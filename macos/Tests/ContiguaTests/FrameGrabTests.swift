// FrameGrab: the screenshot encoder (docs/design/mcp.md) — scaled to 1280 px,
// PNG, real pixels.

import CoreVideo
import XCTest
@testable import Contigua

final class FrameGrabTests: XCTestCase {

    private func makePixelBuffer(width: Int, height: Int) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
        ]
        let status = CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA,
                                         attributes as CFDictionary, &buffer)
        XCTAssertEqual(status, kCVReturnSuccess)
        let pixels = try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(pixels, [])
        defer { CVPixelBufferUnlockBaseAddress(pixels, []) }
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(pixels))
        let rowBytes = CVPixelBufferGetBytesPerRow(pixels)
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        for y in 0..<height {
            for x in 0..<width {
                let offset = y * rowBytes + x * 4
                let value = UInt8((x * 255) / max(1, width - 1))
                bytes[offset] = value        // B
                bytes[offset + 1] = value    // G
                bytes[offset + 2] = value    // R
                bytes[offset + 3] = 255      // A
            }
        }
        return pixels
    }

    func testPngIsAScaledImage() throws {
        let pixels = try makePixelBuffer(width: 1600, height: 900)
        let png = try XCTUnwrap(FrameGrab.png(from: pixels))
        XCTAssertEqual(Array(png.prefix(8)), [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])
        let image = try XCTUnwrap(NSBitmapImageRep(data: png))
        XCTAssertEqual(image.pixelsWide, 1280)
        XCTAssertEqual(image.pixelsHigh, 720)
    }

    func testSmallFramesKeepTheirSize() throws {
        let pixels = try makePixelBuffer(width: 640, height: 360)
        let png = try XCTUnwrap(FrameGrab.png(from: pixels))
        let image = try XCTUnwrap(NSBitmapImageRep(data: png))
        XCTAssertEqual(image.pixelsWide, 640)
        XCTAssertEqual(image.pixelsHigh, 360)
    }
}
