// ⌘V with an image (SHARE-16): the per-window flow's transition table and the
// wire effects it drives — one clip image, one KEY 279 after the phone says it
// wrote the clip, nothing on a refusal, a timeout or a session end.

import AppKit
import XCTest
@testable import Contigua

@MainActor
final class PasteFlowTests: XCTestCase {

    // MARK: The machine's whole table

    private func machine(_ phase: PastePhase) -> PasteMachine { PasteMachine(phase: phase) }

    private func assertTransition(_ phase: PastePhase, _ event: PasteEvent,
                                  becomes expected: PastePhase, _ expectedActions: [PasteAction],
                                  file: StaticString = #filePath, line: UInt = #line) {
        var machine = machine(phase)
        let actions = machine.handle(event)
        XCTAssertEqual(expected, machine.phase, "phase after \(event)", file: file, line: line)
        XCTAssertEqual(expectedActions, actions, "actions after \(event)", file: file, line: line)
    }

    func testIdlePasteStartsSending() {
        assertTransition(.idle, .paste(7), becomes: .sending(7), [.sendImage(7), .showPasting])
    }

    func testSentMovesToAwaitingThePhone() {
        assertTransition(.sending(7), .sent(7), becomes: .awaitingConfirmation(7), [])
        assertTransition(.sending(7), .sent(8), becomes: .sending(7), [])
    }

    func testConfirmationPastesAndSendsTheKey() {
        assertTransition(.awaitingConfirmation(7), .done(7, ok: true),
                         becomes: .pasted, [.sendKey(7), .showPasted])
    }

    func testRefusalFailsWithoutAKey() {
        assertTransition(.awaitingConfirmation(7), .done(7, ok: false),
                         becomes: .failed, [.showFailed])
    }

    func testATimeoutFailsWithoutAKey() {
        assertTransition(.awaitingConfirmation(7), .timedOut(7), becomes: .failed, [.showFailed])
        assertTransition(.sending(7), .timedOut(7), becomes: .sending(7), [])
    }

    func testAnEarlyConfirmationOrAStaleOneIsIgnored() {
        assertTransition(.sending(7), .done(7, ok: true), becomes: .sending(7), [])
        assertTransition(.pasted, .done(7, ok: true), becomes: .pasted, [])
        assertTransition(.pasted, .timedOut(7), becomes: .pasted, [])
        assertTransition(.pasted, .sent(7), becomes: .pasted, [])
        assertTransition(.idle, .done(7, ok: true), becomes: .idle, [])
        assertTransition(.sending(7), .done(8, ok: true), becomes: .sending(7), [])
    }

    func testASecondPasteWhileBusyIsIgnored() {
        assertTransition(.sending(7), .paste(8), becomes: .sending(7), [])
        assertTransition(.awaitingConfirmation(7), .paste(8), becomes: .awaitingConfirmation(7), [])
    }

    func testANewPasteAfterAnOutcomeReplacesThePill() {
        assertTransition(.pasted, .paste(9), becomes: .sending(9),
                         [.hidePill, .sendImage(9), .showPasting])
        assertTransition(.failed, .paste(9), becomes: .sending(9),
                         [.hidePill, .sendImage(9), .showPasting])
    }

    func testASessionEndInEveryState() {
        assertTransition(.idle, .sessionEnded, becomes: .idle, [])
        assertTransition(.sending(7), .sessionEnded, becomes: .failed, [.showFailed])
        assertTransition(.awaitingConfirmation(7), .sessionEnded, becomes: .failed, [.showFailed])
        assertTransition(.pasted, .sessionEnded, becomes: .idle, [.hidePill])
        assertTransition(.failed, .sessionEnded, becomes: .idle, [.hidePill])
    }

    func testEscLeavesEveryPill() {
        assertTransition(.idle, .dismissed, becomes: .idle, [])
        assertTransition(.sending(7), .dismissed, becomes: .idle, [.cancel(7), .hidePill])
        assertTransition(.awaitingConfirmation(7), .dismissed, becomes: .idle,
                         [.cancel(7), .hidePill])
        assertTransition(.pasted, .dismissed, becomes: .idle, [.hidePill])
        assertTransition(.failed, .dismissed, becomes: .idle, [.hidePill])
    }

    func testThePillButtonSharesOnlyAfterAnOutcome() {
        assertTransition(.idle, .shareInstead, becomes: .idle, [])
        assertTransition(.sending(7), .shareInstead, becomes: .sending(7), [])
        assertTransition(.awaitingConfirmation(7), .shareInstead,
                         becomes: .awaitingConfirmation(7), [])
        assertTransition(.pasted, .shareInstead, becomes: .idle, [.share, .hidePill])
        assertTransition(.failed, .shareInstead, becomes: .idle, [.share, .hidePill])
    }

