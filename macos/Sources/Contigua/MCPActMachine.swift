// One act call (docs/specs/mcp.md "One act call", docs/design/mcp.md "Settle
// and observe"): queue on the window → press, type or send → settle → read →
// answer, with the window closing, the link dropping, the deadline and the
// client leaving as events from every state.
//
// Pure: `step(machine, event) -> (machine, actions)`. The runner
// (`MCPActRunner`) owns the continuation, the deadline timer and the phone's
// seq; the machine numbers its own requests (`req`) so a late reply, one the
// call no longer waits on, is ignored here.

import Foundation

/// `wait` on a tool that acts, opens or reads (MCP-81).
enum MCPWait: String, Equatable, CaseIterable {
    case settle, none
}

/// `observe`: the screen an action returns after its settle (MCP-82). The
/// `text` view (MCP-74) ships with T9.
enum MCPObserve: String, Equatable, CaseIterable {
    case tree, none
}

struct MCPActMachine: Equatable {
    /// Fixed by MCP-81: no tool argument changes them.
    static let quietMs = 300
    static let timeoutMs = 2000

    /// How the input reaches the phone: as input frames (a point, a key, a
    /// swipe, and S1's ref tap), as `ui.press` (T10) or as `ui.type` (T13).
    enum Path: Equatable {
        case input, press, type
    }

    enum State: Equatable {
        case queued
        case opening
        case pressing
        case typing
        case sent
        case settling(Int)
        case observing(Int)
        case done
    }

    /// The window when the call's turn comes (MCP-85).
    enum Condition: Equatable {
        case live
        case notReady
        case gone
        case phoneOffline
    }

    struct Settle: Equatable {
        var state: String
        var waitedMs: Int?
        var reason: String?

        init(state: String, waitedMs: Int? = nil, reason: String? = nil) {
            self.state = state
            self.waitedMs = waitedMs
            self.reason = reason
        }
    }

    struct Closed: Equatable {
        let reason: String
        let by: String
    }

    /// What the answer says beyond `did` and `on`. `state` is set only when
    /// the call itself knows it (closed, offline, opening); otherwise the
    /// window's state when the answer is made.
    struct Answer: Equatable {
        var settle: Settle
        var state: String?
        var closed: Closed?
        /// The observed tree, as the `ui_tree` answer's JSON text.
        var tree: String?
        var treeError: String?
        var alsoActed: [String]
        var entry: String?
        var via: String?

        init(settle: Settle, state: String? = nil, closed: Closed? = nil, tree: String? = nil,
             treeError: String? = nil, alsoActed: [String] = [], entry: String? = nil,
             via: String? = nil) {
            self.settle = settle
            self.state = state
            self.closed = closed
            self.tree = tree
            self.treeError = treeError
            self.alsoActed = alsoActed
            self.entry = entry
            self.via = via
        }
    }

    enum Event: Equatable {
        /// The window's queue reached the call.
        case turn(Condition)
        /// S1: the ref was checked against the window's latest tree and
        /// refused (`stale_ref`, `off_screen`); nothing is pressed.
        case refused(String)
        case pressOK
        case pressFailed(String)
        case typeOK(entry: String, via: String)
        case typeFailed(String)
        /// An open's window and first frame both arrived (T6).
        case opened
        case openBound
        case openFailed(String)
        /// Entering Sent: the input is on the phone.
        case entry
        case settleReply(req: Int, settled: Bool, waitedMs: Int, reason: String?)
        case settleFailed(req: Int, code: String)
        case treeReply(req: Int, String)
        case treeFailed(req: Int, code: String)
        case windowClosed(reason: String, by: String)
        case linkLost
        case deadline(waitedMs: Int)
        case clientGone
        case otherInput(String)
    }

    enum Action: Equatable {
        case sendInput
        case sendPress
        case sendType
        case sendSettle(req: Int, quietMs: Int, timeoutMs: Int)
        case sendTree(req: Int)
        case answer(Answer)
        case fail(String)
    }

    var state: State
    let path: Path
    let wait: MCPWait
    let observe: MCPObserve
    var alsoActed: [String] = []
    var nextReq = 1
    /// The settle's outcome, once known.
    var settle: Settle?
    var entry: String?
    var via: String?

    init(path: Path, wait: MCPWait, observe: MCPObserve) {
        self.state = .queued
        self.path = path
        self.wait = wait
        self.observe = observe
    }

    /// `open_app` and `send_link` enter at Opening (T6).
    init(opening wait: MCPWait, observe: MCPObserve) {
        self.init(path: .input, wait: wait, observe: observe)
        state = .opening
    }

    /// `screenshot` with `wait: "settle"` enters at Sent with no input (MCP-64).
    init(screenshotWaiting: Void) {
        self.init(path: .input, wait: .settle, observe: .none)
        state = .sent
    }

    static func step(_ machine: MCPActMachine, _ event: Event) -> (MCPActMachine, [Action]) {
        var m = machine
        var actions = m.handle(event)
        // Sent is passed through: its entry decides the next state at once.
        if m.state == .sent, event != .entry {
            actions += m.handle(.entry)
        }
        return (m, actions)
    }

