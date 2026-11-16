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
    /// layer's buffer, which a screenshot must never read.
    @MainActor
    private final class FakeSource: ScreenshotSource {
        let newestSeq: Int
        let deliver: SnapshotFrame?
        private(set) var askedAfter: Int?
        init(newestSeq: Int, deliver: SnapshotFrame?) {
            self.newestSeq = newestSeq
            self.deliver = deliver
        }
        func copyDisplayedFrame() -> CVPixelBuffer? {
            XCTFail("a screenshot read the display layer's buffer")
            return nil
        }
        func nextKeyframe(after seq: Int, timeout: TimeInterval) async -> SnapshotFrame? {
            askedAfter = seq
            return deliver
        }
    }

    /// The screenshot's answer object; fails the test when it is not an image.
    private func shot(id: Int, state: String, source: ScreenshotSource, streamSize: (Int, Int),
                      crop: [Int]?) async throws -> [String: Any] {
        let result = try await Screenshot.result(id: id, state: state, source: source,
                                                 streamSize: streamSize, crop: crop)
        guard case .image(_, let answer) = result else {
            XCTFail("expected an image")
            return [:]
        }
        return answer
    }

    // [MCP-60]
    func testTheAnswerIsAFrameThatArrivedAfterTheCall() async throws {
        let source = FakeSource(newestSeq: 40, deliver: SnapshotFrame(
            buffer: makeBuffer(width: 64, height: 64, value: 128), seq: 41, ageMs: 12))
        let answer = try await shot(
            id: 3, state: "live", source: source, streamSize: (64, 64), crop: nil)
        XCTAssertEqual(source.askedAfter, 40, "the frame must come after the call's newest")
        let frame = try XCTUnwrap(answer["frame"] as? [String: Any])
        XCTAssertEqual(frame["seq"] as? Int, 41)
        XCTAssertEqual(frame["ageMs"] as? Int, 12)
        XCTAssertEqual(answer["state"] as? String, "live")
        XCTAssertEqual(answer["window"] as? Int, 3)
        XCTAssertEqual(answer["image"] as? [Int], [64, 64])
        XCTAssertEqual(answer["size"] as? [Int], [64, 64])
        XCTAssertNil(answer["crop"])
    }

    // [MCP-60] The PNG's longest side is at most 1280 px; `size` stays the window's.
    func testTheImageIsScaledButSizeIsTheWindows() async throws {
        let source = FakeSource(newestSeq: 0, deliver: SnapshotFrame(
            buffer: makeBuffer(width: 1080, height: 2400, value: 90), seq: 1, ageMs: 0))
        let answer = try await shot(
            id: 3, state: "live", source: source, streamSize: (1080, 2400), crop: nil)
        XCTAssertEqual(answer["image"] as? [Int], [576, 1280])
        XCTAssertEqual(answer["size"] as? [Int], [1080, 2400])
    }

    // [MCP-61]
    func testNoKeyframeIsNoFrame() async throws {
        let source = FakeSource(newestSeq: 7, deliver: nil)
        do {
            _ = try await Screenshot.result(id: 3, state: "paused", source: source,
                                            streamSize: (1080, 2400), crop: nil)
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
            _ = try await Screenshot.result(id: 3, state: "opening",
                                            source: FakeSource(newestSeq: 0, deliver: nil),
                                            streamSize: (1080, 2400), crop: nil)
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
            id: 3, state: "live", source: FakeSource(newestSeq: 0, deliver: SnapshotFrame(
                buffer: black, seq: 1, ageMs: 0)), streamSize: (64, 64), crop: nil)
        XCTAssertEqual(blank["blank"] as? Bool, true)
        let notBlank = try await shot(
            id: 3, state: "live", source: FakeSource(newestSeq: 0, deliver: SnapshotFrame(
                buffer: half, seq: 1, ageMs: 0)), streamSize: (64, 64), crop: nil)
        XCTAssertNil(notBlank["blank"])
    }

    // [MCP-63]
    func testARefCropsToItsBox() async throws {
        let placed = UITreeResolution.placed(snapshot: 2, placed: .init(
            point: .init(x: 0.5, y: 0.5), box: [100, 200, 300, 260], off: false))
        let crop = try ScreenshotCrop.box(for: placed, ref: "s2e1", window: 3, frameSize: (1080, 2400))
        XCTAssertEqual(crop, [92, 192, 308, 268])
        // Clamped to the frame.
        let edge = UITreeResolution.placed(snapshot: 2, placed: .init(
            point: .init(x: 0, y: 0), box: [2, 3, 1078, 2399], off: false))
        XCTAssertEqual(try ScreenshotCrop.box(for: edge, ref: "s2e2", window: 3, frameSize: (1080, 2400)),
                       [0, 0, 1080, 2400])
        // The answer is the crop, scaled, and names it.
        let source = FakeSource(newestSeq: 0, deliver: SnapshotFrame(
            buffer: makeBuffer(width: 1080, height: 2400, value: 90), seq: 1, ageMs: 0))
        let answer = try await shot(
            id: 3, state: "live", source: source, streamSize: (1080, 2400), crop: crop)
        XCTAssertEqual(answer["crop"] as? [Int], [92, 192, 308, 268])
        XCTAssertEqual(answer["image"] as? [Int], [216, 76])
        // A ref the window's latest tree does not name fails stale_ref.
        XCTAssertThrowsError(try ScreenshotCrop.box(for: .noTree, ref: "s1e1", window: 3,
                                                    frameSize: (1080, 2400))) { error in
            XCTAssertEqual((error as? MCPToolError)?.code, .staleRef)
        }
        XCTAssertThrowsError(try ScreenshotCrop.box(for: .stale(ref: "s1e1", snapshot: 1, latest: 2),
                                                    ref: "s1e1", window: 3,
                                                    frameSize: (1080, 2400))) { error in
            XCTAssertEqual((error as? MCPToolError)?.code, .staleRef)
        }
        // A ref to an off-screen node fails off_screen.
        let off = UITreeResolution.placed(snapshot: 2, placed: .init(point: nil, box: [0, 0, 10, 10], off: true))
        XCTAssertThrowsError(try ScreenshotCrop.box(for: off, ref: "s2e3", window: 3,
                                                    frameSize: (1080, 2400))) { error in
            XCTAssertEqual((error as? MCPToolError)?.code, .offScreen)
        }
    }
}
