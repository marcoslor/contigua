// One act call (docs/specs/mcp.md "One act call", MCP-8, MCP-80…87, MCP-107,
// MCP-108): every row of the table is one `(state, event) → (state, actions)`
// asserted exactly. The answer's `did` and `on` are pure functions of the call
// and the window's latest tree, tested here too.

import XCTest
@testable import Contigua

final class MCPActMachineTests: XCTestCase {
    typealias M = MCPActMachine

    private func machine(_ state: M.State, path: M.Path = .input, wait: MCPWait = .settle,
                         observe: MCPObserve = .tree, settle: M.Settle? = nil,
                         nextReq: Int = 1) -> M {
        var m = M(path: path, wait: wait, observe: observe)
        m.state = state
        m.settle = settle
        m.nextReq = nextReq
        return m
    }

    private func step(_ m: M, _ e: M.Event) -> (M.State, [M.Action], M) {
        let (next, actions) = M.step(m, e)
        return (next.state, actions, next)
    }

    private let settled412 = M.Settle(state: "settled", waitedMs: 412, reason: nil)

    // MARK: Queued

    func testATurnOnALiveWindowSendsTheInputAndSettles_MCP81() {
        var (state, actions, m) = step(machine(.queued), .turn(.live))
        XCTAssertEqual(state, .sending)
        XCTAssertEqual(actions, [.sendInput])
        (state, actions, m) = step(m, .inputSent)
        XCTAssertEqual(state, .settling(1))
        XCTAssertEqual(actions, [.sendSettle(req: 1, quietMs: 300, timeoutMs: 2000)])
    }

    func testATurnOnALiveWindowPressesARef() {
        let (state, actions, _) = step(machine(.queued, path: .press), .turn(.live))
        XCTAssertEqual(state, .pressing)
        XCTAssertEqual(actions, [.sendPress])
    }

    func testATurnOnALiveWindowTypes() {
        let (state, actions, _) = step(machine(.queued, path: .type), .turn(.live))
        XCTAssertEqual(state, .typing)
        XCTAssertEqual(actions, [.sendType])
    }

    func testNoInputBeforeTheWindowIsLive_MCP85() {
        let (state, actions, _) = step(machine(.queued), .turn(.notReady))
        XCTAssertEqual(state, .done)
        XCTAssertEqual(actions, [.fail("not_ready")])
        XCTAssertFalse(actions.contains(.sendInput))
    }

    func testATurnOnAGoneWindowFailsNoWindow_MCP85() {
        let (state, actions, _) = step(machine(.queued), .turn(.gone))
        XCTAssertEqual(state, .done)
        XCTAssertEqual(actions, [.fail("no_window")])
    }

    func testATurnWithThePhoneOfflineFailsPhoneOffline_MCP85() {
        let (state, actions, _) = step(machine(.queued), .turn(.phoneOffline))
        XCTAssertEqual(state, .done)
        XCTAssertEqual(actions, [.fail("phone_offline")])
    }

    func testARefusedRefPressesNothing_MCP108() {
        for code in ["stale_ref", "off_screen"] {
            let (state, actions, _) = step(machine(.queued), .refused(code))
            XCTAssertEqual(state, .done)
            XCTAssertEqual(actions, [.fail(code)])
        }
    }

    // MARK: Pressing and Typing (T10, T13)

    func testAPressThatLandedIsSent() {
        let (state, actions, _) = step(machine(.pressing, wait: .none, observe: .none), .pressOK)
        XCTAssertEqual(state, .done)
        XCTAssertEqual(actions, [.answer(M.Answer(settle: M.Settle(state: "not_waited")))])
    }

    func testAPressThatFailedNamesWhy() {
        let cases = [("gone", "stale_ref"), ("not_visible", "stale_ref"),
                     ("off_screen", "off_screen"), ("covered", "covered"),
                     // T10 (MCP-86, #188): a relabelled node is stale; the
                     // phone's and the link's own failures keep their codes.
                     ("changed", "stale_ref"), ("no_window", "no_window"),
                     ("timeout", "timeout"), ("phone_offline", "phone_offline"),
                     ("busy", "failed"), ("failed", "failed")]
        for (phone, code) in cases {
            let (state, actions, _) = step(machine(.pressing), .pressFailed(phone))
            XCTAssertEqual(state, .done, phone)
            XCTAssertEqual(actions, [.fail(code)], phone)
        }
    }

    func testTypedTextIsSentWithItsEntry() {
        let (state, actions, _) = step(machine(.typing, wait: .none, observe: .none),
                                       .typeOK(entry: "inserted", via: "keys"))
        XCTAssertEqual(state, .done)
        XCTAssertEqual(actions, [.answer(M.Answer(settle: M.Settle(state: "not_waited"),
                                                  entry: "inserted", via: "keys"))])
    }

    func testTypingThatFailedFailsWithItsCode() {
        for code in ["no_field", "not_supported", "failed"] {
            let (state, actions, _) = step(machine(.typing), .typeFailed(code))
            XCTAssertEqual(state, .done)
            XCTAssertEqual(actions, [.fail(code)])
        }
    }

