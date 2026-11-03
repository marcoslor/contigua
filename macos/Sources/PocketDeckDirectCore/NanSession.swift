#if POCKETDECK_DIRECT
import Foundation

public enum NanLimits {
    /// docs/design/direct-link.md §2.2: one NDP has 20 s from the dial (the
    /// proof brought one up in about 3.5 s); after that the dial fails.
    public static let ndpTimeoutSeconds = 20
}

/// The 8-byte service-specific info of §6. A short array can never equal a
/// real one, so a malformed discovery report is ignored, not matched.
public struct NanSsi: Sendable, Equatable, Hashable {
    public let bytes: [UInt8]

    public init(_ bytes: [UInt8]) {
        self.bytes = Array(bytes.prefix(8))
    }

    public var hex: String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
}

/// One discovery result the toolkit reported. `token` is the executor's own
/// handle for the toolkit's object; it never travels on the air or in a log.
public struct NanDiscovery: Sendable, Equatable {
    public let token: Int
    public let ssi: NanSsi

    public init(token: Int, ssi: NanSsi) {
        self.token = token
        self.ssi = ssi
    }
}

/// What the private toolkit refused, in its own closed vocabulary.
public enum NanToolkitFailure: Sendable, Equatable {
    /// `dlopen` or the classes are missing: no provider at all.
    case unavailable
    /// The subscribe call failed; the air rejected us.
    case subscribeFailed
    /// The data-session start failed; the NDP was refused.
    case dataSessionFailed
}

/// A data-session state report (§2.2 step 5). The peer's MAC and link-local
/// are the only fields the link layer needs.
public enum NanDataSessionReport: Sendable, Equatable {
    case starting
    case up(mac: String, linkLocal: String)
    case failed(DirectWireCode)
    case lost
}

public enum NanSessionEvent: Sendable, Equatable {
    /// A dial with a key: subscribe for these windows and wait for a match.
    case start(service: String, windows: [NanSsi], passphrase: String)
    /// The 10-minute window turned while an attempt runs.
    case ssiWindows([NanSsi])
    case discovered(NanDiscovery)
    case dataSession(NanDataSessionReport)
    /// The executor's 20 s timer, `NanLimits.ndpTimeoutSeconds` after `start`.
    case ndpTimeout
    case stop
    case toolkit(NanToolkitFailure)
}

/// One attempt's inputs. `passphrase` is the NDP passphrase (§5); it is
/// never logged and never leaves this machine.
public struct NanAttempt: Sendable, Equatable {
    public let service: String
    public let windows: [NanSsi]
    public let passphrase: String

    public init(service: String, windows: [NanSsi], passphrase: String) {
        self.service = service
        self.windows = windows
        self.passphrase = passphrase
    }

    public func matches(_ ssi: NanSsi) -> Bool {
        windows.contains(ssi)
    }

    fileprivate func ticking(_ windows: [NanSsi]) -> NanAttempt {
        NanAttempt(service: service, windows: windows, passphrase: passphrase)
    }
}

public enum NanSessionState: Sendable, Equatable {
    case idle
    case subscribing(NanAttempt)
    case discovered(NanAttempt, token: Int)
    case dataSessionStarting(NanAttempt, token: Int)
    /// `up(peerMAC, peerLL)`: one MAC and one link-local on one interface,
    /// exactly the shape the test-only `peer` op takes.
    case up(DirectPeerSpec)
    case lost
    case blocked(DirectWireCode)
}

public enum NanSessionAction: Sendable, Equatable {
    case subscribe(service: String, windows: [NanSsi])
    case updateWindows([NanSsi])
    case unsubscribe
    case startDataSession(token: Int, passphrase: String)
    case stopDataSession
    case peerUp(DirectPeerSpec)
    case peerLost
    case failed(DirectWireCode)
}

public enum NanPortError: Error, Sendable, Equatable {
    case unavailable
    case failed
}

/// The radio surface the machine drives. The real adapter is `ToolkitNanPort`
/// (§2.2); tests use a fake and never load the framework.
public protocol NanPort: AnyObject {
    func subscribe(service: String, windows: [NanSsi]) throws
    func updateWindows(_ windows: [NanSsi]) throws
    func startDataSession(token: Int, passphrase: String) throws
    func stopDataSession()
    func unsubscribe()
}

