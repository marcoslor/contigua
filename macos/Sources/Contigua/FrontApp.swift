// The app in front on the phone (docs/PROTOCOL.md "Foreground app", PANEL-26).
//
// A pull, not a watch: the Mac asks `task.front` only while the card is open —
// once when it opens and again 2 s after the last request, the card's or an
// MCP read's (the shared budget, FrontReadMachine) — and the phone
// reads its own task list once per request. The state is one small machine so
// a late reply cannot overwrite a newer answer, and the panel shows the row
// only while the machine knows a package; `pkg: null` (home, our app, SystemUI)
// hides it without a disabled placeholder.

import AppKit

/// The last answer the phone gave, kept on show while the next one is asked.
enum FrontAppAnswer: Equatable {
    /// No answer yet (since launch, a reset or a change of phone).
    case unanswered
    case none
    case pkg(String)
}

/// What the Mac knows about the phone's foreground app.
enum FrontAppState: Equatable {
    case idle
    /// A request is out. `showing` is the answer before it: the card asks
    /// again every 2 s while it is open, and the row must not blink out
    /// between each question and its answer.
    case asking(seq: Int, showing: FrontAppAnswer = .unanswered)
    case known(pkg: String)
    case none
}

/// The foreground machine: Idle -> Asking(seq) on every request, carrying the
/// answer on show; Asking(seq) -> Known(pkg) or None on that request's reply;
/// any -> Idle when the link goes or the phone in use changes. Only a reply
/// for the newest request moves it; an older one is stale and ignored.
struct FrontAppMachine: Equatable {
    private(set) var state: FrontAppState = .idle

    mutating func ask(seq: Int) {
        state = .asking(seq: seq, showing: answer)
    }

    /// Returns true when the reply was for the newest request.
    @discardableResult
    mutating func reply(seq: Int, pkg: String?) -> Bool {
        guard case .asking(let expected, _) = state, seq == expected else { return false }
        state = pkg.map(FrontAppState.known) ?? .none
        return true
    }

    mutating func reset() {
        state = .idle
    }

    /// The answer the views show: the newest reply, or the one before it
    /// while a request is out.
    var answer: FrontAppAnswer {
        switch state {
        case .idle: return .unanswered
        case .asking(_, let showing): return showing
        case .known(let pkg): return .pkg(pkg)
        case .none: return .none
        }
    }

    var pkg: String? {
        if case .pkg(let pkg) = answer { return pkg }
        return nil
    }

    var isNone: Bool { answer == .none }
}

/// How long a reply stays usable to the Phone menu and the menu bar's item,
/// which never poll for it: the panel's own two-second cadence plus slack. The
/// panel's row follows the machine, not this window.
enum FrontAppFreshness {
    static let window: TimeInterval = 2

    static func isFresh(_ at: Date?, now: Date = Date()) -> Bool {
        guard let at else { return false }
        return now.timeIntervalSince(at) <= window
    }
}

/// The panel's "Open <App> on Mac" row and the Phone menu's item: the package
/// the phone reported and, when the app list knows it, the app's label and
/// icon. A package the list does not know keeps the fallback words with a
/// generic icon.
struct FrontAppRow: Equatable {
    var pkg: String
    var label: String?
    var icon: NSImage?

    var title: String {
        guard let label, !label.isEmpty else { return "Open Current App on Mac" }
        return "Open \(label) on Mac"
    }

    /// What the row does, with the shortcut: for the help tag and VoiceOver.
    var help: String {
        guard let label, !label.isEmpty else { return FrontAppRow.genericHelp }
        return "Moves \(label) from your phone's screen into its own Mac window, where you left off (⇧⌘C)"
    }

    static let genericHelp =
        "Moves the app on your phone's screen into its own Mac window, where you left off (⇧⌘C)"

    /// The words a menu item must always have when there is nothing fresh to
    /// name, or the fresh reply says nothing is in front.
    static let fallbackTitle = "Open Current App on Mac"
    /// The sentence a disabled menu item carries when the phone says its
    /// screen has nothing to open.
    static let nothingToOpen =
        "Nothing to move. Your phone is showing its home screen or Contigua."
}

/// One `task.front` read as an MCP `phone_status` call sees it (MCP-32).
enum FrontRead: Hashable {
    case pkg(String)
    /// The phone answered `pkg: null`: nothing continuable in front.
    case none
    /// The phone answered `not_available`.
    case notSupported
    /// No answer within the call's 1 s.
    case timeout
}

/// The shared 2 s budget on `task.front` (PROTOCOL.md "Foreground app" §3,
/// MCP-32, PANEL-26) as one pure machine: the panel's card and every MCP
/// client ask through it, and a request less than 2 s after the last one,
/// from either, reuses that answer.
///
/// Phases: Idle (no request since launch or a reset); Out(at) (a request
/// asked at `at`, its reply not in); Answered(at, read). Events and what
/// they do:
/// - `ask(now)`: from Idle, or 2 s or more after the last request, a new
///   request (`seq + 1`, Out, `send`); under 2 s, nothing.
/// - `read(waiter, now)`: an `ask`, then the answer at once when the request
///   is answered, else the waiter waits for this `seq` (`startTimer`).
/// - `reply(seq, pkg)`: for the newest request while Out, Answered with
///   `pkg` or None, and that request's waiters answered; any other reply
///   (an older seq, a second reply, none asked) is stale and ignored.
/// - `unavailable` (`not_available`, no seq): answers the request Out
///   `notSupported`; with none out, ignored.
/// - `reset` (link loss, phone change): `seq + 1`, Idle, every waiter
///   answered `timeout`, so any reply in flight is stale.
/// - `expired(waiter)`: a waiter's 1 s ran out: answered `timeout`; one
///   already answered, ignored.
struct FrontReadMachine: Equatable {
    static let budget: Duration = .seconds(2)

