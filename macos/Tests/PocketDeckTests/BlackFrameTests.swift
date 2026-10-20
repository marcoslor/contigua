// The black-frame fallback for secure surfaces (phone-mirror): Android blanks
// a secure screen with solid black frames, so a full frame of black while the
// screen is on is the phone hiding something. A dark-but-not-black frame (a
// dark app, a dimmed picture) is content and must not count.

import AppKit
import CoreVideo
import XCTest
@testable import PocketDeck

final class BlackFrameTests: XCTestCase {
    /// A tiny BGRA buffer filled with `value` on every channel.
    private func buffer(width: Int = 64, height: Int = 64, value: UInt8) -> CVPixelBuffer {
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
                base[offset] = value     // B
                base[offset + 1] = value // G
                base[offset + 2] = value // R
                base[offset + 3] = 255   // A
            }
        }
        return pixel
    }

    func testASolidBlackFrameIsBlack() {
        XCTAssertTrue(BlackFrame.isBlack(buffer(value: 0)))
        XCTAssertTrue(BlackFrame.isBlack(buffer(value: 3)), "a codec's near-black is still black")
    }

    func testADarkButVisibleFrameIsNotBlack() {
        XCTAssertFalse(BlackFrame.isBlack(buffer(value: 40)), "a dark app is content")
        XCTAssertFalse(BlackFrame.isBlack(buffer(value: 120)))
    }

    func testOneBrightSpeckMakesTheFrameContent() {
        let pixel = buffer(value: 0)
        CVPixelBufferLockBaseAddress(pixel, [])
        let base = CVPixelBufferGetBaseAddress(pixel)!.assumingMemoryBound(to: UInt8.self)
        let rowBytes = CVPixelBufferGetBytesPerRow(pixel)
        let offset = 30 * rowBytes + 30 * 4
        base[offset] = 200
        base[offset + 1] = 200
        base[offset + 2] = 200
        CVPixelBufferUnlockBaseAddress(pixel, [])
        XCTAssertFalse(BlackFrame.isBlack(pixel), "a cursor or a status bar is not a blanked surface")
    }
}