/// §2.2's NDP lifecycle. Pure: `step` returns the next state and the effects;
/// `NanSession` below performs them through a `NanPort`.
public enum NanSessionMachine {
    public static func step(_ state: NanSessionState, _ event: NanSessionEvent,
                            interface: String) -> (NanSessionState, [NanSessionAction]) {
        switch (state, event) {
        case (.idle, .start(let service, let windows, let passphrase)):
            let attempt = NanAttempt(service: service, windows: windows, passphrase: passphrase)
            return (.subscribing(attempt), [.subscribe(service: service, windows: windows)])
        case (.idle, _):
            return (state, [])

        // subscribing: the discovery result is the only way forward.
        case (.subscribing, .start):
            return (state, [])
        case (.subscribing(let attempt), .ssiWindows(let windows)):
            return (.subscribing(attempt.ticking(windows)), [.updateWindows(windows)])
        case (.subscribing(let attempt), .discovered(let discovery))
            where attempt.matches(discovery.ssi):
            return (.discovered(attempt, token: discovery.token),
                    [.startDataSession(token: discovery.token,
                                       passphrase: attempt.passphrase)])
        case (.subscribing, .discovered):
            return (state, [])
        case (.subscribing, .dataSession):
            return (state, [])
        case (.subscribing, .ndpTimeout):
            return (.blocked(.ndpTimeout), [.unsubscribe, .failed(.ndpTimeout)])
        case (.subscribing, .stop):
            return (.idle, [.unsubscribe])
        case (.subscribing, .toolkit(let failure)):
            let code: DirectWireCode = failure == .unavailable ? .notReady : .ndpRefused
            return (.blocked(code), [.unsubscribe, .failed(code)])

        // discovered: the data session is starting; an up report may arrive
        // before the starting report and is accepted.
        case (.discovered, .start):
            return (state, [])
        case (.discovered(let attempt, let token), .ssiWindows(let windows)):
            return (.discovered(attempt.ticking(windows), token: token),
                    [.updateWindows(windows)])
        case (.discovered, .discovered):
            return (state, [])
        case (.discovered(let attempt, let token), .dataSession(.starting)):
            return (.dataSessionStarting(attempt, token: token), [])
        case (.discovered, .dataSession(.up(let mac, let linkLocal))):
            return peerUp(mac: mac, linkLocal: linkLocal, interface: interface)
        case (.discovered, .dataSession(.failed(let code))):
            return (.blocked(code), [.stopDataSession, .unsubscribe, .failed(code)])
        case (.discovered, .dataSession(.lost)):
            return (state, [])
        case (.discovered, .ndpTimeout):
            return (.blocked(.ndpTimeout),
                    [.stopDataSession, .unsubscribe, .failed(.ndpTimeout)])
        case (.discovered, .stop):
            return (.idle, [.stopDataSession, .unsubscribe])
        case (.discovered, .toolkit):
            return (.blocked(.ndpRefused),
                    [.stopDataSession, .unsubscribe, .failed(.ndpRefused)])

        // dataSessionStarting: the up report hands the peer to the link layer.
        case (.dataSessionStarting, .start):
            return (state, [])
        case (.dataSessionStarting(let attempt, let token), .ssiWindows(let windows)):
            return (.dataSessionStarting(attempt.ticking(windows), token: token),
                    [.updateWindows(windows)])
        case (.dataSessionStarting, .discovered):
            return (state, [])
        case (.dataSessionStarting, .dataSession(.starting)):
            return (state, [])
        case (.dataSessionStarting, .dataSession(.up(let mac, let linkLocal))):
            return peerUp(mac: mac, linkLocal: linkLocal, interface: interface)
        case (.dataSessionStarting, .dataSession(.failed(let code))):
            return (.blocked(code), [.stopDataSession, .unsubscribe, .failed(code)])
        case (.dataSessionStarting, .dataSession(.lost)):
            return (.blocked(.ndpRefused),
                    [.stopDataSession, .unsubscribe, .failed(.ndpRefused)])
        case (.dataSessionStarting, .ndpTimeout):
            return (.blocked(.ndpTimeout),
                    [.stopDataSession, .unsubscribe, .failed(.ndpTimeout)])
        case (.dataSessionStarting, .stop):
            return (.idle, [.stopDataSession, .unsubscribe])
        case (.dataSessionStarting, .toolkit):
            return (.blocked(.ndpRefused),
                    [.stopDataSession, .unsubscribe, .failed(.ndpRefused)])

        // up: the NDP is the link layer's; a lost report tears it down, and a
        // second dial reuses it.
        case (.up, .ssiWindows(let windows)):
            return (state, [.updateWindows(windows)])
        case (.up, .dataSession(.lost)):
            return (.lost, [.peerLost, .stopDataSession, .unsubscribe])
        case (.up, .stop):
            return (.idle, [.peerLost, .stopDataSession, .unsubscribe])
        case (.up, _):
            return (state, [])

        // lost: the radio is quiet; the next dial subscribes again.
        case (.lost, .start(let service, let windows, let passphrase)):
            let attempt = NanAttempt(service: service, windows: windows, passphrase: passphrase)
            return (.subscribing(attempt), [.subscribe(service: service, windows: windows)])
        case (.lost, .stop):
            return (.idle, [])
        case (.lost, _):
            return (state, [])

        // blocked: the attempt is over and torn down; a new dial starts over.
        case (.blocked, .start(let service, let windows, let passphrase)):
            let attempt = NanAttempt(service: service, windows: windows, passphrase: passphrase)
            return (.subscribing(attempt), [.subscribe(service: service, windows: windows)])
        case (.blocked, .stop):
            return (.idle, [])
        case (.blocked, _):
            return (state, [])
        }
    }