    enum Phase: Equatable {
        case idle
        case out(at: ContinuousClock.Instant)
        case answered(at: ContinuousClock.Instant, FrontRead)
    }

    enum Event: Equatable {
        case ask(now: ContinuousClock.Instant)
        case read(waiter: Int, now: ContinuousClock.Instant)
        case reply(seq: Int, pkg: String?)
        case unavailable
        case reset
        case expired(waiter: Int)
    }

    enum Action: Hashable {
        /// Send `task.front` with this seq.
        case send(seq: Int)
        /// Resume this waiter with this read.
        case answer(waiter: Int, FrontRead)
        /// Start this waiter's 1 s; its end is `expired`.
        case startTimer(waiter: Int)
    }

    private(set) var seq = 0
    private(set) var phase: Phase = .idle
    /// Each waiting read and the seq it waits for.
    private(set) var waiters: [Int: Int] = [:]

    /// When the last request went out; nil while Idle.
    var askedAt: ContinuousClock.Instant? {
        switch phase {
        case .idle: return nil
        case .out(let at), .answered(let at, _): return at
        }
    }

    /// The first moment an `ask` sends again: 2 s after the last request,
    /// whoever asked it (PANEL-26: the card's next ask); nil while Idle.
    var nextAsk: ContinuousClock.Instant? { askedAt.map { $0 + Self.budget } }

    static func step(_ state: FrontReadMachine, _ event: Event) -> (FrontReadMachine, [Action]) {
        var next = state
        var actions: [Action] = []
        switch event {
        case .ask(let now):
            actions = next.ask(now)
        case .read(let waiter, let now):
            actions = next.ask(now)
            if case .answered(_, let read) = next.phase {
                actions.append(.answer(waiter: waiter, read))
            } else {
                next.waiters[waiter] = next.seq
                actions.append(.startTimer(waiter: waiter))
            }
        case .reply(let seq, let pkg):
            guard case .out(let at) = next.phase, seq == next.seq else { return (state, []) }
            actions = next.settle(at: at, pkg.map(FrontRead.pkg) ?? .none)
        case .unavailable:
            guard case .out(let at) = next.phase else { return (state, []) }
            actions = next.settle(at: at, .notSupported)
        case .reset:
            next.seq += 1
            next.phase = .idle
            actions = next.waiters.keys.sorted().map { .answer(waiter: $0, .timeout) }
            next.waiters = [:]
        case .expired(let waiter):
            guard next.waiters.removeValue(forKey: waiter) != nil else { return (state, []) }
            actions = [.answer(waiter: waiter, .timeout)]
        }
        return (next, actions)
    }

    private mutating func ask(_ now: ContinuousClock.Instant) -> [Action] {
        if let askedAt, now - askedAt < Self.budget { return [] }
        seq += 1
        phase = .out(at: now)
        return [.send(seq: seq)]
    }

    private mutating func settle(at: ContinuousClock.Instant, _ read: FrontRead) -> [Action] {
        phase = .answered(at: at, read)
        let answered = waiters.filter { $0.value == seq }.keys.sorted()
        for waiter in answered { waiters[waiter] = nil }
        return answered.map { .answer(waiter: $0, read) }
    }
}

/// The machine's shell: the clock, the `task.front` send, the waiters'
/// continuations and their 1 s timers. Every decision is the machine's.
@MainActor
final class FrontReadGate {
    static let budget = FrontReadMachine.budget
    static let wait: Duration = .seconds(1)

    /// Sends one `task.front` with this seq.
    var send: ((Int) -> Void)?
    private(set) var machine = FrontReadMachine()
    var seq: Int { machine.seq }
    /// When the next ask sends (PANEL-26: the card schedules its next ask
    /// here); nil while no request has gone out.
    var nextAsk: ContinuousClock.Instant? { machine.nextAsk }
    private let now: () -> ContinuousClock.Instant
    private var continuations: [Int: CheckedContinuation<FrontRead, Never>] = [:]
    private var nextWaiter = 0

    init(now: @escaping () -> ContinuousClock.Instant = { .now }) {
        self.now = now
    }

    /// The panel's ask: sends unless a request went out less than 2 s ago.
    @discardableResult
    func ask() -> Bool {
        let actions = step(.ask(now: now()))
        return actions.contains { if case .send = $0 { return true } else { return false } }
    }

    /// An MCP read: the answer of a request less than 2 s old, or a new one;
    /// `timeout` when no answer comes within `wait`.
    func read(wait: Duration = FrontReadGate.wait) async -> FrontRead {
        let id = nextWaiter
        nextWaiter += 1
        return await withCheckedContinuation { continuation in
            continuations[id] = continuation
            step(.read(waiter: id, now: now()), wait: wait)
        }
    }

    func reply(seq: Int, pkg: String?) {
        step(.reply(seq: seq, pkg: pkg))
    }

    /// `not_available`, which carries no seq: it answers the newest request.
    func unavailable() {
        step(.unavailable)
    }

    func reset() {
        step(.reset)
    }

    @discardableResult
    private func step(_ event: FrontReadMachine.Event, wait: Duration = FrontReadGate.wait) -> [FrontReadMachine.Action] {
        let (next, actions) = FrontReadMachine.step(machine, event)
        machine = next
        for action in actions {
            switch action {
            case .send(let seq):
                send?(seq)
            case .answer(let waiter, let read):
                continuations.removeValue(forKey: waiter)?.resume(returning: read)
            case .startTimer(let waiter):
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: wait)
                    self?.step(.expired(waiter: waiter))
                }
            }
        }
        return actions
    }
}
