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
    /// The phone's master switch is off: every Mac is refused.
    case connectionsOff
    /// The phone accepts paired Macs but not new pairings.
    case pairingsOff
    /// 30 s with neither an advertisement nor a last welcome address: the Mac
    /// has nothing to dial and says so instead of showing Connecting forever.
    case notFound
}

/// Which kind of trust loss a phone is in (PAIR-31/32). *Told* is the phone's
/// own authenticated word (`forgotten`, or its certificate rejection twice):
/// attempts stop. *Inferred* is the Mac's own pin check with the id advertised:
/// the TXT id is unauthenticated, so it only quiets the retries, never stops
/// them, and a passing pin clears it.
enum TrustLossKind: String, Codable, Equatable {
    case told
    case inferred

    var keepsRechecking: Bool { self == .inferred }
    var keepsAddress: Bool { self == .inferred }
}

/// A pin mismatch is the same phone with a new identity, or a foreign phone at
/// a stale address. Before TLS verifies anything the only same-device proof the
/// protocol carries is the advertised record's TXT `id` (a pin mismatch aborts
/// the handshake before `welcome`): a dial to that phone's own discovery record,
/// or the pinned id advertised when the attempt fails.
enum TrustLoss {
    static func sameDevice(dialedService: Bool, advertised: Bool) -> Bool {
        dialedService || advertised
    }
}

enum Pairing: Equatable {
    /// Connecting; the phone has not shown its code yet.
    case contacting
    /// Both screens show this code; the person compares and taps Allow on the phone.
    case comparing(code: String)
    /// The person tapped Allow; the key and `welcome` are on their way.
    case verifying
    /// The person denied on the phone: its own 30 s window started at that
    /// moment, and the sheet counts it down (R2).
    case denied(until: Date)
    /// The phone is inside its 30 s window after a Deny or a timeout: the next
    /// attempt must wait, and the sheet says so (PAIR-5, R2).
    case coolingDown(until: Date)
    /// The phone refused the pairing itself (its master or pairing switch is off).
    case refused(String)
    /// Nobody answered on the phone within its 120 s.
    case timedOut
    /// The phone could not be reached, or the connection dropped while pairing.
    case unreachable
}

extension Pairing {
    /// The deadline a countdown runs to, when this state has one.
    var countdownUntil: Date? {
        switch self {
        case .denied(let until), .coolingDown(let until): return until
        default: return nil
        }
    }

    /// Whole seconds left, never negative: the sheet's one number (R2).
    func remaining(at now: Date) -> Int {
        countdownUntil.map { Self.remaining(until: $0, at: now) } ?? 0
    }

    static func remaining(until: Date, at now: Date) -> Int {
        max(0, Int(until.timeIntervalSince(now).rounded(.up)))
    }

    /// R2 rule 2: Try Again is offered only at 0; nothing retries by itself.
    func canTryAgain(at now: Date) -> Bool {
        countdownUntil.map { Self.canTryAgain(until: $0, at: now) } ?? true
    }

    static func canTryAgain(until: Date, at now: Date) -> Bool { now >= until }

    /// A closed token for the report and the link log (never a date).
    var token: String {
        switch self {
        case .contacting: return "contacting"
        case .comparing: return "comparing"
        case .verifying: return "verifying"
        case .denied: return "denied"
        case .coolingDown: return "coolingDown"
        case .refused: return "refused"
        case .timedOut: return "timedOut"
        case .unreachable: return "unreachable"
        }
    }
}

/// The pairing sheet's failure lines that are worth pinning in a test (the
/// others name the phone and are built there).
enum PairingCopy {
    static let coolingDown = "Wait a moment, then try again."
    static let denied = "Pairing was denied on the phone."

    /// The countdown's one number (R2): seconds only, no new sentence.
    static func countdown(_ seconds: Int) -> String { "\(max(0, seconds)) s" }
    /// PAIR-6: a prompt that has waited 20 s may be invisible because the
    /// phone's notifications are off; the Mac names that possibility.
    static let slowHint = "Check your phone: Contigua's notifications may be turned off."
    static let slowHintAfter: TimeInterval = 20

    static func slowHint(after elapsed: TimeInterval) -> String? {
        elapsed >= slowHintAfter ? slowHint : nil
    }
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