    /// The Typing state's rows (plan T13): a turn types, the phone's answer
    /// goes on to the settle with its `entry` and `via`, its refusal ends the
    /// call with its code, and a window or link gone while typing fails
    /// ([MCP-109]).
    func testTypingWalksItsRows_MCP109() {
        var (state, actions, m) = step(machine(.queued, path: .type), .turn(.live))
        XCTAssertEqual(state, .typing)
        XCTAssertEqual(actions, [.sendType])
        (state, actions, m) = step(m, .typeOK(entry: "inserted", via: "set_text"))
        XCTAssertEqual(state, .settling(1))
        XCTAssertEqual(actions, [.sendSettle(req: 1, quietMs: 300, timeoutMs: 2000)])
        XCTAssertEqual(m.entry, "inserted")
        XCTAssertEqual(m.via, "set_text")

        (state, actions, _) = step(machine(.typing), .typeFailed("no_field"))
        XCTAssertEqual(state, .done)
        XCTAssertEqual(actions, [.fail("no_field")])

        (state, actions, _) = step(machine(.typing), .windowClosed(reason: "app_exited", by: "phone"))
        XCTAssertEqual(state, .done)
        XCTAssertEqual(actions, [.fail("no_window")])

        (state, actions, _) = step(machine(.typing), .linkLost)
        XCTAssertEqual(state, .done)
        XCTAssertEqual(actions, [.fail("phone_offline")])
    }

    /// The phone's `ui.type` codes that are no closed MCP code (`busy`) fail
    /// `failed`; the closed ones keep their code ([MCP-109], [MCP-6]).
    func testATypeRefusalMapsToAClosedCode_MCP109() {
        let cases = [("no_field", "no_field"), ("not_supported", "not_supported"),
                     ("no_window", "no_window"), ("timeout", "timeout"),
                     ("phone_offline", "phone_offline"), ("busy", "failed"), ("failed", "failed"),
                     ("something_new", "failed")]
        for (phone, code) in cases {
            let (state, actions, _) = step(machine(.typing), .typeFailed(phone))
            XCTAssertEqual(state, .done, phone)
            XCTAssertEqual(actions, [.fail(code)], phone)
        }
    }

    // MARK: Sent

    func testSettledThenTreeAnswersWithTheTree_MCP81() {
        var (state, actions, m) = step(machine(.sent), .entry)
        XCTAssertEqual(state, .settling(1))
        XCTAssertEqual(actions, [.sendSettle(req: 1, quietMs: 300, timeoutMs: 2000)])
        (state, actions, m) = step(m, .settleReply(req: 1, settled: true, waitedMs: 412, reason: nil))
        XCTAssertEqual(state, .observing(2))
        XCTAssertEqual(actions, [.sendTree(req: 2)])
        (state, actions, m) = step(m, .treeReply(req: 2, "T"))
        XCTAssertEqual(state, .done)
        XCTAssertEqual(actions, [.answer(M.Answer(settle: settled412, tree: "T"))])
    }

    func testNoWaitWithATreeReadsAtOnce_MCP82() {
        let (state, actions, m) = step(machine(.sent, wait: .none), .entry)
        XCTAssertEqual(state, .observing(1))
        XCTAssertEqual(actions, [.sendTree(req: 1)])
        XCTAssertEqual(m.settle, M.Settle(state: "not_waited"))
    }

    func testNoWaitNoObserveAnswersAtOnce_MCP81() {
        let (state, actions, _) = step(machine(.sent, wait: .none, observe: .none), .entry)
        XCTAssertEqual(state, .done)
        XCTAssertEqual(actions, [.answer(M.Answer(settle: M.Settle(state: "not_waited")))])
    }

    // MARK: Settling

    func testObserveTreeReadsAfterTheSettle_MCP82() {
        let (state, actions, m) = step(machine(.settling(1), nextReq: 2),
                                       .settleReply(req: 1, settled: true, waitedMs: 412, reason: nil))
        XCTAssertEqual(state, .observing(2))
        XCTAssertEqual(actions, [.sendTree(req: 2)])
        XCTAssertEqual(m.settle, settled412)
    }

    func testASettleWithNothingToObserveAnswers_MCP82() {
        let (state, actions, _) = step(machine(.settling(1), observe: .none, nextReq: 2),
                                       .settleReply(req: 1, settled: true, waitedMs: 412, reason: nil))
        XCTAssertEqual(state, .done)
        XCTAssertEqual(actions, [.answer(M.Answer(settle: settled412))])
    }

    func testATimeoutCarriesItsReason_MCP107() {
        let (state, actions, _) = step(machine(.settling(1), observe: .none, nextReq: 2),
                                       .settleReply(req: 1, settled: false, waitedMs: 2000, reason: "loading"))
        XCTAssertEqual(state, .done)
        XCTAssertEqual(actions, [.answer(M.Answer(settle: M.Settle(state: "still_changing",
                                                                   waitedMs: 2000, reason: "loading")))])
    }

    func testAStillChangingWithNoReasonSaysChanges_MCP107() {
        let (_, _, m) = step(machine(.settling(1), nextReq: 2),
                             .settleReply(req: 1, settled: false, waitedMs: 2000, reason: nil))
        XCTAssertEqual(m.settle, M.Settle(state: "still_changing", waitedMs: 2000, reason: "changes"))
    }

