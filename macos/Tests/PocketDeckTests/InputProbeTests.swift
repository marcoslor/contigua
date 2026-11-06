// P0 (pmaxx): the input-to-photon probe's pure half and its luma comparison.
// A tap's effect is the first frame whose watched region changed; the model is
// clock-injected so every transition is pinned without a phone or a window.

import CoreVideo
import XCTest
@testable import PocketDeck

final class InputProbeTests: XCTestCase {
    private func flat(_ value: UInt8) -> ProbeSignature {
        ProbeSignature(cells: Array(repeating: value, count: ProbeSignature.side * ProbeSignature.side))
    }

    private func buffer(fill: UInt8, changed: Bool) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let attributes: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]]
        guard CVPixelBufferCreate(kCFAllocatorDefault, 64, 64, kCVPixelFormatType_32BGRA,
                                  attributes as CFDictionary, &buffer) == kCVReturnSuccess,
              let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        for row in 0..<64 {
            for column in 0..<64 {
                let offset = row * stride + column * 4
                let value: UInt8 = (changed && row < 32 && column < 32) ? 0 : fill
                bytes[offset] = value
                bytes[offset + 1] = value
                bytes[offset + 2] = value
                bytes[offset + 3] = 255
            }
        }
        return buffer
    }

    private func biplanarBuffer(fillY: UInt8) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let attributes: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]]
        guard CVPixelBufferCreate(kCFAllocatorDefault, 64, 64,
                                  kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                                  attributes as CFDictionary, &buffer) == kCVReturnSuccess,
              let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else { return nil }
        let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        for row in 0..<64 {
            for column in 0..<64 {
                bytes[row * stride + column] = fillY
            }
        }
        return buffer
    }

    // MARK: Region and signal

    func testRegionAroundTheTapStaysInsideThePicture() {
        let corner = ProbeRegion.around(x: 0.01, y: 0.99, width: 0.4, height: 0.4)
        XCTAssertEqual(corner.x, 0, accuracy: 0.0001)
        XCTAssertEqual(corner.y, 0.6, accuracy: 0.0001)
        XCTAssertEqual(corner.width, 0.4, accuracy: 0.0001)
        // A bad size is clamped to something a grid can be taken from.
        let tiny = ProbeRegion.around(x: 0.5, y: 0.5, width: 0, height: 2)
        XCTAssertEqual(tiny.width, 0.05, accuracy: 0.0001)
        XCTAssertEqual(tiny.height, 1, accuracy: 0.0001)
        XCTAssertEqual(ProbeRegion.whole.rect(in: CGSize(width: 100, height: 50)),
                       CGRect(x: 0, y: 0, width: 100, height: 50))
    }

    func testTheSignatureIsAStableLumaGrid() throws {
        let first = try XCTUnwrap(buffer(fill: 40, changed: false))
        let same = try XCTUnwrap(buffer(fill: 40, changed: false))
        let other = try XCTUnwrap(buffer(fill: 40, changed: true))
        let a = try XCTUnwrap(ProbeSignal.signature(of: first, region: .whole))
        let b = try XCTUnwrap(ProbeSignal.signature(of: same, region: .whole))
        let c = try XCTUnwrap(ProbeSignal.signature(of: other, region: .whole))
        XCTAssertEqual(a, b)
        XCTAssertFalse(ProbeSignal.changed(a, b))
        XCTAssertTrue(ProbeSignal.changed(a, c), "a quarter of the picture going dark is a change")
        XCTAssertFalse(ProbeSignal.changed(a, flat(40)))
        XCTAssertFalse(ProbeSignal.signature(of: first, region: ProbeRegion(x: 0.99, y: 0.99,
                                                                           width: 0.01, height: 0.01)) != nil)
    }

    func testAVideoRangeFrameComparesInFullRangeLevels() throws {
        // The display layer may hand back a biplanar frame while the probe's
        // decoder outputs BGRA: black in video range is 16, and must not read
        // as a change against BGRA black.
        let videoBlack = try XCTUnwrap(biplanarBuffer(fillY: 16))
        let bgraBlack = try XCTUnwrap(buffer(fill: 0, changed: false))
        let videoWhite = try XCTUnwrap(biplanarBuffer(fillY: 235))
        let bgraWhite = try XCTUnwrap(buffer(fill: 255, changed: false))
        let black = try XCTUnwrap(ProbeSignal.signature(of: videoBlack, region: .whole))
        let bgra = try XCTUnwrap(ProbeSignal.signature(of: bgraBlack, region: .whole))
        XCTAssertEqual(black, bgra)
        XCTAssertFalse(ProbeSignal.changed(black, bgra))
        XCTAssertEqual(try XCTUnwrap(ProbeSignal.signature(of: videoWhite, region: .whole)),
                       try XCTUnwrap(ProbeSignal.signature(of: bgraWhite, region: .whole)))
    }

    // MARK: The machine

    func testTheProbeWaitsForABaselineBeforeTheTap() {
        var transitions: [String] = []
        var model = InputProbeModel { transitions.append($0) }
        XCTAssertEqual(model.phase, .idle)
        XCTAssertNil(model.handle(.frame(flat(10), atMs: 0)))
        XCTAssertEqual(model.phase, .idle)
        XCTAssertNil(model.handle(.tapSent(atMs: 10)))
        XCTAssertNil(model.handle(.arm))
        XCTAssertEqual(model.phase, .waitingBaseline)
        XCTAssertNil(model.handle(.tapSent(atMs: 20)), "a tap before the baseline is ignored")
        XCTAssertEqual(model.handle(.frame(flat(10), atMs: 30)), .armed)
        XCTAssertEqual(model.phase, .watching)
        XCTAssertEqual(model.frames, 1)
        XCTAssertEqual(model.handle(.frame(flat(10), atMs: 40)), nil, "no tap yet: no answer")
        XCTAssertNil(model.handle(.tapSent(atMs: 50)))
        XCTAssertNil(model.handle(.frame(flat(10), atMs: 55)), "unchanged")
        XCTAssertEqual(model.handle(.frame(flat(200), atMs: 70)), .changed(ms: 20))
        XCTAssertEqual(model.phase, .done)
        XCTAssertEqual(model.changedMs ?? -1, 20, accuracy: 0.001)
        XCTAssertNil(model.handle(.frame(flat(0), atMs: 80)), "done ignores every event")
        XCTAssertNil(model.handle(.deadline))
        XCTAssertTrue(transitions.contains("input probe: waiting_baseline --baseline--> watching"),
                      transitions.joined(separator: "\n"))
        XCTAssertTrue(transitions.contains("input probe: watching --changed--> done"))
    }

    func testAFrameBeforeTheTapCannotChangeTheAnswer() {
        var model = InputProbeModel()
        _ = model.handle(.arm)
        _ = model.handle(.frame(flat(10), atMs: 0))
        XCTAssertNil(model.handle(.frame(flat(200), atMs: 10)), "a change before the tap is the wrong event")
        _ = model.handle(.tapSent(atMs: 20))
        XCTAssertNil(model.handle(.frame(flat(200), atMs: 10)))
        XCTAssertEqual(model.handle(.frame(flat(200), atMs: 30)), .changed(ms: 10))
    }

    func testDeadlinesAtBothWaits() {
        var waiting = InputProbeModel()
        _ = waiting.handle(.arm)
        XCTAssertEqual(waiting.handle(.deadline), .timedOut)
        XCTAssertEqual(waiting.phase, .done)

        var watching = InputProbeModel()
        _ = watching.handle(.arm)
        _ = watching.handle(.frame(flat(10), atMs: 0))
        _ = watching.handle(.tapSent(atMs: 5))
        XCTAssertEqual(watching.handle(.deadline), .timedOut)
        XCTAssertEqual(watching.changedMs, nil)
    }
}