    /// True while the window overlays should show a down state. A window can
    /// miss the one-shot online -> offline transition while it is opening, so
    /// the controller reconciles against this value, not only the edge.
    var isDown: Bool {
        switch self {
        case .reconnecting, .offline: return true
        case .idle, .connecting, .online, .needsPairing, .pairing: return false
        }
    }

    /// The window state this Link demands: down while retrying, up only when a
    /// session is online, unchanged for pairing/idle/first-connect. A pairing
    /// failure must not restore windows: `needsPairing` is not "down", but it
    /// is no live session either (the one-shot linkLost already ran).
    var windowDesiredDown: Bool? {
        if isDown { return true }
        if isOnline { return false }
        return nil
    }

    var isOnline: Bool {
        if case .online = self { return true }
        return false
    }

    /// The link is down but the Mac keeps trying on its own.
    var isRecovering: Bool {
        switch self {
        case .connecting, .reconnecting, .offline(_, .unreachable), .offline(_, .busy),
             .offline(_, .pairingsOff), .offline(_, .notFound): return true
        case .offline(_, .connectionsOff): return true
        default: return false
        }
    }

    /// A closed name for the R4 link log: never a person's words, never a
    /// reason string the phone chose.
    var token: String {
        switch self {
        case .idle: return "idle"
        case .connecting: return "connecting"
        case .online: return "online"
        case .reconnecting: return "reconnecting"
        case .offline(_, let cause): return "offline(\(cause.token))"
        case .needsPairing: return "needsPairing"
        case .pairing(_, let pairing): return "pairing(\(pairing.token))"
        }
    }
}

extension Cause {
    var token: String {
        switch self {
        case .unreachable: return "unreachable"
        case .busy: return "busy"
        case .versionMismatch: return "versionMismatch"
        case .localNetworkDenied: return "localNetworkDenied"
        case .connectionsOff: return "connectionsOff"
        case .pairingsOff: return "pairingsOff"
        case .notFound: return "notFound"
        }
    }
}

/// [DECK-14/15] When the phone was last reached, in the person's own words:
/// "Last seen 14:32" while that was today, and the date and the time before
/// today. FormatStyle, so a 12-hour locale and the date's order read its own
/// way.
enum LastSeen {
    static func line(_ date: Date, now: Date = Date(),
                     calendar: Calendar = .current, locale: Locale = .current) -> String {
        var style: Date.FormatStyle = calendar.isDate(date, inSameDayAs: now)
            ? .dateTime.hour().minute()
            : .dateTime.day().month(.abbreviated).hour().minute()
        style.locale = locale
        style.timeZone = calendar.timeZone
        return "Last seen \(date.formatted(style))"
    }
}

/// CONV-PD-07: one spelling for the pair-again action on the Mac. A banner or
/// a state word says "Pair again" (sentence case, no ellipsis); a button or
/// menu title that opens the pairing sheet says "Pair Again…" (the Mac's title
/// case, and an action that asks for more). The phone's own "Pair new Mac" is
/// the phone's and stays as it is.
enum PairAgainCopy {
    static let banner = "Pair again"
    static let sheet = "Pair Again…"

    /// The Deck's Nearby row button: the sheet's spelling for a remembered
    /// phone whose key is gone, plain "Pair" for a phone never paired.
    static func sheetButton(needsPairing: Bool) -> String {
        needsPairing ? sheet : "Pair"
    }
}

/// One line under the toolbar, with at most one button. Derived from `Link`;
/// never raw reason codes.
struct Banner: Equatable {
    enum Action: Equatable { case tryNow, pairAgain, openSettings }
    var text: String
    var action: Action?
    /// One line under the text, for the step that fixes the state (PAIR-35).
    var detail: String? = nil
    /// A live countdown the view draws as "23 s" (R2); the deadline lives in
    /// the machine's state, never in a view timer.
    var countdownUntil: Date? = nil
    /// [DECK-15] The offline banner's last line: when the phone was last
    /// reached. A value from the link machine, drawn through `LastSeen`.
    var lastSeen: Date? = nil

    var actionTitle: String? {
        switch action {
        case .tryNow: return "Try now"
        case .pairAgain: return PairAgainCopy.banner
        case .openSettings: return "Open Settings"
        case nil: return nil
        }
    }
}

extension Link {
    /// The failure messages, named by the phone's own (reported) name — what
    /// the pure state machine shows. Nicknames enter through `banner(naming:)`.
    var banner: Banner? { banner(naming: \.name) }