    private mutating func handle(_ event: Event) -> [Action] {
        if state == .done { return [] }
        switch event {
        case .otherInput(let source):
            if !alsoActed.contains(source) { alsoActed.append(source) }
            return []
        case .clientGone:
            state = .done
            return []
        case .deadline(let waitedMs):
            return onDeadline(waitedMs)
        case .linkLost:
            switch state {
            case .queued, .opening, .pressing, .typing:
                return finish(.fail("phone_offline"))
            case .sent, .settling, .observing:
                return finish(answer(settle: Settle(state: "interrupted"), state: "offline"))
            case .done:
                return []
            }
        case .windowClosed(let reason, let by):
            switch state {
            case .queued, .opening, .pressing, .typing:
                return finish(.fail("no_window"))
            case .sent, .settling, .observing:
                return finish(answer(settle: Settle(state: "window_closed"), state: "closed",
                                     closed: Closed(reason: reason, by: by)))
            case .done:
                return []
            }
        default:
            break
        }

        switch (state, event) {
        case (.queued, .turn(let condition)):
            switch condition {
            case .live:
                switch path {
                case .press:
                    state = .pressing
                    return [.sendPress]
                case .type:
                    state = .typing
                    return [.sendType]
                case .input:
                    state = .sent
                    return [.sendInput]
                }
            case .notReady: return finish(.fail("not_ready"))
            case .gone: return finish(.fail("no_window"))
            case .phoneOffline: return finish(.fail("phone_offline"))
            }
        case (.queued, .refused(let code)):
            return finish(.fail(code))

        case (.pressing, .pressOK):
            state = .sent
            return []
        case (.pressing, .pressFailed(let why)):
            switch why {
            case "off_screen": return finish(.fail("off_screen"))
            case "covered": return finish(.fail("covered"))
            default: return finish(.fail("stale_ref"))  // gone, not_visible
            }

        case (.typing, .typeOK(let entry, let via)):
            self.entry = entry
            self.via = via
            state = .sent
            return []
        case (.typing, .typeFailed(let code)):
            return finish(.fail(code))

        case (.opening, .opened):
            state = .sent
            return []
        case (.opening, .openBound):
            return finish(answer(settle: Settle(state: "not_ready"), state: "opening"))
        case (.opening, .openFailed(let code)):
            return finish(.fail(code))

        case (.sent, .entry):
            switch wait {
            case .settle:
                let req = takeReq()
                state = .settling(req)
                return [.sendSettle(req: req, quietMs: Self.quietMs, timeoutMs: Self.timeoutMs)]
            case .none:
                settle = Settle(state: "not_waited")
                return observeOrAnswer()
            }

        case (.settling(let req), .settleReply(let got, let settled, let waitedMs, let reason)) where got == req:
            settle = settled
                ? Settle(state: "settled", waitedMs: waitedMs)
                : Settle(state: "still_changing", waitedMs: waitedMs, reason: reason ?? "changes")
            return observeOrAnswer()
        case (.settling(let req), .settleFailed(let got, let code)) where got == req:
            // A Mac-side timeout of the settle read is the screen not settling
            // in time; anything else is a phone that cannot watch (MCP-81).
            settle = code == "timeout"
                ? Settle(state: "still_changing", waitedMs: Self.timeoutMs, reason: "changes")
                : Settle(state: "unavailable")
            return observeOrAnswer()

        case (.observing(let req), .treeReply(let got, let tree)) where got == req:
            return finish(answer(settle: settle ?? Settle(state: "not_waited"), tree: tree))
        case (.observing(let req), .treeFailed(let got, let code)) where got == req:
            return finish(answer(settle: settle ?? Settle(state: "not_waited"), treeError: code))

        default:
            // A late or early reply, or an event this state does not take.
            return []
        }
    }

    private mutating func onDeadline(_ waitedMs: Int) -> [Action] {
        switch state {
        case .queued, .opening, .pressing, .typing:
            if state == .opening {
                return finish(answer(settle: Settle(state: "not_ready"), state: "opening"))
            }
            return finish(.fail("timeout"))
        case .sent, .settling:
            return finish(answer(settle: Settle(state: "still_changing", waitedMs: waitedMs,
                                                reason: "changes")))
        case .observing:
            return finish(answer(settle: settle ?? Settle(state: "not_waited"), treeError: "timeout"))
        case .done:
            return []
        }
    }

    private mutating func observeOrAnswer() -> [Action] {
        switch observe {
        case .tree:
            let req = takeReq()
            state = .observing(req)
            return [.sendTree(req: req)]
        case .none:
            return finish(answer(settle: settle ?? Settle(state: "not_waited")))
        }
    }

    private mutating func takeReq() -> Int {
        let req = nextReq
        nextReq += 1
        return req
    }

    private func answer(settle: Settle, state: String? = nil, closed: Closed? = nil,
                        tree: String? = nil, treeError: String? = nil) -> Action {
        .answer(Answer(settle: settle, state: state, closed: closed, tree: tree,
                       treeError: treeError, alsoActed: alsoActed, entry: entry, via: via))
    }

    private mutating func finish(_ action: Action) -> [Action] {
        state = .done
        return [action]
    }
}
