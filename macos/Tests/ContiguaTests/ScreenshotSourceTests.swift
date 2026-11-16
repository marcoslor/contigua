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
    /// models Live Text's freeze holding the decoder; `waitsOutBound` makes a
    /// source with no frame take its whole timeout, as a real one does.
    @MainActor
    private final class FakeSource: ScreenshotSource {
        let newestSeq: Int
        let deliver: SnapshotFrame?
        let deliverAfter: TimeInterval
        let waitsOutBound: Bool
        private let capturingUntil: TimeInterval
        private(set) var askedAfter: Int?
        private(set) var askedTimeout: TimeInterval?
        init(newestSeq: Int, deliver: SnapshotFrame?, deliverAfter: TimeInterval = 0,
             capturingFor: TimeInterval = 0, waitsOutBound: Bool = false) {
            self.newestSeq = newestSeq
            self.deliver = deliver
            self.deliverAfter = deliverAfter
            self.waitsOutBound = waitsOutBound
            self.capturingUntil = ProcessInfo.processInfo.systemUptime + capturingFor
        }
        var isCapturing: Bool { ProcessInfo.processInfo.systemUptime < capturingUntil }
        func copyDisplayedFrame() -> CVPixelBuffer? {
            XCTFail("a screenshot read the display layer's buffer")
            return nil
        }
        func nextKeyframe(after seq: Int, timeout: TimeInterval) async -> SnapshotFrame? {
            askedAfter = seq
            askedTimeout = timeout
            if deliver == nil, waitsOutBound {
                try? await Task.sleep(nanoseconds: UInt64(max(0, timeout) * 1_000_000_000))  // real-time: the bound under test is wall-clock (MCP-61)
            } else if deliverAfter > 0 {
                try? await Task.sleep(nanoseconds: UInt64(deliverAfter * 1_000_000_000))  // real-time: the answer's age is wall-clock (MCP-20)
            }
            return deliver
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

    /// A frame stamped `ago` seconds before now.
    private func frame(_ buffer: CVPixelBuffer, seq: Int, ago: TimeInterval = 0) -> SnapshotFrame {
        SnapshotFrame(buffer: buffer, seq: seq, at: ProcessInfo.processInfo.systemUptime - ago)
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
        let source = FakeSource(newestSeq: 0, deliver: nil, capturingFor: 1.5, waitsOutBound: true)
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
