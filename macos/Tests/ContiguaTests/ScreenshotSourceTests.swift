// MCP-60…63: what a screenshot answers. It is a frame from after the call (the
// phone's next keyframe, never the display layer's buffer), fails `no_frame`
// with the window's state when none arrives, marks a one-colour frame blank,
// and crops to a ref's box (docs/specs/mcp.md "Screenshot").

import CoreVideo
import XCTest
@testable import Contigua

@MainActor
final class ScreenshotSourceTests: XCTestCase {

    private func makeBuffer(width: Int, height: Int, value: UInt8,
                            whiteLeftColumns: Int = 0) -> CVPixelBuffer {
        var created: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                         kCVPixelFormatType_32BGRA,
                                         [kCVPixelBufferCGImageCompatibilityKey: true] as CFDictionary,
                                         &created)
        XCTAssertEqual(status, kCVReturnSuccess)
        let pixel = created!
        CVPixelBufferLockBaseAddress(pixel, [])
        defer { CVPixelBufferUnlockBaseAddress(pixel, []) }
        let base = CVPixelBufferGetBaseAddress(pixel)!.assumingMemoryBound(to: UInt8.self)
        let rowBytes = CVPixelBufferGetBytesPerRow(pixel)
        for y in 0..<height {
            for x in 0..<width {
                let offset = y * rowBytes + x * 4
                let v: UInt8 = x < whiteLeftColumns ? 255 : value
                base[offset] = v
                base[offset + 1] = v
                base[offset + 2] = v
                base[offset + 3] = 255
            }
        }
        return pixel
    }

    /// A source that delivers one frame (or none) and traps on the display
    /// layer's buffer, which a screenshot must never read. `capturingFor`
    /// models Live Text's freeze holding the decoder.
    @MainActor
    private final class FakeSource: ScreenshotSource {
        let newestSeq: Int
        let deliver: SnapshotFrame?
        let deliverAfter: TimeInterval
        private let capturingUntil: TimeInterval
        private(set) var askedAfter: Int?
        private(set) var askedTimeout: TimeInterval?
        init(newestSeq: Int, deliver: SnapshotFrame?, deliverAfter: TimeInterval = 0,
             capturingFor: TimeInterval = 0) {
            self.newestSeq = newestSeq
            self.deliver = deliver
            self.deliverAfter = deliverAfter
            self.capturingUntil = ProcessInfo.processInfo.systemUptime + capturingFor
        }
        var isCapturing: Bool { ProcessInfo.processInfo.systemUptime < capturingUntil }
        var newestAt: TimeInterval? { deliver.map { $0.at } }
        var stillSince: TimeInterval? { nil }
        func copyDisplayedFrame() -> CVPixelBuffer? {
            XCTFail("a screenshot read the display layer's buffer")
            return nil
        }
        func beginSnapshot(after seq: Int, until: TimeInterval,
                           handler: @escaping (SnapshotFrame?) -> Void) -> SnapshotTicket {
            askedAfter = seq
            askedTimeout = until
            let deliver = self.deliver
            let delay = self.deliverAfter
            Task { @MainActor in
                if delay > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))  // real-time: the answer's age is wall-clock (MCP-20)
                }
                handler(deliver)
            }
            return SnapshotTicket(id: 1)
        }
        func askKeyframeAgain() {}
        func cancelSnapshot(_ ticket: SnapshotTicket) {}
        func poll(_ seconds: TimeInterval) async {
            try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))  // real-time: the bound under test is wall-clock (MCP-61)
        }
    }

    /// The screenshot's answer object; fails the test when it is not an image.
    private func shot(id: Int, state: String, source: ScreenshotSource, size: (Int, Int),
                      crop: [Int]?) async throws -> [String: Any] {
        let result = try await Screenshot.result(id: id, state: { state }, source: source,
                                                 size: size, crop: crop)
        guard case .image(_, let answer) = result else {
            XCTFail("expected an image")
            return [:]
        }
        return answer
    }

    // MARK: The wait's rule (MCP-60, MCP-61; #274)

    /// A call that started at 100 and has already sent its first ask at `asked`.
    private func waitModel(callStart: TimeInterval = 100, asked: TimeInterval = 100,
                           hasFrame: Bool = true) -> ScreenshotWaitModel {
        let model = ScreenshotWait.model(callStart: callStart, hasFrame: hasFrame)
        guard asked >= callStart else { return model }
        return ScreenshotWait.transition(model, .asked(now: asked)).model
    }

    private func stamp(seq: Int, at: TimeInterval = 90,
                        origin: SnapshotFrame.Origin = .keyframe) -> SnapshotFrame {
        SnapshotFrame(buffer: makeBuffer(width: 8, height: 8, value: 1), seq: seq, at: at,
                      origin: origin)
    }

    // [MCP-60] #274: the phone answers the first key request with an IDR it
    // sent just before the call, so nothing new is counted. The Mac asks again
    // ~300 ms later, once, and that ask's frame is the answer.
    func testASecondAskCoversThePhonesDuplicateIdr_MCP60() {
        let model = waitModel()
        // Just after the ask: nothing arrived, and the repeat is not due.
        let early = ScreenshotWait.transition(model, .tick(now: 100.1, frame: nil, stillAt: nil,
                                                          displayed: nil))
        XCTAssertEqual(early.outcome, .wait)
        XCTAssertEqual(early.actions, [.wait(seconds: ScreenshotWait.pollInterval)])
        // Past 300 ms: ask again, exactly once.
        let again = ScreenshotWait.transition(early.model, .tick(now: 100.35, frame: nil,
                                                                stillAt: nil, displayed: nil))
        XCTAssertEqual(again.actions, [.askAgain])
        XCTAssertEqual(again.model.state, .waiting(askedAt: 100, repeatAt: 100.3, askedAgain: true))
        let third = ScreenshotWait.transition(again.model, .tick(now: 100.4, frame: nil,
                                                                stillAt: nil, displayed: nil))
        XCTAssertEqual(third.actions, [.wait(seconds: ScreenshotWait.pollInterval)])
        // The second ask's frame answers the call, with no still flag.
        let landed = stamp(seq: 11)
        let done = ScreenshotWait.transition(third.model, .tick(now: 100.45, frame: landed,
                                                                stillAt: nil, displayed: nil))
        XCTAssertEqual(done.outcome, .keyframe(landed))
        XCTAssertEqual(done.model.state, .done)
    }

    // [MCP-60] #274 review: the repeat is counted from the *ask*, never from
    // the call. Live Text holding the one snapshot decoder for 1.5 s leaves
    // 0.5 s of the same bound; the repeat must still wait its own 300 ms
    // after the ask rather than fire at once because the call is older.
    func testTheSecondAskIsCountedFromTheAsk_MCP60() {
        // The call started at 100; Live Text let go and the first ask went out
        // at 101.5. The repeat's moment is 101.8, not 100.3.
        let asked = waitModel(callStart: 100, asked: 101.5)
        XCTAssertEqual(asked.state, .waiting(askedAt: 101.5, repeatAt: 101.8, askedAgain: false))
        let justAfter = ScreenshotWait.transition(asked, .tick(now: 101.55, frame: nil,
                                                               stillAt: nil, displayed: nil))
        XCTAssertEqual(justAfter.actions, [.wait(seconds: ScreenshotWait.pollInterval)],
                       "the repeat must not fire because the call is already 1.5 s old")
        XCTAssertFalse(justAfter.actions.contains(.askAgain))
        let due = ScreenshotWait.transition(justAfter.model, .tick(now: 101.85, frame: nil,
                                                                   stillAt: nil, displayed: nil))
        XCTAssertEqual(due.actions, [.askAgain], "300 ms after the ask, as PATH-41 needs")
    }

    // [MCP-60] #274: a still window sends no frame and says `window.still`
    // instead (PHONE-21); a still sent since the ask answers the displayed
    // frame at once.
    func testASteadyWindowAnswersTheDisplayedFrame_MCP60() {
        let shown = stamp(seq: 40, origin: .displayed)
        let done = ScreenshotWait.transition(waitModel(),
                                             .tick(now: 100.05, frame: nil, stillAt: 100.01,
                                                   displayed: shown))
        XCTAssertEqual(done.outcome, .displayed(shown))
        XCTAssertEqual(done.model.state, .done)
        XCTAssertEqual(done.actions, [], "a still is answered without waiting out the bound")
    }

    // [MCP-61] #274 review: a `window.still` from *before* the call answers
    // nothing. The screen may have changed since it, with the new frame still
    // on the wire, so answering it would be a picture from before the call.
    func testAPreCallStillAnswersNothing_MCP61() {
        let shown = stamp(seq: 40, origin: .displayed)
        let pre = ScreenshotWait.transition(waitModel(),
                                            .tick(now: 100.05, frame: nil, stillAt: 99.5,
                                                  displayed: shown))
        XCTAssertEqual(pre.outcome, .wait, "a still sent before the ask vouches for nothing")
        // Even at the bound, with that same pre-call still, the call fails.
        let bound = ScreenshotWait.transition(pre.model,
                                              .tick(now: 102, frame: nil, stillAt: 99.5,
                                                    displayed: shown))
        XCTAssertEqual(bound.outcome, .fail)
    }

    // [MCP-60] A fresh keyframe that arrives before the still wins: it is what
    // MCP-60 asks for, and it is newer than anything the still vouches for.
    func testAFreshKeyframeBeatsTheStill_MCP60() {
        let fresh = stamp(seq: 41)
        let done = ScreenshotWait.transition(waitModel(),
                                             .tick(now: 100.05, frame: fresh, stillAt: 100.01,
                                                   displayed: stamp(seq: 40, origin: .displayed)))
        XCTAssertEqual(done.outcome, .keyframe(fresh))
    }

    // [MCP-61] A window with no displayed frame at all cannot answer a still:
    // there is no picture to show, so the bound decides.
    func testAStillWithNoDisplayedFrameIsNoFrame_MCP61() {
        let still = ScreenshotWait.transition(waitModel(),
                                              .tick(now: 100.05, frame: nil, stillAt: 100.01,
                                                    displayed: nil))
        XCTAssertEqual(still.outcome, .wait)
        let bound = ScreenshotWait.transition(still.model, .tick(now: 102, frame: nil,
                                                                 stillAt: 100.01,
                                                                 displayed: nil))
        XCTAssertEqual(bound.outcome, .fail)
        XCTAssertEqual(bound.actions, [])
    }

    // [MCP-61] A phone that is neither still nor sending fails `no_frame` at the
    // bound, as it always did, and is asked exactly twice.
    func testANeitherStillNorSendingPhoneIsNoFrame_MCP61() {
        var model = waitModel()
        var repeats = 0
        for step in stride(from: 100.05, through: 102.1, by: 0.05) {
            let next = ScreenshotWait.transition(model, .tick(now: step, frame: nil, stillAt: nil,
                                                              displayed: nil))
            if next.actions.contains(.askAgain) { repeats += 1 }
            model = next.model
            if next.outcome == .fail { break }
        }
        XCTAssertEqual(model.state, .done)
        XCTAssertEqual(repeats, 1, "one repeat, no more")
    }

    // [MCP-61] A call whose Live Text hold outlives the bound fails without
    // ever asking: the bound is the call's, not the ask's.
    func testTheBoundIsTheCallsNotTheAsks_MCP61() {
        var model = ScreenshotWait.model(callStart: 100, hasFrame: true)
        let early = ScreenshotWait.transition(model, .tick(now: 101, frame: nil, stillAt: nil,
                                                           displayed: nil))
        XCTAssertEqual(early.outcome, .wait)
        XCTAssertEqual(early.model.state, .beforeAsk)
        let bound = ScreenshotWait.transition(early.model, .tick(now: 102,
                                                                 frame: nil, stillAt: nil,
                                                                 displayed: nil))
        XCTAssertEqual(bound.outcome, .fail)
        XCTAssertEqual(model.state, .beforeAsk)
        model = bound.model
        XCTAssertEqual(model.state, .done)
    }

    // MARK: A phone that behaves as the wire does (#274)

    /// What one `window.keyframe` ask is answered with, and how long that takes.
    private struct Ask {
        var deliver: CVPixelBuffer?
        var after: TimeInterval = 0
    }

    /// A phone at the other end of the wire, as #274 found it: one ask can be
    /// answered by silence (the phone had just sent that IDR, PATH-41), a still
    /// window sends `window.still` instead of a frame, and a window that is
    /// neither still nor sending sends nothing at all.
    @MainActor
    private final class PhoneSource: ScreenshotSource {
        let newestSeq: Int
        let newestAt: TimeInterval?
        let asks: [Ask]
        let displayed: CVPixelBuffer?
        /// `window.still` arrived this long *before* the call started: a still
        /// from before the ask, which must answer nothing (#165).
        let stillBefore: TimeInterval?
        /// `window.still` arrives this long *after* the call starts; nil never.
        let stillAfter: TimeInterval?
        private let started = ProcessInfo.processInfo.systemUptime
        private(set) var asked = 0
        private(set) var displays = 0
        private var handler: ((SnapshotFrame?) -> Void)?

        init(newestSeq: Int, newestAt: TimeInterval? = nil, asks: [Ask] = [],
             displayed: CVPixelBuffer? = nil, stillAfter: TimeInterval? = nil,
             stillBefore: TimeInterval? = nil) {
            self.newestSeq = newestSeq
            self.newestAt = newestAt
            self.asks = asks
            self.displayed = displayed
            self.stillAfter = stillAfter
            self.stillBefore = stillBefore
        }

        var isCapturing: Bool { false }

        var stillSince: TimeInterval? {
            if let stillBefore { return started - stillBefore }
            guard let stillAfter else { return nil }
            let at = started + stillAfter
            return ProcessInfo.processInfo.systemUptime >= at ? at : nil
        }

        func copyDisplayedFrame() -> CVPixelBuffer? {
            displays += 1
            return displayed
        }

        func beginSnapshot(after seq: Int, until: TimeInterval,
                           handler: @escaping (SnapshotFrame?) -> Void) -> SnapshotTicket {
            self.handler = handler
            ask(seq: seq)
            return SnapshotTicket(id: 1)
        }

        func askKeyframeAgain() { ask(seq: newestSeq) }

        func cancelSnapshot(_ ticket: SnapshotTicket) { handler = nil }

        func poll(_ seconds: TimeInterval) async {
            try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))  // real-time: the bound under test is wall-clock (MCP-61)
        }

        private func ask(seq: Int) {
            let entry = asked < asks.count ? asks[asked] : nil
            asked += 1
            guard let entry else { return }
            Task { @MainActor in
                if entry.after > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(entry.after * 1_000_000_000))  // real-time: the phone's own latency
                }
                guard let handler = self.handler else { return }
                handler(entry.deliver.map {
                    SnapshotFrame(buffer: $0, seq: seq + 1,
                                  at: ProcessInfo.processInfo.systemUptime)
                })
            }
        }
    }

    /// A frame stamped `ago` seconds before now.
    private func frame(_ buffer: CVPixelBuffer, seq: Int, ago: TimeInterval = 0) -> SnapshotFrame {
        SnapshotFrame(buffer: buffer, seq: seq, at: ProcessInfo.processInfo.systemUptime - ago,
                      origin: .keyframe)
    }
    func testAPhoneThatAnswersWithAnOldIdrIsAskedAgain_MCP60() async throws {
        let source = PhoneSource(
            newestSeq: 40,
            asks: [Ask(deliver: nil), Ask(deliver: makeBuffer(width: 64, height: 64, value: 90),
                                          after: 0.3)],
            displayed: makeBuffer(width: 64, height: 64, value: 90))
        let started = ProcessInfo.processInfo.systemUptime
        let answer = try await shot(id: 3, state: "live", source: source, size: (64, 64), crop: nil)
        XCTAssertEqual(source.asked, 2, "the Mac asked a second time")
        let frame = try XCTUnwrap(answer["frame"] as? [String: Any])
        XCTAssertNil(frame["still"], "a keyframe's frame needs no still flag")
        XCTAssertNil(answer["still"], "still is never a top-level key")
        XCTAssertEqual(frame["seq"] as? Int, 41)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 2,
                          "the second ask lands well inside the one 2 s bound")
    }

    // [MCP-60] #274: a still window sends no frame and says so (`window.still`)
    // instead; the call answers the shown frame, marked still inside its frame,
    // with its real age, and at once rather than wait out the bound.
    func testAStillWindowAnswersTheShownFrame_MCP60() async throws {
        let shown = makeBuffer(width: 64, height: 64, value: 90)
        let source = PhoneSource(newestSeq: 12, newestAt: ProcessInfo.processInfo.systemUptime - 30,
                                  asks: [], displayed: shown, stillAfter: 0.1)
        let started = ProcessInfo.processInfo.systemUptime
        let answer = try await shot(id: 3, state: "live", source: source, size: (64, 64), crop: nil)
        XCTAssertNil(answer["still"], "still lives inside frame, not beside it (MCP-62)")
        let frame = try XCTUnwrap(answer["frame"] as? [String: Any])
        XCTAssertEqual(frame["still"] as? Bool, true)
        XCTAssertEqual(frame["seq"] as? Int, 12, "the answer is the frame the phone vouched for")
        XCTAssertGreaterThanOrEqual(frame["ageMs"] as? Int ?? -1, 30_000, "its real age")
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 1,
                          "answered at once, well under the 2 s bound")
    }

    // [MCP-61] A frame older than a minute is still the picture when the phone
    // says so: the age is told, never used as a reason to fail. A static page
    // left open for 2 minutes must not fail `no_frame` again.
    func testALongQuietWindowAnswersWithItsRealAge_MCP61() async throws {
        let source = PhoneSource(newestSeq: 40, newestAt: ProcessInfo.processInfo.systemUptime - 125,
                                  asks: [], displayed: makeBuffer(width: 64, height: 64, value: 8),
                                  stillAfter: 0.1)
        let answer = try await shot(id: 3, state: "live", source: source, size: (64, 64), crop: nil)
        let frame = try XCTUnwrap(answer["frame"] as? [String: Any])
        XCTAssertEqual(frame["still"] as? Bool, true)
        XCTAssertGreaterThanOrEqual(frame["ageMs"] as? Int ?? -1, 125_000,
                                    "the real age, past the old 60 s cap")
    }

    // [MCP-61] #274 review: a `window.still` that arrived before the call
    // answers nothing. If a fresh keyframe arrives it wins; if none does the
    // call fails `no_frame` at its bound — it never hands back the pre-call
    // picture (#165).
    func testAPreCallStillAnswersNothing_MCP61() async throws {
        let source = PhoneSource(
            newestSeq: 40, newestAt: ProcessInfo.processInfo.systemUptime - 5,
            asks: [Ask(deliver: makeBuffer(width: 64, height: 64, value: 90), after: 0.1)],
            displayed: makeBuffer(width: 64, height: 64, value: 8), stillBefore: 0.4)
        let answer = try await shot(id: 3, state: "live", source: source, size: (64, 64), crop: nil)
        let frame = try XCTUnwrap(answer["frame"] as? [String: Any])
        XCTAssertNil(frame["still"], "the fresh keyframe wins, not the pre-call still")
        XCTAssertEqual(frame["seq"] as? Int, 41)
    }

    // [MCP-61] The same pre-call still with no keyframe behind it: `no_frame`
    // at the bound, and the display layer is never read for the answer.
    func testAPreCallStillIsNoFrame_MCP61() async throws {
        let source = PhoneSource(newestSeq: 40, newestAt: ProcessInfo.processInfo.systemUptime - 5,
                                  asks: [], displayed: makeBuffer(width: 64, height: 64, value: 8),
                                  stillBefore: 0.4)
        do {
            _ = try await Screenshot.result(id: 3, state: { "live" }, source: source,
                                            size: (64, 64), crop: nil)
            XCTFail("a still from before the call answered a picture")
        } catch let error as MCPToolError {
            XCTAssertEqual(error.code, .noFrame)
        }
    }

    // [MCP-60] A fresh keyframe that arrives before the still wins.
    func testAFreshKeyframeBeatsTheStill_MCP60() async throws {
        let source = PhoneSource(
            newestSeq: 40, asks: [Ask(deliver: makeBuffer(width: 64, height: 64, value: 90))],
            displayed: makeBuffer(width: 64, height: 64, value: 8), stillAfter: 0.05)
        let answer = try await shot(id: 3, state: "live", source: source, size: (64, 64), crop: nil)
        let frame = try XCTUnwrap(answer["frame"] as? [String: Any])
        XCTAssertNil(frame["still"], "the answer is a keyframe, not a still")
        XCTAssertEqual(frame["seq"] as? Int, 41)
    }

    // [MCP-61] A window with no displayed frame at all is still `no_frame`,
    // even when the phone says it is still: there is no picture to show.
    func testAStillWithNoDisplayedFrameIsNoFrame_MCP61() async throws {
        let source = PhoneSource(newestSeq: 0, asks: [], stillAfter: 0.05)
        let started = ProcessInfo.processInfo.systemUptime
        do {
            _ = try await Screenshot.result(id: 3, state: { "live" }, source: source,
                                            size: (64, 64), crop: nil)
            XCTFail("expected no_frame")
        } catch let error as MCPToolError {
            XCTAssertEqual(error.code, .noFrame)
            XCTAssertEqual(error.extra["state"] as? String, "live")
        }
        XCTAssertEqual(source.displays, 0,
                       "a still never vouches for a picture that was never counted")
        XCTAssertGreaterThanOrEqual(ProcessInfo.processInfo.systemUptime - started, 1.9,
                                    "with nothing to show the bound decides, not the still")
    }

    // [MCP-61] Neither still nor sending: `no_frame`, as it always was.
    func testANeitherStillNorSendingPhoneIsNoFrame_MCP61() async throws {
        let source = PhoneSource(newestSeq: 5, asks: [], displayed: makeBuffer(width: 64, height: 64,
                                                                             value: 9))
        do {
            _ = try await Screenshot.result(id: 3, state: { "live" }, source: source,
                                            size: (64, 64), crop: nil)
            XCTFail("expected no_frame")
        } catch let error as MCPToolError {
            XCTAssertEqual(error.code, .noFrame)
            XCTAssertEqual(source.displays, 0, "a still that never came reads no buffer")
        }
    }

    // [MCP-61] An offline window can't make a picture: say so at once,
    // without asking for a keyframe or waiting out the 2 s bound.
    func testAnOfflinePhoneIsPhoneOfflineAtOnce() async throws {
        let source = FakeSource(newestSeq: 7, deliver: nil)
        let started = ProcessInfo.processInfo.systemUptime
        do {
            _ = try await Screenshot.result(id: 3, state: { "offline" }, source: source,
                                            size: (64, 64), crop: nil,
                                            online: false, phone: "Pixel")
            XCTFail("an offline phone answered a screenshot")
        } catch let error as MCPToolError {
            XCTAssertEqual(error.code, .phoneOffline)
            XCTAssertEqual(error.message, MCPToolError.phoneOffline("Pixel").message)
        }
        XCTAssertNil(source.askedAfter, "no keyframe is asked of an offline phone")
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 0.5)
    }

    // [MCP-60]
    func testTheAnswerIsAFrameThatArrivedAfterTheCall() async throws {
        let source = FakeSource(newestSeq: 40, deliver: frame(
            makeBuffer(width: 64, height: 64, value: 128), seq: 41, ago: 0.012))
        let answer = try await shot(
            id: 3, state: "live", source: source, size: (64, 64), crop: nil)
        XCTAssertEqual(source.askedAfter, 40, "the frame must come after the call's newest")
        let frame = try XCTUnwrap(answer["frame"] as? [String: Any])
        XCTAssertEqual(frame["seq"] as? Int, 41)
        // Stamped 12 ms before the call: at least that old when answered.
        XCTAssertGreaterThanOrEqual(frame["ageMs"] as? Int ?? -1, 12)
        XCTAssertEqual(answer["state"] as? String, "live")
        XCTAssertEqual(answer["window"] as? Int, 3)
        XCTAssertEqual(answer["image"] as? [Int], [64, 64])
        XCTAssertEqual(answer["size"] as? [Int], [64, 64])
        XCTAssertNil(answer["crop"])
    }

    // [MCP-60] The PNG's longest side is at most 1280 px; `size` stays the window's.
    func testTheImageIsScaledButSizeIsTheWindows() async throws {
        let source = FakeSource(newestSeq: 0, deliver: frame(makeBuffer(width: 1080, height: 2400, value: 90), seq: 1, ago: 0))
        let answer = try await shot(
            id: 3, state: "live", source: source, size: (1080, 2400), crop: nil)
        XCTAssertEqual(answer["image"] as? [Int], [576, 1280])
        XCTAssertEqual(answer["size"] as? [Int], [1080, 2400])
    }

    // [MCP-61]
    func testNoKeyframeIsNoFrame() async throws {
        let source = FakeSource(newestSeq: 7, deliver: nil)
        do {
            _ = try await Screenshot.result(id: 3, state: { "paused" }, source: source,
                                            size: (1080, 2400), crop: nil)
            XCTFail("expected no_frame")
        } catch let error as MCPToolError {
            XCTAssertEqual(error.code, .noFrame)
            XCTAssertEqual(error.extra["state"] as? String, "paused")
            XCTAssertTrue(error.message.hasPrefix("Window 3 is paused: no new picture arrived in 2 s."),
                          error.message)
        }
    }

    // [MCP-61] An opening window says it has no picture yet.
    func testAnOpeningWindowHasNoPictureYet() async throws {
        do {
            _ = try await Screenshot.result(id: 3, state: { "opening" },
                                            source: FakeSource(newestSeq: 0, deliver: nil),
                                            size: (1080, 2400), crop: nil)
            XCTFail("expected no_frame")
        } catch let error as MCPToolError {
            XCTAssertEqual(error.code, .noFrame)
            XCTAssertEqual(error.extra["state"] as? String, "opening")
            XCTAssertTrue(error.message.hasPrefix("Window 3 is opening: no picture yet."), error.message)
        }
    }

    // [MCP-62]
    func testAOneColourFrameIsBlank() async throws {
        let black = makeBuffer(width: 64, height: 64, value: 0)
        let half = makeBuffer(width: 64, height: 64, value: 0, whiteLeftColumns: 32)
        let blank = try await shot(
            id: 3, state: "live", source: FakeSource(newestSeq: 0, deliver: frame(black, seq: 1, ago: 0)), size: (64, 64), crop: nil)
        XCTAssertEqual(blank["blank"] as? Bool, true)
        let notBlank = try await shot(
            id: 3, state: "live", source: FakeSource(newestSeq: 0, deliver: frame(half, seq: 1, ago: 0)), size: (64, 64), crop: nil)
        XCTAssertNil(notBlank["blank"])
    }

    // [MCP-63]
    func testARefCropsToItsBox() async throws {
        let placed = UITreeResolution.placed(snapshot: 2, placed: .init(
            point: .init(x: 0.5, y: 0.5), box: [100, 200, 300, 260], off: false))
        let crop = try ScreenshotCrop.box(for: placed, ref: "s2e1", window: 3, size: (1080, 2400))
        XCTAssertEqual(crop, [92, 192, 308, 268])
        // Clamped to the frame.
        let edge = UITreeResolution.placed(snapshot: 2, placed: .init(
            point: .init(x: 0, y: 0), box: [2, 3, 1078, 2399], off: false))
        XCTAssertEqual(try ScreenshotCrop.box(for: edge, ref: "s2e2", window: 3, size: (1080, 2400)),
                       [0, 0, 1080, 2400])
        // The answer is the crop, scaled, and names it.
        let source = FakeSource(newestSeq: 0, deliver: frame(makeBuffer(width: 1080, height: 2400, value: 90), seq: 1, ago: 0))
        let answer = try await shot(
            id: 3, state: "live", source: source, size: (1080, 2400), crop: crop)
        XCTAssertEqual(answer["crop"] as? [Int], [92, 192, 308, 268])
        XCTAssertEqual(answer["image"] as? [Int], [216, 76])
        // A ref the window's latest tree does not name fails stale_ref.
        XCTAssertThrowsError(try ScreenshotCrop.box(for: .noTree, ref: "s1e1", window: 3,
                                                    size: (1080, 2400))) { error in
            XCTAssertEqual((error as? MCPToolError)?.code, .staleRef)
        }
        XCTAssertThrowsError(try ScreenshotCrop.box(for: .stale(ref: "s1e1", snapshot: 1, latest: 2),
                                                    ref: "s1e1", window: 3,
                                                    size: (1080, 2400))) { error in
            XCTAssertEqual((error as? MCPToolError)?.code, .staleRef)
        }
        // A ref to an off-screen node fails off_screen.
        let off = UITreeResolution.placed(snapshot: 2, placed: .init(point: nil, box: [0, 0, 10, 10], off: true))
        XCTAssertThrowsError(try ScreenshotCrop.box(for: off, ref: "s2e3", window: 3,
                                                    size: (1080, 2400))) { error in
            XCTAssertEqual((error as? MCPToolError)?.code, .offScreen)
        }
    }

    // [MCP-63] The tree's box is in the display's pixels; the frame can be
    // smaller (the Phone Mirror: a 1080×2340 display, a 592×1280 stream). The
    // crop is answered in display pixels and applied scaled to the frame.
    func testARefCropsInFramePixelsWhenTheDisplayIsLarger() async throws {
        let placed = UITreeResolution.placed(snapshot: 4, placed: .init(
            point: .init(x: 0.5, y: 0.96), box: [48, 2210, 1032, 2290], off: false))
        let crop = try ScreenshotCrop.box(for: placed, ref: "s4e9", window: 3, size: (1080, 2340))
        XCTAssertEqual(crop, [40, 2202, 1040, 2298])
        let rect = ScreenshotCrop.frameRect(crop: crop, size: (1080, 2340), frame: (592, 1280))
        XCTAssertEqual(rect, [21, 1204, 571, 1258])
        let source = FakeSource(newestSeq: 0, deliver: frame(
            makeBuffer(width: 592, height: 1280, value: 90), seq: 1))
        let answer = try await shot(id: 3, state: "live", source: source, size: (1080, 2340), crop: crop)
        XCTAssertEqual(answer["crop"] as? [Int], [40, 2202, 1040, 2298])
        XCTAssertEqual(answer["size"] as? [Int], [1080, 2340])
        XCTAssertEqual(answer["image"] as? [Int], [550, 54], "the cropped frame area, at its own scale")
    }

    // [MCP-63] A box near the top maps to the frame's top rows, not to rows
    // scaled the wrong way.
    func testARefNearTheTopCropsTheFramesTopRows() throws {
        let placed = UITreeResolution.placed(snapshot: 4, placed: .init(
            point: .init(x: 0.5, y: 0.03), box: [540, 60, 1000, 140], off: false))
        let crop = try ScreenshotCrop.box(for: placed, ref: "s4e2", window: 3, size: (1080, 2340))
        XCTAssertEqual(crop, [532, 52, 1008, 148])
        XCTAssertEqual(ScreenshotCrop.frameRect(crop: crop, size: (1080, 2340), frame: (592, 1280)),
                       [291, 28, 553, 81])
        // Equal spaces: the crop is the frame rect.
        XCTAssertEqual(ScreenshotCrop.frameRect(crop: crop, size: (1080, 2340), frame: (1080, 2340)), crop)
    }

    // [MCP-50] [MCP-62] A window's `size` is the display's pixels: the tree's
    // `size` when there is a tree; for the Phone Mirror without one, the
    // phone's screen turned to the stream's orientation; else the stream's.
    func testAMirrorsSizeIsTheDisplaysInBothOrientations() async throws {
        let phone = CGSize(width: 1080, height: 2340)
        XCTAssertTrue(MCPWindowSize.pixels(treeSize: nil, mirrorScreen: phone, stream: (592, 1280))
                      == (1080, 2340))
        XCTAssertTrue(MCPWindowSize.pixels(treeSize: nil, mirrorScreen: phone, stream: (1280, 592))
                      == (2340, 1080))
        // The phone may report its screen turned the other way: the stream decides.
        XCTAssertTrue(MCPWindowSize.pixels(treeSize: nil, mirrorScreen: CGSize(width: 2340, height: 1080),
                                           stream: (592, 1280)) == (1080, 2340))
        // A tree's size wins; an app window's display is its stream.
        XCTAssertTrue(MCPWindowSize.pixels(treeSize: [2340, 1080], mirrorScreen: phone, stream: (1280, 592))
                      == (2340, 1080))
        XCTAssertTrue(MCPWindowSize.pixels(treeSize: nil, mirrorScreen: nil, stream: (590, 1280))
                      == (590, 1280))
        // The screenshot answers that size, whatever the frame's.
        let source = FakeSource(newestSeq: 0, deliver: frame(
            makeBuffer(width: 592, height: 1280, value: 90), seq: 1))
        let answer = try await shot(id: 3, state: "live", source: source, size: (1080, 2340), crop: nil)
        XCTAssertEqual(answer["size"] as? [Int], [1080, 2340])
        XCTAssertEqual(answer["image"] as? [Int], [592, 1280])
    }

    // [MCP-61] A window that closed while the call waited fails no_window,
    // not no_frame pointing at ui_tree.
    func testAWindowClosedAtTheBoundIsNoWindow() async throws {
        // Live when the call starts; closed once it is waiting for a keyframe.
        let source = FakeSource(newestSeq: 0, deliver: nil)
        do {
            _ = try await Screenshot.result(id: 3, state: { source.askedAfter == nil ? "live" : "closed" },
                                            source: source,
                                            size: (1080, 2400), crop: nil)
            XCTFail("expected no_window")
        } catch let error as MCPToolError {
            XCTAssertEqual(error.code, .noWindow)
            XCTAssertEqual(error.message, MCPToolError.noWindow(3).message)
        }
    }

    // [MCP-61] A frame that arrived but would not encode is `failed`, and
    // the sentence does not claim that no picture arrived.
    func testAnEncodeFailureIsFailed() async throws {
        let source = FakeSource(newestSeq: 0, deliver: frame(makeBuffer(width: 64, height: 64, value: 90), seq: 1))
        do {
            _ = try await Screenshot.result(id: 3, state: { "live" }, source: source,
                                            size: (64, 64), crop: nil, encode: { _, _ in nil })
            XCTFail("expected failed")
        } catch let error as MCPToolError {
            XCTAssertEqual(error.code, .failed)
            XCTAssertFalse(error.message.contains("no new picture arrived"), error.message)
            XCTAssertEqual(error.extra["window"] as? Int, 3)
        }
    }

    // [MCP-61] The 2 s bound covers Live Text's capture too: the keyframe
    // wait gets only the time left.
    func testTheBoundIncludesLiveTextsCaptureWait() async throws {
        let source = FakeSource(newestSeq: 0, deliver: nil, capturingFor: 1.5)
        let started = ProcessInfo.processInfo.systemUptime
        do {
            _ = try await Screenshot.result(id: 3, state: { "live" }, source: source,
                                            size: (64, 64), crop: nil)
            XCTFail("expected no_frame")
        } catch let error as MCPToolError {
            XCTAssertEqual(error.code, .noFrame)
        }
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        XCTAssertLessThan(elapsed, 2.3, "the whole call stays inside the 2 s bound")
        XCTAssertLessThanOrEqual(source.askedTimeout ?? 99, 0.6)
    }

    // [MCP-20] `frame.ageMs` is the frame's age when the answer is made, not
    // when it was decoded.
    func testAgeIsTakenWhenTheAnswerIsMade() async throws {
        let source = FakeSource(newestSeq: 4, deliver: frame(
            makeBuffer(width: 64, height: 64, value: 90), seq: 5, ago: 0.5), deliverAfter: 0.2)
        let answer = try await shot(id: 3, state: "live", source: source, size: (64, 64), crop: nil)
        let frame = try XCTUnwrap(answer["frame"] as? [String: Any])
        XCTAssertGreaterThanOrEqual(frame["ageMs"] as? Int ?? -1, 650)
    }
}