    func testASettleThePhoneCannotWatchIsUnavailable_MCP81() {
        let (state, actions, m) = step(machine(.settling(1), nextReq: 2),
                                       .settleFailed(req: 1, code: "not_available"))
        XCTAssertEqual(state, .observing(2))
        XCTAssertEqual(actions, [.sendTree(req: 2)])
        XCTAssertEqual(m.settle, M.Settle(state: "unavailable"))
        let (state2, actions2, _) = step(machine(.settling(1), observe: .none, nextReq: 2),
                                         .settleFailed(req: 1, code: "not_available"))
        XCTAssertEqual(state2, .done)
        XCTAssertEqual(actions2, [.answer(M.Answer(settle: M.Settle(state: "unavailable")))])
    }

    // MARK: Observing

    func testATreeFailureAfterTheActionIsNotAnError_MCP82() {
        let (state, actions, _) = step(machine(.observing(2), settle: settled412, nextReq: 3),
                                       .treeFailed(req: 2, code: "timeout"))
        XCTAssertEqual(state, .done)
        XCTAssertEqual(actions, [.answer(M.Answer(settle: settled412, treeError: "timeout"))])
    }

    // MARK: Closing, the link, the deadline, the client

    func testAWindowThatClosesDuringTheSettleSaysWhy_MCP83() {
        let (state, actions, _) = step(machine(.settling(1), nextReq: 2),
                                       .windowClosed(reason: "app_exited", by: "phone"))
        XCTAssertEqual(state, .done)
        XCTAssertEqual(actions, [.answer(M.Answer(
            settle: M.Settle(state: "window_closed"), state: "closed",
            closed: M.Closed(reason: "app_exited", by: "phone")))])
    }

    func testAWindowThatClosesWhileSentOrObservingSaysWhy_MCP83() {
        for start in [M.State.sent, .observing(2)] {
            let (state, actions, _) = step(machine(start, settle: settled412, nextReq: 3),
                                           .windowClosed(reason: "app_exited", by: "phone"))
            XCTAssertEqual(state, .done)
            XCTAssertEqual(actions, [.answer(M.Answer(
                settle: M.Settle(state: "window_closed"), state: "closed",
                closed: M.Closed(reason: "app_exited", by: "phone")))], "\(start)")
        }
    }

    func testAWindowThatClosesBeforeThePressFailsNoWindow() {
        for start in [M.State.pressing, .typing] {
            let (state, actions, _) = step(machine(start), .windowClosed(reason: "app_exited", by: "phone"))
            XCTAssertEqual(state, .done)
            XCTAssertEqual(actions, [.fail("no_window")])
        }
    }

    func testALostLinkBeforeTheInputFailsPhoneOffline() {
        for start in [M.State.queued, .pressing, .typing] {
            let (state, actions, _) = step(machine(start), .linkLost)
            XCTAssertEqual(state, .done)
            XCTAssertEqual(actions, [.fail("phone_offline")], "\(start)")
        }
    }

    func testALostLinkAfterTheInputAnswersInterrupted() {
        for start in [M.State.sent, .settling(1), .observing(2)] {
            let (state, actions, _) = step(machine(start, nextReq: 3), .linkLost)
            XCTAssertEqual(state, .done)
            XCTAssertEqual(actions, [.answer(M.Answer(settle: M.Settle(state: "interrupted"),
                                                      state: "offline"))], "\(start)")
        }
    }

    func testTheDeadlineAnswersTimeout_MCP8() {
        for start in [M.State.queued, .pressing, .typing] {
            let (state, actions, _) = step(machine(start), .deadline(waitedMs: 5000))
            // MCP-84: a press or a text still out drains until the phone answers it.
            XCTAssertEqual(state, start == .queued ? .done : .draining, "\(start)")
            XCTAssertEqual(actions, [.fail("timeout")], "\(start)")
        }
        let (state, actions, _) = step(machine(.settling(1), nextReq: 2), .deadline(waitedMs: 4990))
        XCTAssertEqual(state, .done)
        XCTAssertEqual(actions, [.answer(M.Answer(settle: M.Settle(state: "still_changing",
                                                                   waitedMs: 4990, reason: "deadline")))])
        let (state2, actions2, _) = step(machine(.observing(2), settle: settled412, nextReq: 3),
                                         .deadline(waitedMs: 5000))
        XCTAssertEqual(state2, .done)
        XCTAssertEqual(actions2, [.answer(M.Answer(settle: settled412, treeError: "timeout"))])
    }

    func testAClientThatLeftGetsNoAnswer() {
        for start in [M.State.queued, .opening, .pressing, .typing, .sent, .settling(1), .observing(2)] {
            let (state, actions, _) = step(machine(start, nextReq: 3), .clientGone)
            // MCP-84: a press or a text still out drains until the phone answers it.
            XCTAssertEqual(state, start == .pressing || start == .typing ? .draining : .done, "\(start)")
            XCTAssertEqual(actions, [], "\(start)")
        }
    }

    func testThePersonsInputIsAddedToAlsoActed_MCP84() {
        var (state, actions, m) = step(machine(.settling(1), observe: .none, nextReq: 2), .otherInput("person"))
        XCTAssertEqual(state, .settling(1))
        XCTAssertEqual(actions, [])
        (_, _, m) = step(m, .otherInput("person"))
        (state, actions, m) = step(m, .settleReply(req: 1, settled: true, waitedMs: 412, reason: nil))
        XCTAssertEqual(actions, [.answer(M.Answer(settle: settled412, alsoActed: ["person"]))],
                       "a source is listed once")
    }

