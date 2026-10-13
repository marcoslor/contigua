// The connection as the UI sees it: one `Link` value, driven by a pure state
// machine. Nothing here touches sockets, timers or the main queue, so every
// transition (docs/design/mac-redesign.md §4) is unit-tested with a fake clock.
//
// The UI never sees session states or reason strings: transient failures only
// move `Link` (and show nothing), the few failures that need the user become a
// `Banner`.

import Foundation

struct PhoneRef: Equatable, Hashable {
    var id: String
    var name: String
    var model: String
}

enum Cause: Equatable {
    case unreachable
    case busy
    case versionMismatch
    case localNetworkDenied
}

enum Pairing: Equatable {
    /// Connecting; the phone has not shown its code yet.
    case contacting
    /// Both screens show this code; the person compares and taps Allow on the phone.
    case comparing(code: String)
    /// The person tapped Allow; the key and `welcome` are on their way.
    case verifying
    case denied
    /// Nobody answered on the phone within its 120 s.
    case timedOut
    /// The phone could not be reached, or the connection dropped while pairing.
    case unreachable
}

enum Link: Equatable {
    /// Nothing remembered and nothing in progress.
    case idle
    /// First attempt(s) this run; never online yet.
    case connecting(PhoneRef)
    case online(PhoneRef)
    /// Was online this run; the link dropped less than 15 s ago.
    case reconnecting(PhoneRef)
    /// No live session for 15 s (or the phone said why it will not talk to us).
    case offline(PhoneRef, Cause)
    /// The key is missing or the phone rejected it.
    case needsPairing(PhoneRef)
    /// A user-driven pairing is in progress; a sheet is up.
    case pairing(PhoneRef, Pairing)

    var phone: PhoneRef? {
        switch self {
        case .idle: return nil
        case .connecting(let p), .online(let p), .reconnecting(let p), .needsPairing(let p): return p
        case .offline(let p, _), .pairing(let p, _): return p
        }
    }

    var isOnline: Bool {
        if case .online = self { return true }
        return false
    }

    /// The link is down but the Mac keeps trying on its own.
    var isRecovering: Bool {
        switch self {
        case .connecting, .reconnecting, .offline(_, .unreachable), .offline(_, .busy): return true
        default: return false
        }
    }
}

/// One line under the toolbar, with at most one button. Derived from `Link`;
/// never raw reason codes.
struct Banner: Equatable {
    enum Action: Equatable { case tryNow, pairAgain, openSettings }
    var text: String
    var action: Action?

    var actionTitle: String? {
        switch action {
        case .tryNow: return "Try now"
        case .pairAgain: return "Pair again"
        case .openSettings: return "Open Settings"
        case nil: return nil
        }
    }
}

extension Link {
    var banner: Banner? {
        switch self {
        case .offline(let p, .unreachable):
            return Banner(text: "Can't reach \(p.name). Check that it's on the same Wi-Fi.", action: .tryNow)
        case .offline(let p, .busy):
            return Banner(text: "Another Mac is connected to \(p.name).", action: .tryNow)
        case .offline(let p, .versionMismatch):
            return Banner(text: "\(p.name) runs an incompatible version of PocketDeck.", action: nil)
        case .offline(_, .localNetworkDenied):
            return Banner(text: "PocketDeck needs Local Network access. Open System Settings → Privacy & Security → Local Network.",
                          action: .openSettings)
        case .needsPairing(let p):
            return Banner(text: "\(p.name) no longer trusts this Mac.", action: .pairAgain)
        default:
            return nil
        }
    }
}

enum ChipStyle: Equatable { case green, orange, pulsingOrange, grey }

struct Chip: Equatable {
    var text: String
    var style: ChipStyle
}

extension Link {
    /// The toolbar chip; nil while a pairing sheet is up or nothing is remembered.
    var chip: Chip? {
        switch self {
        case .idle, .pairing: return nil
        case .online: return Chip(text: "Connected", style: .green)
        case .connecting: return Chip(text: "Connecting…", style: .grey)
        case .reconnecting: return Chip(text: "Reconnecting…", style: .pulsingOrange)
        case .offline: return Chip(text: "Offline", style: .grey)
        case .needsPairing: return Chip(text: "Pair again", style: .orange)
        }
    }
}

// MARK: - Retry schedule

enum ReconnectPolicy {
    /// 1, 2, 4, 8, 15 s, then every 15 s for as long as it takes.
    static let backoff: [TimeInterval] = [1, 2, 4, 8, 15]

    /// Delay before the attempt that follows `failures` consecutive failures.
    static func delay(afterFailures failures: Int) -> TimeInterval {
        guard failures > 0 else { return 0 }
        return backoff[min(failures - 1, backoff.count - 1)]
    }
}

// MARK: - State machine