    /// The failure messages. `naming` turns the phone's ref into the name to
    /// show (its nickname, else its own name); every caller that can resolve
    /// nicknames passes it, tests use the default. `lastSeen` is the machine's
    /// stamp, and every offline banner carries it (DECK-15).
    func banner(naming: (PhoneRef) -> String = \.name, lastSeen: Date? = nil) -> Banner? {
        switch self {
        case .offline(let p, .unreachable):
            return Banner(text: "Can't reach \(naming(p)). Check that it's on the same Wi-Fi.", action: .tryNow,
                          lastSeen: lastSeen)
        case .offline(let p, .busy):
            return Banner(text: "Another Mac is connected to \(naming(p)).", action: .tryNow,
                          lastSeen: lastSeen)
        case .offline(let p, .connectionsOff):
            return Banner(text: "Connections are turned off on \(naming(p)).", action: nil,
                          detail: "Turn on Allow connections in Contigua on your phone.",
                          lastSeen: lastSeen)
        case .offline(let p, .notFound):
            return Banner(text: "Can't find \(naming(p)) on this network.", action: nil,
                          detail: "Check that the phone is on the same Wi-Fi and Contigua is running.",
                          lastSeen: lastSeen)
        case .offline(let p, .pairingsOff):
            return Banner(text: "\(naming(p)) isn't accepting new pairings.", action: nil,
                          lastSeen: lastSeen)
        case .offline(let p, .versionMismatch):
            return Banner(text: "\(naming(p)) runs an incompatible version of Contigua.", action: nil,
                          lastSeen: lastSeen)
        case .offline(_, .localNetworkDenied):
            return Banner(text: "Contigua needs Local Network access. Open System Settings → Privacy & Security → Local Network.",
                          action: .openSettings, lastSeen: lastSeen)
        case .needsPairing(let p):
            return Banner(text: "\(naming(p)) no longer trusts this Mac.", action: .pairAgain)
        case .pairing(_, .denied(let until)):
            return Banner(text: PairingCopy.denied, action: nil, countdownUntil: until)
        case .pairing(_, .coolingDown(let until)):
            return Banner(text: PairingCopy.coolingDown, action: nil, countdownUntil: until)
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
        case .needsPairing: return Chip(text: PairAgainCopy.banner, style: .orange)
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
    /// The advertised record for this phone now (PAIR-31/35): whether it is on
    /// the air, whether a last welcome address is dialable, and whether the
    /// record appeared or changed since the last report.
    case reachability(advertised: Bool, hasAddress: Bool, changed: Bool)
    /// Launch a phone whose record already says trust was lost (PAIR-32).
    case restoreTrustLost(PhoneRef, TrustLossKind)
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

    /// A closed name for the R4 link log (a failure keeps its reason code:
    /// those are the protocol's, and the log is what names the bug).
    var token: String {
        switch self {
        case .launch: return "launch"
        case .activate: return "activate"
        case .welcome: return "welcome"
        case .attemptFailed(let reason): return "fail:\(reason)"
        case .reachabilityHint: return "reachabilityHint"
        case .reachability: return "reachability"
        case .restoreTrustLost: return "restoreTrustLost"
        case .tryNow: return "tryNow"
        case .beginPairing: return "beginPairing"
        case .codeShown: return "codeShown"
        case .pairApproved: return "pairApproved"
        case .cancelPairing: return "cancelPairing"
        case .forget: return "forget"
        case .localNetworkDenied: return "localNetworkDenied"
        case .tick: return "tick"
        }
    }
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
    /// The inferred trust loss's quiet re-check (PAIR-31).
    static let trustRecheck: TimeInterval = 60
    /// Nothing advertised and no last address: say so instead of Connecting (PAIR-35).
    static let notFoundAfter: TimeInterval = 30
    /// The connections-off refusal's own cadence (PAIR-35).
    static let connectionsOffRetry: TimeInterval = 30
    /// The phone's post-deny window (Session.kt PairCooldown): the sheet counts
    /// from the deny or from the first `pair_cooldown` it hears (R2).
    static let cooldownWindow: TimeInterval = 30

    private(set) var link: Link = .idle
    private var outageStart: Date?
    private var failures = 0
    /// Consecutive closes right after TLS, before any `welcome` (PAIR-23): one
    /// may be a phone restarting, two in a row mean it refuses this Mac.
    private var earlyCloses = 0
    /// The phone rejected this Mac's certificate after our pin passed (PAIR-31),
    /// two in a row mean trust lost rather than a blip.
    private var certRejections = 0
    /// The trust-lost kind and when the inferred kind last rechecked.
    private(set) var trustLossKind: TrustLossKind?
    private var trustLastAttempt: Date?
    /// True from a trust re-check's attempt until its failure or welcome: the
    /// inferred state must never start a second dial over one in flight.
    private var trustAttemptPending = false
    /// What the controller last said about the advertised record (PAIR-31/35).
    private var advertised = false
    private var hasAddress = false
    /// Where to go back to when a pairing is cancelled.
    private var resume: Link = .idle
    /// [DECK-14/15] When this phone was last reached: the chip's help tag and
    /// the offline banner say it. Stamped by a welcome and by every tick of a
    /// live session, seeded at launch from the remembered record, and never
    /// inferred from a counter, a timer or another flag.
    private(set) var lastSeen: Date?

    init(link: Link = .idle, lastSeen: Date? = nil) {
        self.link = link
        self.lastSeen = lastSeen
    }

    /// Launch: seed the sighting this Mac remembered, so a phone that is away
    /// from the first second still says when it was here. A record with no
    /// stamp leaves it nil (the banner then says nothing).
    mutating func seedLastSeen(_ date: Date?) {
        guard lastSeen == nil, let date else { return }
        lastSeen = date
    }

    var consecutiveFailures: Int { failures }

    /// PAIR-36: the `--connect` launch's first pairing is still unresolved,
    /// from `.launch` until the link first reaches online, pairing or
    /// needsPairing, or another activation, a person's pairing or a forget.
    /// While it holds, the test entry point's retries may pair (a first dial
    /// that met `busy`, a phone not yet listening); after it only the person's
    /// Pair Again pairs, so a cancelled sheet never leaves a quiet pairing dial.
    private(set) var launchPairing = false

    @discardableResult
    mutating func handle(_ event: LinkEvent, at now: Date) -> [LinkAction] {
        let actions = step(event, at: now)
        switch event {
        case .launch(let phone): launchPairing = phone != nil
        case .activate, .beginPairing, .cancelPairing, .forget, .restoreTrustLost: launchPairing = false
        default: break
        }
        switch link {
        case .online, .pairing, .needsPairing: launchPairing = false
        default: break
        }
        return actions
    }

    private mutating func step(_ event: LinkEvent, at now: Date) -> [LinkAction] {
        switch event {
        case .launch(let phone):
            guard let phone else { link = .idle; return [] }
            link = .connecting(phone)
            outageStart = now
            failures = 0
            earlyCloses = 0
            certRejections = 0
            trustLossKind = nil
            trustAttemptPending = false
            advertised = false
            hasAddress = false
            return [.attempt(after: 0)]

        case .activate(let phone):
            // A trust-lost phone keeps its state when it becomes the phone in
            // use: only a pairing or a passing pin ends it (PAIR-32).
            if case .needsPairing = link, link.phone?.id == phone.id {
                if trustLossKind == .inferred {
                    trustLastAttempt = now
                    trustAttemptPending = true
                    return [.attempt(after: 0)]
                }
                return [.stopAttempts]
            }
            link = .connecting(phone)
            outageStart = now
            failures = 0
            earlyCloses = 0
            certRejections = 0
            trustLossKind = nil
            trustAttemptPending = false
            advertised = false
            hasAddress = false
            return [.attempt(after: 0)]

        case .restoreTrustLost(let phone, let kind):
            link = .needsPairing(phone)
            trustLossKind = kind
            trustLastAttempt = now
            trustAttemptPending = false
            outageStart = now
            failures = 0
            earlyCloses = 0
            certRejections = 0
            return kind == .told ? [.stopAttempts] : []

        case .welcome(let phone):
            link = .online(phone)
            lastSeen = now
            outageStart = nil
            failures = 0
            earlyCloses = 0
            certRejections = 0
            trustLossKind = nil
            trustAttemptPending = false
            return []

        case .attemptFailed(let reason):
            return failed(reason, at: now)

        case .reachability(let advertised, let hasAddress, let changed):
            self.advertised = advertised
            self.hasAddress = hasAddress
            if trustLossKind == .inferred, case .needsPairing = link,
               advertised, changed, !trustAttemptPending {
                trustLastAttempt = now
                trustAttemptPending = true
                return [.attempt(after: 0)]
            }
            if case .offline(_, .connectionsOff) = link, advertised, changed {
                failures = 0
                return [.attempt(after: 0)]
            }
            if case .offline(_, .notFound) = link, advertised {
                // The phone is back on the air: the "Can't find" sentence is no
                // longer true, so the attempt starts from a connecting link and
                // a failure follows the usual 15 s sentence.
                if case .offline(let p, _) = link { link = .connecting(p) }
                outageStart = now
                failures = 0
                trustLastAttempt = now
                return [.attempt(after: 0)]
            }
            return []

        case .reachabilityHint, .tryNow:
            guard link.isRecovering || isRetryable(event) else { return [] }
            failures = 0
            earlyCloses = 0
            return [.attempt(after: 0)]

        case .beginPairing(let phone):
            trustAttemptPending = false
            // A re-pair forgets the old pin, so the inferred premise (our pin
            // did not match) is gone: the person is now in control, and a
            // cancelled sheet must not leave a quiet dial that could re-pin
            // without the code flow. Keep the state as the sticky kind.
            if trustLossKind == .inferred { trustLossKind = .told }
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
            trustLossKind = nil
            trustAttemptPending = false
            return [.stopAttempts]

        case .localNetworkDenied:
            guard let phone = link.phone else { return [] }
            link = .offline(phone, .localNetworkDenied)
            return [.stopAttempts]

        case .tick:
            // A live session is a sighting: the stamp is the last contact, not
            // the moment it dropped (DECK-14/15).
            if case .online = link { lastSeen = now }
            // The inferred kind's quiet re-check (PAIR-31): the advertisement
            // may be a spoof, so this never becomes a permanent stop. While it
            // is advertised, one attempt per 60 s; while it is not, the kept
            // last address gets the normal backoff, and with neither there is
            // nothing to dial until the record appears.
            if trustLossKind == .inferred, case .needsPairing = link {
                let last = trustLastAttempt ?? outageStart
                if advertised {
                    if !trustAttemptPending, let last,
                       now.timeIntervalSince(last) >= Self.trustRecheck {
                        trustLastAttempt = now
                        trustAttemptPending = true
                        return [.attempt(after: 0)]
                    }
                } else if hasAddress {
                    let delay = ReconnectPolicy.delay(afterFailures: failures)
                    if !trustAttemptPending, let last, now.timeIntervalSince(last) >= delay {
                        trustLastAttempt = now
                        trustAttemptPending = true
                        return [.attempt(after: 0)]
                    }
                } else {
                    return []
                }
            }
            switch link {
            case .connecting(let p), .reconnecting(let p), .offline(let p, .unreachable):
                if let start = outageStart, now.timeIntervalSince(start) >= Self.notFoundAfter,
                   !advertised, !hasAddress {
                    link = .offline(p, .notFound)
                } else if let start = outageStart, now.timeIntervalSince(start) >= Self.offlineAfter,
                          advertised || hasAddress {
                    // With neither an advertisement nor an address there is
                    // nothing to reach yet; PAIR-35 says so at 30 s instead.
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
            case "pair_denied":
                link = .pairing(phone, .denied(until: now.addingTimeInterval(Self.cooldownWindow)))
            case "pair_cooldown":
                link = .pairing(phone, .coolingDown(until: now.addingTimeInterval(Self.cooldownWindow)))
            case "pair_timeout": link = .pairing(phone, .timedOut)
            case "connections_off", "pairing_off", "pair_exporter":
                link = .pairing(phone, .refused(reason))
            default: link = .pairing(phone, .unreachable)
            }
            return []
        }
        guard let phone = link.phone else { return [] }
        trustAttemptPending = false
        switch reason {
        case "pair_cooldown":
            // A launch that meets a phone inside its 30 s window: the person
            // is pairing (or just tried to), so the sheet says to wait rather
            // than leaving a silent offline link (PAIR-5). The deadline is the
            // upper bound: the Mac did not see the deny that opened it (R2).
            link = .pairing(phone, .coolingDown(until: now.addingTimeInterval(Self.cooldownWindow)))
            return [.stopAttempts]
        case "forgotten":
            // The phone's own authenticated word (PAIR-30): no attempt can fix
            // it and the person must re-pair.
            trustLossKind = .told
            link = .needsPairing(phone)
            return [.stopAttempts]
        case "pin-mismatch":
            // Our pin did not match a phone that is the same device (the
            // controller resolved the advertisement): inferred trust lost. The
            // TXT id is unauthenticated, so quiet re-checks continue (PAIR-31).
            trustLossKind = .inferred
            trustLastAttempt = now
            link = .needsPairing(phone)
            // While the record is advertised the 60 s tick is the re-check;
            // with no advertisement the kept last address still gets the
            // normal backoff (PAIR-31/35), never a tight loop.
            if !advertised, hasAddress {
                failures += 1
                trustAttemptPending = true
                return [.attempt(after: ReconnectPolicy.delay(afterFailures: failures))]
            }
            return []
        case "bad_pin", "no-pin", "not_paired":
            // v2: the TLS-level pairing state died, or the phone no longer pins
            // this Mac at all (PAIR-23); retries never fix it, the re-pair hint
            // handles the person's next step.
            //
            // A retry to a phone whose pairing switch is off cannot present a
            // pin at all, so its `no-pin` is that same refusal, not a lost key:
            // the sentence and the backoff stay (PAIR-13).
            if reason == "no-pin", case .offline(_, .pairingsOff) = link {
                failures += 1
                return [.attempt(after: ReconnectPolicy.delay(afterFailures: failures))]
            }
            trustLossKind = .told
            link = .needsPairing(phone)
            return [.stopAttempts]
        case "certificate_unknown", "bad_certificate":
            // The phone rejected this Mac's certificate after our own pin
            // passed (a Mac identity it does not know): one may be a restart,
            // two in a row is a refusal (PAIR-31, PAIR-23's rule).
            certRejections += 1
            if certRejections >= 2 {
                trustLossKind = .told
                link = .needsPairing(phone)
                return [.stopAttempts]
            }
            failures += 1
            if case .online = link {
                link = .reconnecting(phone)
                outageStart = now
            }
            return [.attempt(after: ReconnectPolicy.delay(afterFailures: failures))]
        case "closed-early":
            // A phone that pins nothing for this Mac closes right after TLS
            // without a word when its pairings are off (PAIR-23). One such
            // close may be the phone restarting; twice in a row is a refusal.
            earlyCloses += 1
            if earlyCloses >= 2 {
                link = .needsPairing(phone)
                return [.stopAttempts]
            }
            failures += 1
            if case .online = link {
                link = .reconnecting(phone)
                outageStart = now
            }
            return [.attempt(after: ReconnectPolicy.delay(afterFailures: failures))]
        case "version":
            link = .offline(phone, .versionMismatch)
            return [.stopAttempts]
        case "pair_denied":
            return []
        case "busy":
            failures += 1
            link = .offline(phone, .busy)
            return [.attempt(after: max(ReconnectPolicy.delay(afterFailures: failures), 15))]
        case "connections_off":
            // The phone's switch may come back: one attempt per 30 s (plus one
            // on a new advertisement, in `.reachability`), never a loop.
            failures += 1
            link = .offline(phone, .connectionsOff)
            return [.attempt(after: Self.connectionsOffRetry)]
        case "pairing_off":
            failures += 1
            link = .offline(phone, .pairingsOff)
            return [.attempt(after: ReconnectPolicy.delay(afterFailures: failures))]
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

// MARK: - One presentation for every surface (R1)

/// What the Deck, the menu-bar panel and the Settings row show for one Link
/// value. Pure, so the table test can walk every state and prove the three
/// surfaces never disagree (AGENTS.md: one truth, one derivation).
struct LinkPresentation: Equatable {
    var banner: Banner?
    /// The Deck's app grid and its Phone button are live only online.
    var deckInteractive: Bool
    var panelNotice: Banner?
    var settingsPresence: DevicePresence
    var chip: Chip?

    init(link: Link, naming: @escaping (PhoneRef) -> String = { $0.name },
         lastSeen: Date? = nil) {
        banner = link.banner(naming: naming, lastSeen: lastSeen)
        deckInteractive = link.isOnline
        panelNotice = PhonePanelNotice.banner(for: link, naming: naming, lastSeen: lastSeen)
        settingsPresence = DevicePresence(link)
        chip = link.chip
    }
}