    func testLateRepliesAreIgnoredBySeq() {
        // A reply for a request the call is no longer waiting on.
        let (state, actions, _) = step(machine(.observing(2), settle: settled412, nextReq: 3),
                                       .settleReply(req: 1, settled: true, waitedMs: 50, reason: nil))
        XCTAssertEqual(state, .observing(2))
        XCTAssertEqual(actions, [])
        let (state2, actions2, _) = step(machine(.settling(4), nextReq: 5), .treeReply(req: 3, "old"))
        XCTAssertEqual(state2, .settling(4))
        XCTAssertEqual(actions2, [])
        let (state3, actions3, _) = step(machine(.settling(4), nextReq: 5),
                                         .settleReply(req: 3, settled: true, waitedMs: 1, reason: nil))
        XCTAssertEqual(state3, .settling(4))
        XCTAssertEqual(actions3, [])
    }

    func testATreeReplyBeforeTheTreeWasAskedIsIgnored() {
        let (state, actions, _) = step(machine(.settling(1), nextReq: 2), .treeReply(req: 2, "early"))
        XCTAssertEqual(state, .settling(1))
        XCTAssertEqual(actions, [])
    }

    func testDoneIgnoresEverything() {
        let events: [M.Event] = [.turn(.live), .pressOK, .entry, .linkLost, .clientGone,
                                 .deadline(waitedMs: 1), .otherInput("person"),
                                 .windowClosed(reason: "closed", by: "you"),
                                 .settleReply(req: 1, settled: true, waitedMs: 1, reason: nil)]
        for event in events {
            let (state, actions, _) = step(machine(.done, nextReq: 2), event)
            XCTAssertEqual(state, .done)
            XCTAssertEqual(actions, [], "\(event)")
        }
    }

    // MARK: Opening (T6) and screenshot

    /// T6 [MCP-41]: an open waits for the phone's `window.opened` and the
    /// stream's first frame, then settles and reads like an action; its answer
    /// is the opened-window shape.
    func testAnOpenWaitsForTheFirstFrameThenSettles_MCP41() {
        var (state, actions, m) = step(M(opening: .settle, observe: .tree), .windowOpened)
        XCTAssertEqual(state, .opening)
        XCTAssertEqual(actions, [])
        (state, actions, m) = step(m, .firstFrame)
        XCTAssertEqual(state, .settling(1))
        XCTAssertEqual(actions, [.sendSettle(req: 1, quietMs: 300, timeoutMs: 2000)])
        (state, actions, m) = step(m, .settleReply(req: 1, settled: true, waitedMs: 412, reason: nil))
        XCTAssertEqual(state, .observing(2))
        XCTAssertEqual(actions, [.sendTree(req: 2)])
        let tree = #"{"nodes":[{"ref":"s1e0","role":"View"}]}"#
        (state, actions, m) = step(m, .treeReply(req: 2, tree))
        XCTAssertEqual(state, .done)
        let result = M.Answer(settle: settled412, tree: tree)
        XCTAssertEqual(actions, [.answer(result)])

        let answer = MCPOpenAnswer.answer(window: 5, kind: .app, package: "com.google.android.calculator",
                                          label: "Calculator", opened: .new, openedBy: "you",
                                          size: [590, 1280], result: result)
        XCTAssertEqual(answer["window"] as? Int, 5)
        XCTAssertEqual(answer["kind"] as? String, "app")
        XCTAssertEqual(answer["package"] as? String, "com.google.android.calculator")
        XCTAssertEqual(answer["label"] as? String, "Calculator")
        XCTAssertEqual(answer["opened"] as? String, "new")
        XCTAssertEqual(answer["openedBy"] as? String, "you")
        XCTAssertEqual(answer["size"] as? [Int], [590, 1280])
        XCTAssertEqual((answer["settle"] as? [String: Any])?["state"] as? String, "settled")
        XCTAssertEqual((answer["settle"] as? [String: Any])?["waitedMs"] as? Int, 412)
        XCTAssertNotNil(answer["tree"] as? [String: Any])
        XCTAssertNil(answer["did"], "an open is not an input: no did")

        // The open bound (10 s) with no first frame: the window exists, still opening.
        XCTAssertEqual(M.openBoundMs, 10_000)
        (state, actions, m) = step(M(opening: .settle, observe: .tree), .windowOpened)
        (state, actions, m) = step(m, .openBound)
        XCTAssertEqual(state, .done)
        XCTAssertEqual(actions, [.answer(M.Answer(settle: M.Settle(state: "not_ready"), state: "opening"))])
    }

    /// T6: the first frame before the phone's `window.opened` still waits for it.
    func testAFirstFrameBeforeTheOpenedReplyWaits_MCP41() {
        var (state, actions, m) = step(M(opening: .settle, observe: .tree), .firstFrame)
        XCTAssertEqual(state, .opening)
        XCTAssertEqual(actions, [])
        (state, actions, m) = step(m, .windowOpened)
        XCTAssertEqual(state, .settling(1))
        XCTAssertEqual(actions, [.sendSettle(req: 1, quietMs: 300, timeoutMs: 2000)])
        _ = m
    }

