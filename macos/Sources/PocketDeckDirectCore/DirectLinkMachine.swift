#if POCKETDECK_DIRECT
import Foundation

/// One link's lifecycle (docs/design/direct-link.md §2.5). The daemon never
/// keeps loose booleans beside it: state is this enum only, and the events
/// below are the only way it changes.
public enum DirectLinkState: String, Sendable, Equatable {
    case connecting
    case up
    case down
}

public enum DirectLinkEvent: Sendable, Equatable {
    case connected
    case connectFailed
    case peerClosed
    case appClosed
}

public enum DirectLinkAction: Sendable, Equatable {
    /// Close the app's socket end so the fd reports EOF/reset.
    case closeAppSocket
    /// Stop accepting bytes from the app.
    case stopReadingApp
}

public enum DirectLinkMachine {
    /// Pure transition. `down` ignores every later event: a closed link is
    /// never resurrected; the app dials again.
    public static func step(_ state: DirectLinkState,
                            _ event: DirectLinkEvent) -> (DirectLinkState, [DirectLinkAction]) {
        switch (state, event) {
        case (.connecting, .connected):
            return (.up, [])
        case (.connecting, .connectFailed), (.connecting, .peerClosed), (.connecting, .appClosed):
            return (.down, [.closeAppSocket, .stopReadingApp])
        case (.up, .peerClosed), (.up, .appClosed):
            return (.down, [.closeAppSocket, .stopReadingApp])
        case (.up, .connected):
            // A second connect callback cannot happen on one pcb; ignore it
            // rather than move a live link.
            return (.up, [])
        case (.up, .connectFailed):
            // A late failure on an established link still ends it: the app
            // must not keep a socket the helper will never carry bytes for.
            return (.down, [.closeAppSocket, .stopReadingApp])
        case (.down, _):
            return (.down, [])
        }
    }

    public static func describe(_ state: DirectLinkState, _ event: DirectLinkEvent,
                                _ next: DirectLinkState) -> String {
        "link: \(state.rawValue) --\(event)--> \(next.rawValue)"
    }
}
#endif