    // MARK: The flow's wire effects

    private final class Seen {
        var images: [(id: UInt32, data: Data, mime: String)] = []
        var keys: [KeyEvent] = []
        var shares: [(data: Data, mime: String)] = []
        var pills: [PastePillState?] = []
    }

    private func makeFlow(_ seen: Seen) -> PasteFlow {
        // A sleep long enough that the test, not the timer, drives the flow.
        let flow = PasteFlow(sleep: { _ in try? await Task.sleep(for: .seconds(60)) })  // real-time: injected clock never fires
        flow.sendImage = { id, data, mime in
            seen.images.append((id, data, mime))
            flow.sent(id)
        }
        flow.sendKey = { event in seen.keys.append(event) }
        flow.share = { data, mime in seen.shares.append((data, mime)) }
        flow.pill = { seen.pills.append($0) }
        return flow
    }

    func testAPasteSendsTheImageAndThenOnePasteKey() {
        let seen = Seen()
        let flow = makeFlow(seen)
        flow.paste(image: Data([0x89, 0x50]), mime: "image/png", id: 7)
        XCTAssertEqual([7], seen.images.map(\.id))
        XCTAssertEqual(2, seen.images.first?.data.count)
        XCTAssertEqual("image/png", seen.images.first?.mime)
        XCTAssertEqual([.pasting], seen.pills)

        flow.done(id: 7, ok: true)
        XCTAssertEqual([KeyEvent(action: 0, keycode: 279, metaState: 0)], seen.keys)
        XCTAssertEqual(.pasted, seen.pills.last)
    }

    func testARefusalSendsNoKeyAndTheFailurePill() {
        let seen = Seen()
        let flow = makeFlow(seen)
        flow.paste(image: Data([1]), mime: "image/png", id: 7)
        flow.done(id: 7, ok: false)
        XCTAssertEqual([], seen.keys)
        XCTAssertEqual(.failed, seen.pills.last)
    }

    func testATimeoutSendsNoKey() {
        let seen = Seen()
        let flow = makeFlow(seen)
        flow.paste(image: Data([1]), mime: "image/png", id: 7)
        flow.handle(.timedOut(7))
        XCTAssertEqual([], seen.keys)
        XCTAssertEqual(.failed, seen.pills.last)
    }

    func testASessionEndInFlightSendsNoKey() {
        let seen = Seen()
        let flow = makeFlow(seen)
        flow.paste(image: Data([1]), mime: "image/png", id: 7)
        flow.sessionEnded()
        XCTAssertEqual([], seen.keys)
        XCTAssertEqual(.failed, seen.pills.last)
    }

    func testASecondPasteWhileBusyIsIgnoredByTheFlowToo() {
        let seen = Seen()
        let flow = makeFlow(seen)
        flow.paste(image: Data([1]), mime: "image/png", id: 7)
        flow.paste(image: Data([2]), mime: "image/png", id: 8)
        XCTAssertEqual([7], seen.images.map(\.id))
        flow.done(id: 8, ok: true)
        XCTAssertEqual([], seen.keys, "another image's confirmation cannot paste this one")
        flow.done(id: 7, ok: true)
        XCTAssertEqual([KeyEvent(action: 0, keycode: 279, metaState: 0)], seen.keys)
    }

    func testThePillButtonSharesTheSameImage() {
        let seen = Seen()
        let flow = makeFlow(seen)
        flow.paste(image: Data([1, 2, 3]), mime: "image/png", id: 7)
        flow.done(id: 7, ok: false)
        flow.shareInstead()
        XCTAssertEqual(1, seen.shares.count)
        XCTAssertEqual(Data([1, 2, 3]), seen.shares.first?.data)
        XCTAssertEqual("image/png", seen.shares.first?.mime)
        XCTAssertNil(seen.pills.last!)
    }

    func testTheThreePillCopies() {
        XCTAssertEqual("Pasting…", PastePillState.pasting.text)
        XCTAssertEqual("Image pasted. Nothing there?", PastePillState.pasted.text)
        XCTAssertEqual("Nothing pasted.", PastePillState.failed.text)
        XCTAssertTrue(PastePillState.pasting.showsProgress)
        XCTAssertFalse(PastePillState.pasted.showsProgress)
    }
}