    /// T6: `wait: "none"` on an open reads at once when the window is up.
    func testAnOpenWithWaitNoneReadsAtOnce_MCP41() {
        var (state, actions, m) = step(M(opening: .none, observe: .tree), .windowOpened)
        (state, actions, m) = step(m, .firstFrame)
        XCTAssertEqual(state, .observing(1))
        XCTAssertEqual(actions, [.sendTree(req: 1)])
        (state, actions, m) = step(M(opening: .none, observe: .none), .windowOpened)
        (state, actions, m) = step(m, .firstFrame)
        XCTAssertEqual(state, .done)
        XCTAssertEqual(actions, [.answer(M.Answer(settle: M.Settle(state: "not_waited")))])
    }

    /// T6 [MCP-43]: a link window answers `kind: link`, with null package and
    /// label until the phone names the app.
    func testALinkWindowAnswersKindLinkWithNullNames_MCP43() {
        let answer = MCPOpenAnswer.answer(window: 7, kind: .link, package: nil, label: nil,
                                          opened: .new, openedBy: "you", size: [900, 600],
                                          result: M.Answer(settle: M.Settle(state: "not_ready"), state: "opening"))
        XCTAssertEqual(answer["kind"] as? String, "link")
        XCTAssertTrue(answer["package"] is NSNull)
        XCTAssertTrue(answer["label"] is NSNull)
        XCTAssertEqual(answer["state"] as? String, "opening")
    }

    func testAnOpenThatGotItsFirstFrameSettles() {
        let (_, _, opened) = step(machine(.opening), .windowOpened)
        let (state, actions, _) = step(opened, .firstFrame)
        XCTAssertEqual(state, .settling(1))
        XCTAssertEqual(actions, [.sendSettle(req: 1, quietMs: 300, timeoutMs: 2000)])
    }

    func testAnOpenPastItsBoundIsStillOpening_MCP41() {
        let (state, actions, _) = step(machine(.opening), .openBound)
        XCTAssertEqual(state, .done)
        XCTAssertEqual(actions, [.answer(M.Answer(settle: M.Settle(state: "not_ready"), state: "opening"))])
    }

    func testAnOpenThePhoneRefusedFailsWithItsCode() {
        let (state, actions, _) = step(machine(.opening), .openFailed("not_found"))
        XCTAssertEqual(state, .done)
        XCTAssertEqual(actions, [.fail("not_found")])
    }

    func testAScreenshotThatWaitsEntersSent_MCP64() {
        let m = M(screenshotWaiting: ())
        XCTAssertEqual(m.state, .sent)
        let (state, actions, _) = step(m, .entry)
        XCTAssertEqual(state, .settling(1))
        XCTAssertEqual(actions, [.sendSettle(req: 1, quietMs: 300, timeoutMs: 2000)])
    }

    // MARK: The envelope's `did` and `on` (MCP-80, MCP-87, MCP-108)

    private func tree(snapshot: Int, nodes: [UITree.Node]) -> UITree {
        UITree(seq: 1, stream: 3, ok: true, code: nil, message: nil, displayId: 47,
               snapshot: snapshot, size: [1080, 2400], truncated: false, layers: [],
               nodes: nodes, note: nil)
    }

    private func node(_ i: Int, ref: String, role: String, text: String? = nil, box: [Int],
                      at: UITree.Point? = nil, click: Bool = false) -> UITree.Node {
        UITree.Node(index: i, ref: ref, parent: nil, layer: 0, role: role, text: text,
                    desc: nil, id: nil, box: box, at: at, off: false, click: click,
                    edit: false, scroll: false, check: nil, selected: false, focused: false,
                    disabled: false, password: false, loading: false)
    }

    func testAPointTapNamesTheNodeUnderIt_MCP87() throws {
        let latest = tree(snapshot: 4, nodes: [
            node(0, ref: "s4e0", role: "FrameLayout", box: [0, 0, 1080, 2400]),
            node(1, ref: "s4e1", role: "Button", text: "Continue",
                 box: [108, 1440, 972, 1680], click: true),
        ])
        let did = MCPActDid.tap(x: 0.5, y: 0.65, holdMs: nil, latest: latest)
        let hit = try XCTUnwrap(did.object["hit"] as? [String: Any])
        XCTAssertEqual(hit["ref"] as? String, "s4e1")
        XCTAssertEqual(hit["role"] as? String, "Button")
        XCTAssertEqual(hit["text"] as? String, "Continue")
        XCTAssertEqual(did.snapshot, 4)
        XCTAssertEqual(did.object["at"] as? [Double], [0.5, 0.65])
    }

    func testAPointTapOutsideEveryClickableHasNoHit_MCP87() {
        let latest = tree(snapshot: 4, nodes: [
            node(1, ref: "s4e1", role: "Button", box: [108, 1440, 972, 1680], click: true),
        ])
        let did = MCPActDid.tap(x: 0.05, y: 0.05, holdMs: nil, latest: latest)
        XCTAssertNil(did.object["hit"])
        XCTAssertEqual(did.snapshot, 4)
        XCTAssertNil(MCPActDid.tap(x: 0.5, y: 0.5, holdMs: nil, latest: nil).snapshot)
    }

