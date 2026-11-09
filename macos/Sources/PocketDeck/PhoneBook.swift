// The phone book above Session (docs/design/multi-phone.md §5.1, §7 slice 1):
// one connection record per phone and one current id. A record owns the live
// Session, its LinkMachine, its attempt timer, its retry state and its path
// outage. The claim set decides the session's lifetime; it is a set and never
// a bool, because the current phone and the --connect-phone test hook can
// name the same phone (pairing.md PAIR-24..PAIR-29).
//
// Nothing here opens a socket or starts a timer: the controller performs the
// returned actions, so every rule is unit-tested with a fake clock.

import Foundation
import Observation

/// What keeps a phone's session alive. Slice 1 has the current phone and the
/// test hook; later slices add feature claims (notifications, Finder).
enum PhoneClaim: Hashable {
    case current
    case testHook
}

/// The live session's path outage (docs/specs/transport.md PATH-17), per phone:
/// none, or down since a moment and, after the windows' 15 s, offline.
enum PathOutage: Equatable {
    case none
    case down(since: Date, offline: Bool)
}

enum PhoneBookAction: Equatable {
    /// Start or resume this phone's session; it has a claim and no live link.
    case connect(deviceId: String)
    /// The last claim went: close this phone's session and cancel its retry.
    case close(deviceId: String)
    case attempt(deviceId: String, after: TimeInterval)
    case stopAttempts(deviceId: String)
    case startPairing(deviceId: String, phone: PhoneRef)
}

/// One machine step, kept for the R4 link log: the states are closed tokens,
/// never a person's words or a reason string the phone chose.
struct LinkTransition: Equatable {
    var from: Link
    var to: Link
    var event: LinkEvent
}

struct PhoneBookEventResult: Equatable {
    var actions: [PhoneBookAction] = []
    /// True only for the current phone: the controller may touch the Deck,
    /// panel, windows and the one clipboard, notifications, files and media.
    var affectsCurrent = false
    var currentLinkLost = false
    var currentLinkRestored = false
    /// Set when this step changed the phone's link (R4's one log line).
    var transition: LinkTransition? = nil
}

@MainActor
@Observable
final class PhoneSession {
    private(set) var deviceId: String
    var phone: PhoneRef?
    var machine = LinkMachine()
    var session: Session?
    var attemptTask: Task<Void, Never>?
    var pathOutage = PathOutage.none
    var claims: Set<PhoneClaim> = []
    /// Attempt state that used to be global (multi-phone.md S4): each phone
    /// dials on its own service/cached choice, interface and failure flag.
    var lastAttemptWasService = false
    var lastAttemptFailed = false
    var pinInterface = true
    /// `--connect-phone`: the endpoint this record dials without discovery.
    var hookEndpoint: (host: String, port: UInt16)?

    init(deviceId: String, phone: PhoneRef? = nil) {
        self.deviceId = deviceId
        self.phone = phone
    }

    /// The link the UI would see for this phone: a live session with no usable
    /// path reads Reconnecting, exactly as the one-phone controller did.
    var link: Link {
        guard pathOutage != .none, case .online(let phone) = machine.link else { return machine.link }
        return .reconnecting(phone)
    }

    var isOnline: Bool { link.isOnline }
    var pathsDown: Bool { pathOutage != .none }
    var pathsOffline: Bool {
        if case .down(_, let offline) = pathOutage { return offline }
        return false
    }

    fileprivate func setDeviceId(_ id: String) { deviceId = id }
}

@MainActor
@Observable
final class PhoneBook {
    private(set) var records: [String: PhoneSession] = [:]
    private(set) var currentId: String?

    /// Launch: the remembered active phone is the only claim. A record that
    /// already says trust was lost starts in that state, not with a dial
    /// (PAIR-32).
    @discardableResult
    func start(active: PhoneRef?, at now: Date,
               trustLost: TrustLossKind? = nil) -> PhoneBookEventResult {
        guard let active else {
            currentId = nil
            return PhoneBookEventResult()
        }
        currentId = active.id
        let record = ensureRecord(for: active.id, phone: active)
        record.claims.insert(.current)
        if let trustLost {
            return handle(.restoreTrustLost(active, trustLost), from: active.id, at: now)
        }
        return handle(.launch(active), from: active.id, at: now)
    }

    var current: PhoneSession? { currentId.flatMap { records[$0] } }
    var currentLink: Link { current?.link ?? .idle }
    /// Sorted so a shutdown and the tests see a stable order.
    var all: [PhoneSession] { records.values.sorted { $0.deviceId < $1.deviceId } }

    func record(for id: String) -> PhoneSession? { records[id] }

    @discardableResult
    func ensureRecord(for id: String, phone: PhoneRef? = nil) -> PhoneSession {
        if let record = records[id] {
            if let phone, record.phone == nil { record.phone = phone }
            return record
        }
        let record = PhoneSession(deviceId: id, phone: phone)
        records[id] = record
        return record
    }

