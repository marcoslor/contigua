// Which peers a run may dial on its own.
//
// `default` is the person's own app: discovery is theirs, so it may connect to
// a phone found over Bonjour. Any other profile is a separate test/development
// copy on a Mac that shares its LAN with real phones; one such run dialed a
// real phone it had found over Bonjour and opened pairing screens on it. So a
// non-default profile dials only what it was told to (`--connect host:port`,
// the harness's fakephone or emulator) or a cached address from its own
// earlier session — never a discovered phone.

import Foundation

enum DialPolicy {
    /// True when automatic attempts (reconnects and QR probes) may use
    /// Bonjour-discovered phones.
    static func mayDialDiscovered(_ profile: Profile) -> Bool {
        profile.isDefault
    }
}

/// Where a scheduled attempt dials (`ConnectionController.runAttempt`).
enum AttemptRoute: Equatable {
    /// `--connect-phone host:port`: a test hook's own endpoint.
    case testHook
    /// `--connect host:port`: the test entry point for the current phone;
    /// `launchPairing` is `LinkMachine.launchPairing`.
    case manualConnect(launchPairing: Bool)
    /// A reconnect to a discovered or cached phone.
    case automatic
}

extension DialPolicy {
    /// PAIR-36: `--connect` may pair — the phone's Allow is the only step —
    /// while its launch's first pairing is unresolved, so a retry after `busy`
    /// or a refused first dial is still a pairing attempt and never a pin-only
    /// dial that ends `no-pin`; after that outcome its retries are pin-only and
    /// only the person's Pair Again pairs. The `--connect-phone` hook dials as
    /// it always has. An automatic reconnect never raises a prompt on the phone.
    static func pairingPolicy(for route: AttemptRoute) -> Session.PairingPolicy {
        switch route {
        case .testHook: return .allowed
        case .manualConnect(let launchPairing): return launchPairing ? .allowed : .never
        case .automatic: return .never
        }
    }
}

/// PAIR-36 (#217): what a due attempt — a Bonjour hint, a retry, a tick — does
/// with the phone's live session. A pairing dial still in flight may be the
/// one whose code the phone is showing, so it is left alone, the same guard a
/// person's pairing has (`isPairing`); it ends on its own pairing timeout. Any
/// other unauthenticated attempt is closed before the new dial, never leaked.
enum AttemptPreemption: Equatable {
    /// No session: dial.
    case dial
    /// Ready, or a pairing dial in flight: nothing to do.
    case leave
    /// Close the session, then dial.
    case replace

    static func decide(state: SessionState?, dialsToPair: Bool) -> AttemptPreemption {
        switch state {
        case nil: return .dial
        case .ready: return .leave
        case .idle, .connecting, .handshaking: return dialsToPair ? .leave : .replace
        case .failed, .closed: return .replace
        }
    }
}