enum LinkEvent: Equatable {
    /// App launch. `phone` is the remembered active phone, if any.
    case launch(PhoneRef?)
    /// A different phone becomes the active one and is connected to now
    /// (Settings → Use, a finished QR pairing).
    case activate(PhoneRef)
    /// A session reached `welcome` (a pairing session included).
    case welcome(PhoneRef)
    /// An attempt ended. `reason` is a `ConnectionFailure` reason or a phone error code.
    case attemptFailed(reason: String)
    /// The remembered phone was (re)discovered, the network changed, the Mac woke.
    case reachabilityHint
    case tryNow
    case beginPairing(PhoneRef)
    /// The phone showed a code (`pair.code_shown`) in a session that is allowed to pair.
    case codeShown(PhoneRef, code: String)
    /// The phone sent `pair.ok`: the person tapped Allow.
    case pairApproved
    case cancelPairing
    case forget(deviceId: String)
    case localNetworkDenied
    case tick
}

enum LinkAction: Equatable {
    /// Start the next attempt after `delay` (replaces any scheduled attempt).
    case attempt(after: TimeInterval)
    /// No attempt may run or be scheduled.
    case stopAttempts
    /// Open a user-driven pairing session with this phone.
    case startPairing(PhoneRef)
}

struct LinkMachine {
    static let offlineAfter: TimeInterval = 15

    private(set) var link: Link = .idle
    private var outageStart: Date?
    private var failures = 0
    /// Where to go back to when a pairing is cancelled.
    private var resume: Link = .idle

    init(link: Link = .idle) { self.link = link }

    var consecutiveFailures: Int { failures }

    @discardableResult
    mutating func handle(_ event: LinkEvent, at now: Date) -> [LinkAction] {
        switch event {
        case .launch(let phone):
            guard let phone else { link = .idle; return [] }
            link = .connecting(phone)
            outageStart = now
            failures = 0
            return [.attempt(after: 0)]

        case .activate(let phone):
            link = .connecting(phone)
            outageStart = now
            failures = 0
            return [.attempt(after: 0)]

        case .welcome(let phone):
            link = .online(phone)
            outageStart = nil
            failures = 0
            return []

        case .attemptFailed(let reason):
            return failed(reason, at: now)

        case .reachabilityHint, .tryNow:
            guard link.isRecovering || isRetryable(event) else { return [] }
            failures = 0
            return [.attempt(after: 0)]

        case .beginPairing(let phone):
            resume = pairingIsActive ? resume : link
            link = .pairing(phone, .contacting)
            return [.stopAttempts, .startPairing(phone)]

        case .codeShown(let phone, let code):
            if !pairingIsActive { resume = link }
            link = .pairing(phone, .comparing(code: code))
            return [.stopAttempts]

        case .pairApproved:
            guard case .pairing(let p, _) = link else { return [] }
            link = .pairing(p, .verifying)
            return []

        case .cancelPairing:
            guard pairingIsActive else { return [] }
            link = resume
            if case .idle = resume { return [] }
            if case .needsPairing = resume { return [] }
            failures = 0
            outageStart = now
            return [.attempt(after: 0)]

        case .forget(let deviceId):
            guard link.phone?.id == deviceId else { return [] }
            link = .idle
            outageStart = nil
            return [.stopAttempts]

        case .localNetworkDenied:
            guard let phone = link.phone else { return [] }
            link = .offline(phone, .localNetworkDenied)
            return [.stopAttempts]

        case .tick:
            switch link {
            case .connecting(let p), .reconnecting(let p):
                if let start = outageStart, now.timeIntervalSince(start) >= Self.offlineAfter {
                    link = .offline(p, .unreachable)
                }
            default:
                break
            }
            return []
        }
    }

    private var pairingIsActive: Bool {
        if case .pairing = link { return true }
        return false
    }

    /// "Try now" also restarts a phone that was waiting for the user.
    private func isRetryable(_ event: LinkEvent) -> Bool {
        guard event == .tryNow else { return false }
        if case .offline(_, .versionMismatch) = link { return true }
        return false
    }

    private mutating func failed(_ reason: String, at now: Date) -> [LinkAction] {
        if case .pairing(let phone, _) = link {
            switch reason {
            case "pair_denied": link = .pairing(phone, .denied)
            case "pair_timeout": link = .pairing(phone, .timedOut)
            default: link = .pairing(phone, .unreachable)
            }
            return []
        }
        guard let phone = link.phone else { return [] }
        switch reason {
        case "auth_failed":
            link = .needsPairing(phone)
            return [.stopAttempts]
        case "version":
            link = .offline(phone, .versionMismatch)
            return [.stopAttempts]
        case "pair_denied":
            return []
        case "busy":
            failures += 1
            link = .offline(phone, .busy)
            return [.attempt(after: max(ReconnectPolicy.delay(afterFailures: failures), 15))]
        default:
            failures += 1
            switch link {
            case .online:
                link = .reconnecting(phone)
                outageStart = now
            case .offline(_, .busy):
                link = .offline(phone, .unreachable)
            default:
                break
            }
            return [.attempt(after: ReconnectPolicy.delay(afterFailures: failures))]
        }
    }
}