    /// A new claim on a phone with no session asks for a connect; a phone that
    /// already has a session (online or retrying) is left alone.
    @discardableResult
    func addClaim(_ claim: PhoneClaim, to id: String, phone: PhoneRef? = nil) -> [PhoneBookAction] {
        let record = ensureRecord(for: id, phone: phone)
        guard !record.claims.contains(claim) else { return [] }
        let wasEmpty = record.claims.isEmpty
        record.claims.insert(claim)
        return wasEmpty ? [.connect(deviceId: id)] : []
    }

    /// The last claim closes the session; another claim keeps it running.
    @discardableResult
    func removeClaim(_ claim: PhoneClaim, from id: String) -> [PhoneBookAction] {
        guard let record = records[id], record.claims.remove(claim) != nil else { return [] }
        if claim == .current, currentId == id { currentId = nil }
        guard record.claims.isEmpty else { return [] }
        record.machine = LinkMachine()
        record.pathOutage = .none
        return [.close(deviceId: id)]
    }

    /// Use This Phone: the previous phone loses `current` and closes only when
    /// no other claim names it. The new phone connects only when it has no
    /// live link yet; switching to an already-online phone does not redial.
    @discardableResult
    func setCurrent(_ id: String?, phone: PhoneRef? = nil, connect: Bool = true) -> [PhoneBookAction] {
        guard id != currentId else { return [] }
        var actions: [PhoneBookAction] = []
        if let previous = currentId { actions += removeClaim(.current, from: previous) }
        currentId = id
        guard let id else { return actions }
        let record = ensureRecord(for: id, phone: phone)
        let needsConnect = record.machine.link == .idle && record.session == nil
        record.claims.insert(.current)
        if connect, needsConnect { actions.append(.connect(deviceId: id)) }
        return actions
    }

    /// Forget: drop the record and close its session; every other record stays.
    @discardableResult
    func removeRecord(_ id: String) -> [PhoneBookAction] {
        guard let record = records.removeValue(forKey: id) else { return [] }
        if currentId == id { currentId = nil }
        record.claims = []
        record.machine = LinkMachine()
        record.pathOutage = .none
        return [.close(deviceId: id)]
    }

    /// A manual pairing starts under a provisional id and learns the phone's
    /// device id from `welcome`; live session closures follow the record, so
    /// only the map key and the id change. When another record already holds
    /// that id (the same phone reached under two ids), it is handed back for
    /// the controller to close, and its claims move to the adopted record.
    @discardableResult
    func adopt(_ record: PhoneSession, as id: String) -> PhoneSession? {
        guard record.deviceId != id else { return nil }
        let old = record.deviceId
        let displaced = records[id]
        if let displaced { record.claims.formUnion(displaced.claims) }
        records.removeValue(forKey: old)
        record.setDeviceId(id)
        records[id] = record
        if currentId == old { currentId = id }
        return displaced
    }

    /// Drive one phone's LinkMachine. Actions carry the phone id so the
    /// controller schedules that phone's own attempt.
    func handle(_ event: LinkEvent, from id: String, at now: Date) -> PhoneBookEventResult {
        guard let record = records[id] else { return PhoneBookEventResult() }
        rememberPhone(event, in: record)
        let before = record.link
        let actions = record.machine.handle(event, at: now).map { action -> PhoneBookAction in
            switch action {
            case .attempt(let delay): return .attempt(deviceId: id, after: delay)
            case .stopAttempts: return .stopAttempts(deviceId: id)
            case .startPairing(let phone): return .startPairing(deviceId: id, phone: phone)
            }
        }
        let after = record.link
        let affectsCurrent = id == currentId
        return PhoneBookEventResult(
            actions: actions,
            affectsCurrent: affectsCurrent,
            currentLinkLost: affectsCurrent && before.isOnline && !after.isOnline,
            currentLinkRestored: affectsCurrent && !before.isOnline && after.isOnline,
            transition: before == after ? nil : LinkTransition(from: before, to: after, event: event))
    }

    /// Shutdown: every phone loses every claim and every session closes.
    @discardableResult
    func closeAll() -> [PhoneBookAction] {
        var actions: [PhoneBookAction] = []
        for record in all where !record.claims.isEmpty || record.machine.link != .idle {
            record.claims = []
            record.machine = LinkMachine()
            record.pathOutage = .none
            actions.append(.close(deviceId: record.deviceId))
        }
        currentId = nil
        return actions
    }

    private func rememberPhone(_ event: LinkEvent, in record: PhoneSession) {
        switch event {
        case .launch(let phone):
            if let phone { record.phone = phone }
        case .activate(let phone), .welcome(let phone):
            record.phone = phone
        case .beginPairing(let phone), .codeShown(let phone, _):
            record.phone = phone
        default:
            break
        }
    }
}
