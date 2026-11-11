// Starting a session on any path (docs/design/paths.md §9.1, PATH-20). Every
// ready provider dials at once; only the plain `hello` is serialized, because
// two plain hellos would make the phone supersede its own fresh session. The
// pure machine here decides who sends it and when a held attempt joins.

import Foundation

enum PathStartState: Equatable {
    /// No start yet.
    case idle
    /// Attempts are dialing; no plain hello has gone out.
    case starting
    /// [attempt] holds the one plain hello, waiting for `welcome`.
    case hello(attempt: String)
    /// The first `welcome` found the session; later paths join it.
    case founded(session: String)
    /// Every started provider failed (or the peer refused the version).
    case failed
}

enum PathStartEvent: Equatable {
    /// The provider ids started for this attempt, in the planner's order.
    case start([String])
    /// That attempt's TLS handshake completed: it may hold or send the hello.
    case ready(String)
    case attemptFailed(String)
    /// `welcome.session` arrived on [attempt]; the first one founds the session.
    case welcome(attempt: String, session: String)
}

enum PathStartAction: Equatable {
    case sendPlainHello(String)
    case sendJoin([String], session: String)
    case sessionFounded(String)
    case fail
}

/// `(state, event) -> (state, actions)`; side effects are the caller's.
struct PathStart {
    private(set) var state: PathStartState = .idle
    /// TLS-up attempts waiting for their hello, in readiness order.
    private(set) var held: [String] = []
    private(set) var dialing: Set<String> = []

    mutating func handle(_ event: PathStartEvent) -> [PathStartAction] {
        switch event {
        case .start(let ids):
            guard state == .idle else { return [] }
            state = .starting
            dialing = Set(ids)
            held = []
            return []

        case .ready(let id):
            dialing.remove(id)
            switch state {
            case .starting:
                state = .hello(attempt: id)
                return [.sendPlainHello(id)]
            case .hello:
                held.append(id)
                return []
            case .founded(let session):
                return [.sendJoin([id], session: session)]
            case .failed, .idle:
                return []
            }

        case .attemptFailed(let id):
            dialing.remove(id)
            held.removeAll { $0 == id }
            switch state {
            case .hello(let attempt) where attempt == id:
                if let next = held.first {
                    held.removeFirst()
                    state = .hello(attempt: next)
                    return [.sendPlainHello(next)]
                }
                if dialing.isEmpty {
                    state = .failed
                    return [.fail]
                }
                state = .starting
                return []
            case .starting:
                if dialing.isEmpty && held.isEmpty {
                    state = .failed
                    return [.fail]
                }
                return []
            case .hello, .founded, .failed, .idle:
                return []
            }

        case .welcome(let attempt, let session):
            switch state {
            case .hello(let helloAttempt) where helloAttempt == attempt:
                let joining = held
                held = []
                dialing = []
                state = .founded(session: session)
                var actions: [PathStartAction] = [.sessionFounded(session)]
                if !joining.isEmpty { actions.append(.sendJoin(joining, session: session)) }
                return actions
            case .founded, .hello, .starting, .failed, .idle:
                return []
            }
        }
    }
}
