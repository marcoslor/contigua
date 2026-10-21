// The frozen frame's pixel work (docs/design/livetext.md, "Frame route"): the
// display layer's displayed buffer draws correctly but is not readable through
// its memory, which is why v105 froze a frame full of text and recognised 0
// characters. The snapshot Live Text keeps is a 32BGRA buffer of our own, and
// the analyser runs on the rasterised image. These tests pin the copy: same
// picture, CPU-readable, and the entry diagnostics (size, format, mean luma)
// that make a blank frame visible in a log.

import AppKit
import CoreVideo
import CoreGraphics
import XCTest
@testable import PocketDeck

final class LiveTextFrameTests: XCTestCase {
    /// A uniform frame in a planar 4:2:0 format, the shape a decoder hands over.
    private func planarBuffer(luma: UInt8, format: OSType) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, 320, 200, format, nil, &buffer)
                == kCVReturnSuccess, let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        if CVPixelBufferIsPlanar(buffer) {
            for plane in 0..<CVPixelBufferGetPlaneCount(buffer) {
                guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, plane) else { continue }
                let height = CVPixelBufferGetHeightOfPlane(buffer, plane)
                let bytes = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
                for row in 0..<height {
                    memset(base.advanced(by: row * bytes), plane == 0 ? Int32(luma) : 128, bytes)
                }
            }
        }
        return buffer
    }

    private func bgraBuffer(luma: UInt8) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, 320, 200, kCVPixelFormatType_32BGRA,
                                  nil, &buffer) == kCVReturnSuccess, let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        for row in 0..<CVPixelBufferGetHeight(buffer) {
            memset(base.advanced(by: row * CVPixelBufferGetBytesPerRow(buffer)), Int32(luma),
                   CVPixelBufferGetBytesPerRow(buffer))
        }
        return buffer
    }

    func testTheSnapshotIsReadableAndKeepsThePicture() throws {
        let source = try XCTUnwrap(bgraBuffer(luma: 200))
        let snapshot = try XCTUnwrap(LiveTextImage.snapshot(source),
                                     "the frame could not be copied onto our side")
        XCTAssertEqual(CVPixelBufferGetPixelFormatType(snapshot), kCVPixelFormatType_32BGRA)
        XCTAssertEqual(CVPixelBufferGetWidth(snapshot), 320)
        XCTAssertEqual(CVPixelBufferGetHeight(snapshot), 200)
        XCTAssertEqual(CVPixelBufferLockBaseAddress(snapshot, .readOnly), kCVReturnSuccess)
        defer { CVPixelBufferUnlockBaseAddress(snapshot, .readOnly) }
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(snapshot),
                                 "the copy must be readable through its memory (the analyser's path)")
        let pixel = base.advanced(by: CVPixelBufferGetBytesPerRow(snapshot) * 100 + 4 * 100)
            .assumingMemoryBound(to: UInt8.self)
        XCTAssertEqual(Int(pixel[1]), 200, accuracy: 3, "the copy holds the source's pixels")
        XCTAssertEqual(LiveTextImage.meanLuma(snapshot), LiveTextImage.meanLuma(source), accuracy: 2,
                       "the copy is the same picture")
        XCTAssertNotNil(LiveTextImage.cgImage(snapshot))
    }

    /// A planar 8-bit 4:2:0 frame (what the decoder normally hands the layer)
    /// is copied just the same, and its mean luma reads as the grey it is.
    func testAPlanarFrameIsCopiedAndMeasured() throws {
        let source = try XCTUnwrap(planarBuffer(luma: 128, format: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange))
        XCTAssertEqual(LiveTextImage.pixelFormat(source).isEmpty, false)
        let snapshot = try XCTUnwrap(LiveTextImage.snapshot(source))
        XCTAssertEqual(CVPixelBufferLockBaseAddress(snapshot, .readOnly), kCVReturnSuccess)
        defer { CVPixelBufferUnlockBaseAddress(snapshot, .readOnly) }
        XCTAssertNotNil(CVPixelBufferGetBaseAddress(snapshot))
        XCTAssertGreaterThan(LiveTextImage.meanLuma(source), 40)
        XCTAssertLessThan(LiveTextImage.meanLuma(source), 220)
    }

    func testEntryDiagnosticsNameTheFormatAndTheBlackness() throws {
        let grey = try XCTUnwrap(bgraBuffer(luma: 128))
        XCTAssertEqual(LiveTextImage.pixelFormat(grey), "BGRA")
        XCTAssertEqual(LiveTextImage.meanLuma(grey), 128, accuracy: 2)

        // A frame that arrives blank has mean 0: that is what the log shows.
        let black = try XCTUnwrap(bgraBuffer(luma: 0))
        XCTAssertEqual(LiveTextImage.meanLuma(black), 0, accuracy: 0.5)

        let planar = try XCTUnwrap(planarBuffer(luma: 235, format: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange))
        XCTAssertEqual(LiveTextImage.pixelFormat(planar), "420v")
    }

    /// The frozen frame's PNG and the analyser come from the same picture: the
    /// copy's PNG is the stream's pixel size (the e2e check asserts the size).
    func testTheSnapshotEncodesAtTheFramesPixelSize() throws {
        let source = try XCTUnwrap(bgraBuffer(luma: 90))
        let snapshot = try XCTUnwrap(LiveTextImage.snapshot(source))
        let png = try XCTUnwrap(LiveTextImage.pngData(snapshot))
        XCTAssertGreaterThan(png.count, 64)
        let data = png.prefix(33)
        let width = data[16..<20].reduce(0) { $0 << 8 | Int($1) }
        let height = data[20..<24].reduce(0) { $0 << 8 | Int($1) }
        XCTAssertEqual(width, 320)
        XCTAssertEqual(height, 200)
    }
}