    /// The transition line of AGENTS.md; closed tokens only, so no SSI, key,
    /// passphrase, MAC or address can reach a log.
    public static func describe(_ state: NanSessionState, _ event: NanSessionEvent,
                                _ next: NanSessionState) -> String {
        "nan: \(token(state)) --\(token(event))--> \(token(next))"
    }

    private static func peerUp(mac: String, linkLocal: String,
                               interface: String) -> (NanSessionState, [NanSessionAction]) {
        guard let peer = peerSpec(interface: interface, mac: mac, linkLocal: linkLocal) else {
            return (.blocked(.ndpRefused),
                    [.stopDataSession, .unsubscribe, .failed(.ndpRefused)])
        }
        return (.up(peer), [.peerUp(peer)])
    }

    private static func peerSpec(interface: String, mac: String,
                                 linkLocal: String) -> DirectPeerSpec? {
        let normalized = mac.lowercased()
        guard isMAC(normalized), let bytes = IPv6Address.parse(linkLocal) else { return nil }
        return DirectPeerSpec(interface: interface, mac: normalized,
                              linkLocal: IPv6Address.format(bytes))
    }

    private static func token(_ state: NanSessionState) -> String {
        switch state {
        case .idle: return "idle"
        case .subscribing: return "subscribing"
        case .discovered: return "discovered"
        case .dataSessionStarting: return "data_session_starting"
        case .up: return "up"
        case .lost: return "lost"
        case .blocked(let code): return "blocked:\(code.rawValue)"
        }
    }

    private static func token(_ event: NanSessionEvent) -> String {
        switch event {
        case .start: return "start"
        case .ssiWindows: return "ssi_windows"
        case .discovered(let discovery):
            return "discovered:\(discovery.token)"
        case .dataSession(.starting): return "data_session:starting"
        case .dataSession(.up): return "data_session:up"
        case .dataSession(.failed(let code)): return "data_session:failed:\(code.rawValue)"
        case .dataSession(.lost): return "data_session:lost"
        case .ndpTimeout: return "ndp_timeout"
        case .stop: return "stop"
        case .toolkit(.unavailable): return "toolkit:unavailable"
        case .toolkit(.subscribeFailed): return "toolkit:subscribe_failed"
        case .toolkit(.dataSessionFailed): return "toolkit:data_session_failed"
        }
    }
}

public struct NanSessionStep: Sendable, Equatable {
    public let state: NanSessionState
    public let actions: [NanSessionAction]

    public init(state: NanSessionState, actions: [NanSessionAction]) {
        self.state = state
        self.actions = actions
    }
}

/// The machine plus the port: one owner of the radio's lifecycle, one
/// transition line per state change, every effect through `NanPort`.
public final class NanSession {
    public private(set) var state: NanSessionState = .idle
    private let port: NanPort
    private let interface: String
    private let log: (String) -> Void

    public init(port: NanPort, interface: String,
                log: @escaping (String) -> Void = { _ in }) {
        self.port = port
        self.interface = interface
        self.log = log
    }

    public var peer: DirectPeerSpec? {
        if case .up(let peer) = state { return peer }
        return nil
    }

    @discardableResult
    public func handle(_ event: NanSessionEvent) -> NanSessionStep {
        let from = state
        let (next, actions) = NanSessionMachine.step(from, event, interface: interface)
        state = next
        if next != from {
            log(NanSessionMachine.describe(from, event, next))
        }
        if let failure = perform(actions) {
            return handle(.toolkit(failure))
        }
        return NanSessionStep(state: next, actions: actions)
    }

    /// Performs the port half; peer and failure actions belong to the caller.
    /// A port refusal is fed back as the toolkit event, which always ends in
    /// `blocked`, so this cannot recurse twice.
    private func perform(_ actions: [NanSessionAction]) -> NanToolkitFailure? {
        for action in actions {
            switch action {
            case .subscribe(let service, let windows):
                do {
                    try port.subscribe(service: service, windows: windows)
                } catch let error as NanPortError {
                    return error == .unavailable ? .unavailable : .subscribeFailed
                } catch {
                    return .subscribeFailed
                }
            case .updateWindows(let windows):
                do {
                    try port.updateWindows(windows)
                } catch {
                    return .subscribeFailed
                }
            case .startDataSession(let token, let passphrase):
                do {
                    try port.startDataSession(token: token, passphrase: passphrase)
                } catch {
                    return .dataSessionFailed
                }
            case .unsubscribe:
                port.unsubscribe()
            case .stopDataSession:
                port.stopDataSession()
            case .peerUp, .peerLost, .failed:
                break
            }
        }
        return nil
    }
}
#endif
