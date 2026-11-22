// PATH-53 (#190, #159): the lifecycle of one session's event-loop group.
//
// A dial runs off the session queue (the TLS handshake blocks), so a close can
// land while a dial is still using the group. The group may only shut down
// once the last dial started on it has ended: a dial that meets a shut-down
// loop has its work dropped by NIO ("Cannot schedule tasks on an EventLoop
// that has already shut down"), its futures never complete and the debug
// build traps on the leaked promise.

import Foundation
import NIOCore

enum DialGroupState: Equatable {
    /// The group takes dials; `dials` are running on it now.
    case open(dials: Int)
    /// The session closed while `dials` were still running; no new dial starts.
    case closing(dials: Int)
    /// Shut down (or handed back, for a group the session does not own).
    case shutDown
}

enum DialGroupEvent: Equatable {
    case dialStarted
    case dialEnded
    case close
}

enum DialGroupAction: Equatable {
    /// Shut the group down now: nothing runs on it any more.
    case shutdown
    /// The dial must not start: the group is closing or gone.
    case refuseDial
}

/// Pure: `(state, event) -> (state, actions)`, every case explicit.
enum DialGroupMachine {
    static func handle(_ state: DialGroupState, _ event: DialGroupEvent) -> (DialGroupState, [DialGroupAction]) {
        switch (state, event) {
        case (.open(let dials), .dialStarted):
            return (.open(dials: dials + 1), [])
        case (.open(let dials), .dialEnded):
            return (.open(dials: max(dials - 1, 0)), [])
        case (.open(let dials), .close):
            return dials == 0 ? (.shutDown, [.shutdown]) : (.closing(dials: dials), [])
        case (.closing(let dials), .dialStarted):
            return (.closing(dials: dials), [.refuseDial])
        case (.closing(let dials), .dialEnded):
            return dials <= 1 ? (.shutDown, [.shutdown]) : (.closing(dials: dials - 1), [])
        case (.closing(let dials), .close):
            return (.closing(dials: dials), [])
        case (.shutDown, .dialStarted):
            return (.shutDown, [.refuseDial])
        case (.shutDown, .dialEnded), (.shutDown, .close):
            return (.shutDown, [])
        }
    }
}

/// One group and its machine. The session queue starts dials and closes; each
/// dial ends from wherever its last use of the group ran, so the state sits
/// behind a lock. Only an owned group is ever shut down.
final class DialGroup: @unchecked Sendable {
    let group: EventLoopGroup
    private let owned: Bool
    private let lock = NSLock()
    private var state: DialGroupState = .open(dials: 0)
    /// Called once the owned group has finished shutting down (tests).
    private let onShutdown: (@Sendable () -> Void)?

    init(group: EventLoopGroup, owned: Bool, onShutdown: (@Sendable () -> Void)? = nil) {
        self.group = group
        self.owned = owned
        self.onShutdown = onShutdown
    }

    var current: DialGroupState {
        lock.lock(); defer { lock.unlock() }
        return state
    }

    /// false: the dial must not run on this group.
    func dialStarted() -> Bool {
        !step(.dialStarted).contains(.refuseDial)
    }

    func dialEnded() {
        perform(step(.dialEnded), blocking: false)
    }

    /// From the session queue. With no dial running the shutdown is the
    /// blocking one close() always did; otherwise the last dial's end does it.
    func close() {
        perform(step(.close), blocking: true)
    }

    private func step(_ event: DialGroupEvent) -> [DialGroupAction] {
        lock.lock(); defer { lock.unlock() }
        let (next, actions) = DialGroupMachine.handle(state, event)
        state = next
        return actions
    }

    private func perform(_ actions: [DialGroupAction], blocking: Bool) {
        guard actions.contains(.shutdown), owned else { return }
        if blocking {
            try? group.syncShutdownGracefully()
            onShutdown?()
        } else {
            // The last dial may end on a thread that must not block on the
            // group (the session queue or a dial thread): shut it down without
            // waiting.
            let done = onShutdown
            group.shutdownGracefully { _ in done?() }
        }
    }
}