    func testTheEnvelopeNamesWhatWasPressedAndWhatItActedOn_MCP80() throws {
        let did = MCPActDid.key("back")
        let answer = MCPActEnvelope.answer(
            window: 3, did: did, frameAtInput: 1302,
            result: M.Answer(settle: settled412, tree: #"{"nodes":[]}"#, alsoActed: ["person"]))
        XCTAssertNil(answer["ok"])
        XCTAssertEqual(answer["window"] as? Int, 3)
        XCTAssertEqual(answer["did"] as? [String: String], ["action": "key", "key": "back"])
        let on = try XCTUnwrap(answer["on"] as? [String: Any])
        XCTAssertTrue(on["snapshot"] is NSNull)
        XCTAssertEqual(on["frame"] as? Int, 1302)
        XCTAssertEqual(answer["settle"] as? [String: AnyHashable], ["state": "settled", "waitedMs": 412])
        XCTAssertEqual(answer["alsoActed"] as? [String], ["person"])
        XCTAssertNotNil(answer["tree"] as? [String: Any])
        XCTAssertNil(answer["closed"])
    }

    func testAClosedEnvelopeHasNoTree_MCP83() throws {
        let answer = MCPActEnvelope.answer(
            window: 3, did: MCPActDid.key("back"), frameAtInput: 2210,
            result: M.Answer(settle: M.Settle(state: "window_closed"), state: "closed",
                             closed: M.Closed(reason: "app_exited", by: "phone")))
        XCTAssertEqual(answer["state"] as? String, "closed")
        XCTAssertEqual(answer["closed"] as? [String: String], ["reason": "app_exited", "closedBy": "phone"])
        XCTAssertNil(answer["tree"])
        XCTAssertNil(answer["alsoActed"])
    }

    // MARK: Review fixes (T5)

    /// MCP-8, MCP-84: a deadline while the input is still going out answers,
    /// but the call keeps the window's turn until the input has finished.
    func testADeadlineWhileSendingWaitsForTheInput_MCP8() {
        var (state, actions, m) = step(machine(.sending), .deadline(waitedMs: nil))
        XCTAssertEqual(state, .draining)
        XCTAssertEqual(actions, [.answer(M.Answer(settle: M.Settle(state: "not_waited", reason: "deadline")))])
        (state, actions, m) = step(m, .otherInput("person"))
        XCTAssertEqual(state, .draining)
        XCTAssertEqual(actions, [])
        (state, actions, m) = step(m, .inputSent)
        XCTAssertEqual(state, .done)
        XCTAssertEqual(actions, [])
    }

    /// MCP-84: whatever ends the call while its input goes out leaves it draining.
    func testAnEndWhileSendingDrains_MCP84() {
        let cases: [(M.Event, [M.Action])] = [
            (.clientGone, []),
            (.linkLost, [.answer(M.Answer(settle: M.Settle(state: "interrupted"), state: "offline"))]),
            (.windowClosed(reason: "app_exited", by: "phone"),
             [.answer(M.Answer(settle: M.Settle(state: "window_closed"), state: "closed",
                               closed: M.Closed(reason: "app_exited", by: "phone")))]),
        ]
        for (event, expected) in cases {
            let (state, actions, _) = step(machine(.sending), event)
            XCTAssertEqual(state, .draining, "\(event)")
            XCTAssertEqual(actions, expected, "\(event)")
        }
    }

    func testTheInputSentGoesOnToTheSettle_MCP81() {
        let (state, actions, _) = step(machine(.sending, wait: .none, observe: .none), .inputSent)
        XCTAssertEqual(state, .done)
        XCTAssertEqual(actions, [.answer(M.Answer(settle: M.Settle(state: "not_waited")))])
    }

    /// MCP-8: `waitedMs` counts only the settle's own wait; a call the deadline
    /// ended before any settle answers `not_waited` with no `waitedMs`.
    func testTheDeadlineCountsOnlyTheSettlesWait_MCP8() {
        let (state, actions, _) = step(machine(.sent), .deadline(waitedMs: nil))
        XCTAssertEqual(state, .done)
        XCTAssertEqual(actions, [.answer(M.Answer(settle: M.Settle(state: "not_waited", reason: "deadline")))])
        let (_, actions2, _) = step(machine(.settling(1), observe: .none, nextReq: 2), .deadline(waitedMs: 1200))
        XCTAssertEqual(actions2, [.answer(M.Answer(settle: M.Settle(state: "still_changing",
                                                                    waitedMs: 1200, reason: "deadline")))])
    }

    /// MCP-83: a settle that finds the display gone waits up to 500 ms for the
    /// phone's close reason, then answers `window_closed`.
    func testASettleThatFindsNoDisplayIsWindowClosed_MCP83() {
        for code in ["no_display", "no_window"] {
            var (state, actions, m) = step(machine(.settling(1), nextReq: 2), .settleFailed(req: 1, code: code))
            XCTAssertEqual(state, .closing, code)
            XCTAssertEqual(actions, [.waitForClose(ms: 500)], code)
            (state, actions, m) = step(m, .closeWaitOver)
            XCTAssertEqual(state, .done)
            XCTAssertEqual(actions, [.answer(M.Answer(settle: M.Settle(state: "window_closed"), state: "closed"))])
        }
    }

    func testAClosingCallTakesThePhonesReason_MCP83() {
        let (state, actions, _) = step(machine(.closing, nextReq: 2),
                                       .windowClosed(reason: "phone_closed", by: "phone"))
        XCTAssertEqual(state, .done)
        XCTAssertEqual(actions, [.answer(M.Answer(settle: M.Settle(state: "window_closed"), state: "closed",
                                                  closed: M.Closed(reason: "phone_closed", by: "phone")))])
    }

    func testAClosingCallPastItsDeadlineIsWindowClosed_MCP8() {
        for event in [M.Event.deadline(waitedMs: 2100), .linkLost] {
            let (state, actions, _) = step(machine(.closing, nextReq: 2), event)
            XCTAssertEqual(state, .done)
            XCTAssertEqual(actions, [.answer(M.Answer(settle: M.Settle(state: "window_closed"), state: "closed"))],
                           "\(event)")
        }
    }

    /// MCP-8: the Mac's own wait on the settle ran out.
    func testASettleTimeoutIsStillChanging_MCP8() {
        let (state, actions, _) = step(machine(.settling(1), observe: .none, nextReq: 2),
                                       .settleFailed(req: 1, code: "timeout"))
        XCTAssertEqual(state, .done)
        XCTAssertEqual(actions, [.answer(M.Answer(settle: M.Settle(state: "still_changing",
                                                                   waitedMs: 2000, reason: "deadline")))])
    }

    func testASettleThatIsBusyOrFailedIsUnavailable_MCP81() {
        for code in ["busy", "failed", "not_connected"] {
            let (state, actions, _) = step(machine(.settling(1), observe: .none, nextReq: 2),
                                           .settleFailed(req: 1, code: code))
            XCTAssertEqual(state, .done, code)
            XCTAssertEqual(actions, [.answer(M.Answer(settle: M.Settle(state: "unavailable")))], code)
        }
    }

    func testTheDeadlineInOpeningIsNotReady_MCP8() {
        let (state, actions, _) = step(machine(.opening), .deadline(waitedMs: nil))
        XCTAssertEqual(state, .done)
        XCTAssertEqual(actions, [.answer(M.Answer(settle: M.Settle(state: "not_ready"), state: "opening"))])
    }

    func testAWindowClosedOrLinkLostInOpeningFails_MCP83() {
        let (state, actions, _) = step(machine(.opening), .windowClosed(reason: "app_exited", by: "phone"))
        XCTAssertEqual(state, .done)
        XCTAssertEqual(actions, [.fail("no_window")])
        let (state2, actions2, _) = step(machine(.opening), .linkLost)
        XCTAssertEqual(state2, .done)
        XCTAssertEqual(actions2, [.fail("phone_offline")])
    }

    // MARK: Review follow-ups (#262): the turn drains while the phone acts

    /// MCP-84: a deadline while the phone's `ui.press` is out fails the call at
    /// once, but the window's turn is held until the phone answers (or the
    /// request's own bound): the next call's input cannot land during the press.
    func testADeadlineWhilePressingDrainsBeforeTheTurnIsFree_MCP84() {
        for answer in [M.Event.pressOK, .pressFailed("timeout"), .pressFailed("gone")] {
            var (state, actions, m) = step(machine(.pressing, path: .press), .deadline(waitedMs: nil))
            XCTAssertEqual(state, .draining)
            XCTAssertEqual(actions, [.fail("timeout")])
            (state, actions, m) = step(m, .otherInput("person"))
            XCTAssertEqual(state, .draining)
            XCTAssertEqual(actions, [])
            (state, actions, m) = step(m, answer)
            XCTAssertEqual(state, .done, "\(answer)")
            XCTAssertEqual(actions, [], "\(answer)")
        }
    }

    /// MCP-84: the same for `ui.type`.
    func testADeadlineWhileTypingDrainsBeforeTheTurnIsFree_MCP84() {
        for answer in [M.Event.typeOK(entry: "inserted", via: "keys"), .typeFailed("timeout"),
                       .typeFailed("no_field")] {
            var (state, actions, m) = step(machine(.typing, path: .type), .deadline(waitedMs: nil))
            XCTAssertEqual(state, .draining)
            XCTAssertEqual(actions, [.fail("timeout")])
            (state, actions, m) = step(m, answer)
            XCTAssertEqual(state, .done, "\(answer)")
            XCTAssertEqual(actions, [], "\(answer)")
        }
    }

    /// MCP-84: a client that leaves while its press is out gets no answer, and
    /// its turn is held until the phone answers the press.
    func testAClientGoneWhilePressingDrainsBeforeTheTurnIsFree_MCP84() {
        var (state, actions, m) = step(machine(.pressing, path: .press), .clientGone)
        XCTAssertEqual(state, .draining)
        XCTAssertEqual(actions, [])
        (state, actions, m) = step(m, .deadline(waitedMs: nil))
        XCTAssertEqual(state, .draining)
        XCTAssertEqual(actions, [])
        (state, actions, m) = step(m, .pressOK)
        XCTAssertEqual(state, .done)
        XCTAssertEqual(actions, [])
    }

    /// MCP-84: the same for `ui.type`.
    func testAClientGoneWhileTypingDrainsBeforeTheTurnIsFree_MCP84() {
        var (state, actions, m) = step(machine(.typing, path: .type), .clientGone)
        XCTAssertEqual(state, .draining)
        XCTAssertEqual(actions, [])
        (state, actions, m) = step(m, .typeFailed("phone_offline"))
        XCTAssertEqual(state, .done)
        XCTAssertEqual(actions, [])
    }

    /// MCP-84 through the runner: A's deadline ends its call while its
    /// `ui.press` is still out; B's input waits until the phone has answered A.
    @MainActor
    func testTheNextCallWaitsForAPressInFlight_MCP84() async {
        let queue = WindowActQueue()
        let shared = SharedLog()
        let a = FakeActEnvironment(name: "A")
        a.pressMs = 300
        a.shared = shared
        let b = FakeActEnvironment(name: "B")
        b.shared = shared
        let first = Task {
            await MCPActRunner.run(MCPActMachine(path: .press, wait: .settle, observe: .none),
                                   window: 3, queue: queue, deadline: .milliseconds(100), env: a, ref: true)
        }
        for _ in 0..<500 where a.log.isEmpty {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(2)) // real-time: let A's press go out
        }
        let second = Task {
            await MCPActRunner.run(MCPActMachine(path: .input, wait: .none, observe: .none),
                                   window: 3, queue: queue, deadline: .seconds(5), env: b)
        }
        let outcome = await first.value
        XCTAssertEqual(outcome, .fail("timeout"))
        _ = await second.value
        XCTAssertEqual(shared.lines, ["A.press", "A.pressed", "B.input"],
                       "B's input went out while A's press was on the phone")
    }

    // MARK: Review follow-ups (#262): one test per untested row

    /// Row "Queued · Opening · Pressing · Typing | `windowClosed`": a call still
    /// queued when its window closes fails `no_window` and sends nothing.
    func testQueuedWindowClosedFailsNoWindow_MCP85() {
        let (state, actions, _) = step(machine(.queued), .windowClosed(reason: "app_exited", by: "phone"))
        XCTAssertEqual(state, .done)
        XCTAssertEqual(actions, [.fail("no_window")])
    }

    /// Row "any but Done, Sending, Draining, Pressing, Typing | `clientGone`" in Closing.
    func testClosingClientGoneEndsWithNoAnswer_MCP83() {
        let (state, actions, _) = step(machine(.closing, nextReq: 2), .clientGone)
        XCTAssertEqual(state, .done)
        XCTAssertEqual(actions, [])
    }

    /// Row "any but Draining, Done | `otherInput`" in Closing: the source is
    /// kept and the close's answer carries it.
    func testClosingOtherInputIsAlsoActed_MCP84() {
        var (state, actions, m) = step(machine(.closing, nextReq: 2), .otherInput("person"))
        XCTAssertEqual(state, .closing)
        XCTAssertEqual(actions, [])
        (state, actions, m) = step(m, .closeWaitOver)
        XCTAssertEqual(state, .done)
        XCTAssertEqual(actions, [.answer(M.Answer(settle: M.Settle(state: "window_closed"), state: "closed",
                                                  alsoActed: ["person"]))])
    }

    /// Row "Draining | anything else": a window closing while the call drains
    /// is ignored; the turn is still held.
    func testDrainingIgnoresWindowClosed_MCP84() {
        let (state, actions, _) = step(machine(.draining), .windowClosed(reason: "app_exited", by: "phone"))
        XCTAssertEqual(state, .draining)
        XCTAssertEqual(actions, [])
    }

    /// Row "Draining | anything else": the link's loss is ignored.
    func testDrainingIgnoresLinkLost_MCP84() {
        let (state, actions, _) = step(machine(.draining), .linkLost)
        XCTAssertEqual(state, .draining)
        XCTAssertEqual(actions, [])
    }

    /// Row "Draining | anything else": a second deadline is ignored.
    func testDrainingIgnoresTheDeadline_MCP84() {
        let (state, actions, _) = step(machine(.draining), .deadline(waitedMs: 100))
        XCTAssertEqual(state, .draining)
        XCTAssertEqual(actions, [])
    }

    /// Row "Draining | anything else": a client that leaves while its call
    /// drains changes nothing.
    func testDrainingIgnoresClientGone_MCP84() {
        let (state, actions, _) = step(machine(.draining), .clientGone)
        XCTAssertEqual(state, .draining)
        XCTAssertEqual(actions, [])
    }

    // [MCP-86] T10: the phone answers `ui.press` gone → stale_ref, and no
    // input frame went out.
    @MainActor
    func testAGonePressIsStaleRefAndPressesNothing() async {
        let env = FakeActEnvironment(name: "a")
        env.pressEvent = .pressFailed("gone")
        let outcome = await MCPActRunner.run(MCPActMachine(path: .press, wait: .settle, observe: .tree),
                                             window: 3, queue: WindowActQueue(),
                                             deadline: .seconds(5), env: env, ref: true)
        XCTAssertEqual(outcome, .fail("stale_ref"))
        XCTAssertEqual(env.log, ["a.press"], "a gone ref sends no TOUCH and no settle")
    }
}
