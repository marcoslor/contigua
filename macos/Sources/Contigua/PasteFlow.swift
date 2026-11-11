// ⌘V with an image (SHARE-16): one flow per stream window. A person's ⌘V
// sends the image once, waits up to three seconds for the phone to say it
// wrote the clip, and only then sends the single paste key. The three pills
// are the existing glass pill component with one button.

import AppKit
import Foundation

enum PastePhase: Equatable {
    case idle
    case sending(UInt32)
    case awaitingConfirmation(UInt32)
    case pasted
    case failed

    /// Sending the image or waiting for the phone: a second ⌘V is ignored.
    var inFlight: Bool {
        switch self {
        case .sending, .awaitingConfirmation: return true
        case .idle, .pasted, .failed: return false
        }
    }
}

enum PasteEvent: Equatable {
    /// ⌘V's image, with the id the wire transfer uses.
    case paste(UInt32)
    /// The bytes left the Mac.
    case sent(UInt32)
    /// The phone could not even start the transfer.
    case sendFailed(UInt32)
    /// The phone wrote the clip (`clip.image.done`).
    case done(UInt32, ok: Bool)
    case timedOut(UInt32)
    case sessionEnded
    /// Esc, or the outcome pill's five seconds.
    case dismissed
    /// The outcome pill's button.
    case shareInstead
}

enum PasteAction: Equatable {
    case sendImage(UInt32)
    case sendKey(UInt32)
    case share
    case showPasting
    case showPasted
    case showFailed
    case hidePill
    case cancel(UInt32)
}

/// The words and progress of each pill. The texts are the spec's own
/// (SHARE-16), pinned by K2.
enum PastePillState: Equatable {
    case pasting
    case pasted
    case failed

    var text: String {
        switch self {
        case .pasting: return "Pasting…"
        case .pasted: return "Image pasted. Nothing there?"
        case .failed: return "Nothing pasted."
        }
    }

    var showsProgress: Bool { self == .pasting }
}

/// The transition function only: `(phase, event) -> (phase, actions)`.
struct PasteMachine {
    private(set) var phase: PastePhase

    init(phase: PastePhase = .idle) {
        self.phase = phase
    }

    mutating func handle(_ event: PasteEvent) -> [PasteAction] {
        switch event {
        case .paste(let id):
            switch phase {
            case .idle:
                phase = .sending(id)
                return [.sendImage(id), .showPasting]
            case .sending, .awaitingConfirmation:
                return []
            case .pasted, .failed:
                phase = .sending(id)
                return [.hidePill, .sendImage(id), .showPasting]
            }
        case .sent(let id):
            guard case .sending(let current) = phase, current == id else { return [] }
            phase = .awaitingConfirmation(id)
            return []
        case .sendFailed(let id):
            guard case .sending(let current) = phase, current == id else { return [] }
            phase = .failed
            return [.showFailed]
        case .done(let id, let ok):
            guard case .awaitingConfirmation(let current) = phase, current == id else { return [] }
            if ok {
                phase = .pasted
                return [.sendKey(id), .showPasted]
            }
            phase = .failed
            return [.showFailed]
        case .timedOut(let id):
            guard case .awaitingConfirmation(let current) = phase, current == id else { return [] }
            phase = .failed
            return [.showFailed]
        case .sessionEnded:
            switch phase {
            case .idle:
                return []
            case .sending, .awaitingConfirmation:
                phase = .failed
                return [.showFailed]
            case .pasted, .failed:
                phase = .idle
                return [.hidePill]
            }
        case .dismissed:
            switch phase {
            case .idle:
                return []
            case .sending(let id), .awaitingConfirmation(let id):
                phase = .idle
                return [.cancel(id), .hidePill]
            case .pasted, .failed:
                phase = .idle
                return [.hidePill]
            }
        case .shareInstead:
            switch phase {
            case .idle, .sending, .awaitingConfirmation:
                return []
            case .pasted, .failed:
                phase = .idle
                return [.share, .hidePill]
            }
        }
    }
}

/// Drives one window's flow: owns the timers and runs the machine's actions.
@MainActor
final class PasteFlow {
    private(set) var machine = PasteMachine()

    /// The window wires these to the session, the drop path and its pill.
    var sendImage: ((UInt32, Data, String) -> Void)?
    var sendKey: ((KeyEvent) -> Void)?
    var cancelImage: ((UInt32) -> Void)?
    var share: ((Data, String) -> Void)?
    var pill: ((PastePillState?) -> Void)?

    private let wait: Duration
    private let hold: Duration
    private let sleep: @Sendable (Duration) async -> Void
    private var image: (data: Data, mime: String)?
    private var waitTask: Task<Void, Never>?
    private var hideTask: Task<Void, Never>?

    init(wait: Duration = .seconds(3), hold: Duration = .seconds(5),
         sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }) {
        self.wait = wait
        self.hold = hold
        self.sleep = sleep
    }

    var phase: PastePhase { machine.phase }
    var isPillVisible: Bool { machine.phase != .idle }

    /// ⌘V's image. A second ⌘V while one is in flight keeps the first.
    func paste(image data: Data, mime: String, id: UInt32) {
        guard !machine.phase.inFlight else { return }
        self.image = (data, mime)
        handle(.paste(id))
    }

    func sent(_ id: UInt32) { handle(.sent(id)) }
    func done(id: UInt32, ok: Bool) { handle(.done(id, ok: ok)) }
    func sessionEnded() { handle(.sessionEnded) }
    func dismiss() { handle(.dismissed) }
    func shareInstead() { handle(.shareInstead) }

    func handle(_ event: PasteEvent) {
        waitTask?.cancel()
        waitTask = nil
        let before = machine.phase
        let actions = machine.handle(event)
        Log.app.notice("paste: \(String(describing: before), privacy: .public) --\(String(describing: event), privacy: .public)--> \(String(describing: self.machine.phase), privacy: .public)")  // log-ok: closed phase and event tokens plus a wire id, never content
        apply(actions)
        // The wait starts when the bytes have left (`.sent`), and only one
        // timer may exist: the send action may already have dispatched `.sent`.
        if case .awaitingConfirmation(let id) = machine.phase, waitTask == nil {
            waitTask = Task { [weak self] in
                guard let self else { return }
                await self.sleep(self.wait)
                guard !Task.isCancelled else { return }
                self.handle(.timedOut(id))
            }
        }
    }

    private func apply(_ actions: [PasteAction]) {
        for action in actions {
            switch action {
            case .sendImage(let id):
                guard let image else { continue }
                sendImage?(id, image.data, image.mime)
            case .sendKey(let id):
                _ = id
                sendKey?(KeyEvent(action: 0, keycode: 279, metaState: 0))
            case .share:
                guard let image else { continue }
                share?(image.data, image.mime)
            case .showPasting:
                hideTask?.cancel()
                hideTask = nil
                pill?(.pasting)
            case .showPasted:
                pill?(.pasted)
                scheduleHide()
            case .showFailed:
                pill?(.failed)
                scheduleHide()
            case .hidePill:
                hideTask?.cancel()
                hideTask = nil
                pill?(nil)
            case .cancel(let id):
                cancelImage?(id)
            }
        }
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            guard let self else { return }
            await self.sleep(self.hold)
            guard !Task.isCancelled else { return }
            self.handle(.dismissed)
        }
    }
}
