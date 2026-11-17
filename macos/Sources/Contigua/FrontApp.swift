// The app in front on the phone (docs/PROTOCOL.md "Foreground app", PANEL-26).
//
// A pull, not a watch: the Mac asks `task.front` only while the card is open —
// once when it opens and at most once every 2 s after that — and the phone
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
enum FrontRead: Equatable {
    case pkg(String)
    /// The phone answered `pkg: null`: nothing continuable in front.
    case none
    /// The phone answered `not_available`.
    case notSupported
    /// No answer within the call's 1 s.
    case timeout
}

/// The shared 2 s budget on `task.front` (PROTOCOL.md "Foreground app" §3):
/// the panel's card and every MCP client ask through it, and a request less
/// than 2 s after the last one, from either, reuses that answer. Its states:
/// no request; a request out (waiters queued); a request answered. A reply
/// for an older seq is stale; `reset` (link loss, phone change) bumps the seq
/// and answers every waiter `timeout`.
@MainActor
final class FrontReadGate {
    static let budget: Duration = .seconds(2)
    static let wait: Duration = .seconds(1)

    /// Sends one `task.front` with this seq.
    var send: ((Int) -> Void)?
    private(set) var seq = 0
    private let now: () -> ContinuousClock.Instant
    private var askedAt: ContinuousClock.Instant?
    private var answer: FrontRead?
    private var waiters: [Int: (seq: Int, resume: CheckedContinuation<FrontRead, Never>)] = [:]
    private var nextWaiter = 0

    init(now: @escaping () -> ContinuousClock.Instant = { .now }) {
        self.now = now
    }

    /// The panel's ask: sends unless a request went out less than 2 s ago.
    @discardableResult
    func ask() -> Bool {
        if let askedAt, now() - askedAt < Self.budget { return false }
        seq += 1
        askedAt = now()
        answer = nil
        send?(seq)
        return true
    }

    /// An MCP read: the answer of a request less than 2 s old, or a new one;
    /// `timeout` when no answer comes within `wait`.
    func read(wait: Duration = FrontReadGate.wait) async -> FrontRead {
        ask()
        if let answer { return answer }
        let id = nextWaiter
        nextWaiter += 1
        let expected = seq
        return await withCheckedContinuation { continuation in
            waiters[id] = (expected, continuation)
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: wait)
                self?.finish(id, .timeout)
            }
        }
    }

    func reply(seq: Int, pkg: String?) {
        guard seq == self.seq, answer == nil else { return }
        settle(pkg.map(FrontRead.pkg) ?? .none)
    }

    /// `not_available`, which carries no seq: it answers the newest request.
    func unavailable() {
        guard askedAt != nil, answer == nil else { return }
        settle(.notSupported)
    }

    func reset() {
        seq += 1
        askedAt = nil
        answer = nil
        for id in Array(waiters.keys) { finish(id, .timeout) }
    }

    private func settle(_ read: FrontRead) {
        answer = read
        for (id, waiter) in waiters where waiter.seq == seq { finish(id, read) }
    }

    private func finish(_ id: Int, _ read: FrontRead) {
        guard let waiter = waiters.removeValue(forKey: id) else { return }
        waiter.resume.resume(returning: read)
    }
}
