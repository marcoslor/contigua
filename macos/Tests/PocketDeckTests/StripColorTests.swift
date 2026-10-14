// The strip's colour: the average of the frame's top rows, the luminance that
// picks the titlebar's appearance, and the sampler's timer.

import AppKit
import CoreImage
import XCTest
@testable import PocketDeck

final class StripColorTests: XCTestCase {

    // MARK: Luminance and appearance

    func testLuminanceOfBlackWhiteAndGrey() {
        XCTAssertEqual(StripColor(red: 0, green: 0, blue: 0).luminance, 0, accuracy: 1e-9)
        XCTAssertEqual(StripColor(red: 1, green: 1, blue: 1).luminance, 1, accuracy: 1e-9)
        // sRGB 0.5 is about 21 % linear light.
        XCTAssertEqual(StripColor(red: 0.5, green: 0.5, blue: 0.5).luminance, 0.214, accuracy: 0.002)
    }

    func testGreenCountsMoreThanBlue() {
        XCTAssertGreaterThan(StripColor(red: 0, green: 1, blue: 0).luminance, StripColor(red: 1, green: 0, blue: 0).luminance)
        XCTAssertGreaterThan(StripColor(red: 1, green: 0, blue: 0).luminance, StripColor(red: 0, green: 0, blue: 1).luminance)
    }

    func testLightColoursTakeTheLightAppearanceAndDarkOnesTheDark() {
        XCTAssertTrue(StripColor(red: 0.96, green: 0.96, blue: 0.97).prefersLightAppearance(wasLight: nil), "a white settings header")
        XCTAssertFalse(StripColor(red: 0.07, green: 0.07, blue: 0.08).prefersLightAppearance(wasLight: nil), "a dark header")
        XCTAssertFalse(StripColor(red: 0.2, green: 0.4, blue: 0.84).prefersLightAppearance(wasLight: nil), "a saturated blue toolbar reads with white text")
        XCTAssertTrue(StripColor(red: 1, green: 0.85, blue: 0.2).prefersLightAppearance(wasLight: nil), "yellow reads with dark text")
    }

    func testAColourOnTheLineDoesNotFlicker() {
        // Luminance just under and just over the crossover, as an animation or a
        // noisy frame would produce.
        let under = Self.grey(luminance: StripColor.crossover - 0.01)
        let over = Self.grey(luminance: StripColor.crossover + 0.01)
        XCTAssertTrue(under.prefersLightAppearance(wasLight: true), "stays light inside the band")
        XCTAssertFalse(over.prefersLightAppearance(wasLight: false), "stays dark inside the band")
        XCTAssertFalse(Self.grey(luminance: StripColor.crossover - 0.05).prefersLightAppearance(wasLight: true), "leaves light past the band")
        XCTAssertTrue(Self.grey(luminance: StripColor.crossover + 0.05).prefersLightAppearance(wasLight: false), "leaves dark past the band")
    }

    func testOnlyANoticeableChangeIsWorthAnAnimation() {
        let base = StripColor(red: 0.5, green: 0.5, blue: 0.5)
        XCTAssertFalse(StripColor(red: 0.505, green: 0.5, blue: 0.5).isNoticeablyDifferent(from: base))
        XCTAssertTrue(StripColor(red: 0.52, green: 0.5, blue: 0.5).isNoticeablyDifferent(from: base))
        XCTAssertEqual(StripColor.easeDuration, 0.25)
    }

    private static func grey(luminance: Double) -> StripColor {
        // Inverse of the sRGB transfer for a neutral grey.
        let value = luminance <= 0.0031308 ? luminance * 12.92 : 1.055 * pow(luminance, 1 / 2.4) - 0.055
        return StripColor(red: value, green: value, blue: value)
    }

    // MARK: Top rows

    /// A BGRA frame: `top` for the first `topRows` rows, `body` below.
    private func frame(width: Int = 64, height: Int = 48, topRows: Int, top: (UInt8, UInt8, UInt8),
                       body: (UInt8, UInt8, UInt8)) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
        let pixels = try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(pixels, [])
        defer { CVPixelBufferUnlockBaseAddress(pixels, []) }
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(pixels)).assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(pixels)
        for y in 0..<height {
            let colour = y < topRows ? top : body
            for x in 0..<width {
                let p = base + y * stride + x * 4
                p[0] = colour.2; p[1] = colour.1; p[2] = colour.0; p[3] = 255
            }
        }
        return pixels
    }

    func testTheAverageIsOfTheTopRowsOnly() throws {
        let context = CIContext()
        let buffer = try frame(topRows: 8, top: (240, 240, 245), body: (0, 0, 200))
        let colour = try XCTUnwrap(TopEdge.averageColor(of: buffer, using: context))
        XCTAssertEqual(colour.red, 240.0 / 255, accuracy: 0.03)
        XCTAssertEqual(colour.green, 240.0 / 255, accuracy: 0.03)
        XCTAssertEqual(colour.blue, 245.0 / 255, accuracy: 0.03)
        XCTAssertTrue(colour.prefersLightAppearance(wasLight: nil))
    }

    func testTheTopOfTheFrameIsTheTopNotTheBottom() throws {
        // A dark header over a white body, and the reverse: Core Image's origin
        // is bottom-left, so a swapped band would read the other colour.
        let context = CIContext()
        let darkHeader = try frame(topRows: 8, top: (20, 20, 25), body: (250, 250, 250))
        let lightFooter = try XCTUnwrap(TopEdge.averageColor(of: darkHeader, using: context))
        XCTAssertLessThan(lightFooter.luminance, 0.05)
        let lightHeader = try frame(topRows: 8, top: (250, 250, 250), body: (20, 20, 25))
        XCTAssertGreaterThan(try XCTUnwrap(TopEdge.averageColor(of: lightHeader, using: context)).luminance, 0.9)
    }

    func testAColouredHeaderKeepsItsHue() throws {
        let colour = try XCTUnwrap(TopEdge.averageColor(of: frame(topRows: 8, top: (51, 102, 214), body: (240, 240, 240)),
                                                       using: CIContext()))
        XCTAssertEqual(colour.red, 51.0 / 255, accuracy: 0.04)
        XCTAssertEqual(colour.green, 102.0 / 255, accuracy: 0.04)
        XCTAssertEqual(colour.blue, 214.0 / 255, accuracy: 0.04)
    }

    func testAFrameShorterThanTheBandIsAveragedWhole() throws {
        let buffer = try frame(width: 32, height: 4, topRows: 4, top: (255, 0, 0), body: (0, 0, 0))
        let colour = try XCTUnwrap(TopEdge.averageColor(of: buffer, using: CIContext()))
        XCTAssertEqual(colour.red, 1, accuracy: 0.03)
    }

    // MARK: Sampler

    func testTheSamplerReportsTheColourAndStopsWhenAsked() throws {
        let buffer = try frame(topRows: 8, top: (200, 30, 30), body: (0, 0, 0))
        var seen: [StripColor] = []
        var asked = 0
        let sampler = StripColorSampler(source: { asked += 1; return buffer }, onColor: { seen.append($0) })
        XCTAssertFalse(sampler.isRunning)
        sampler.start()
        XCTAssertTrue(sampler.isRunning)
        // The first sample does not wait for the timer; it is averaged off the main thread.
        let firstBy = Date(timeIntervalSinceNow: StripColorSampler.interval * 0.8)
        while seen.isEmpty, Date() < firstBy { RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01)) }
        XCTAssertEqual(seen.count, 1, "the first sample comes before the first tick")
        RunLoop.current.run(until: Date(timeIntervalSinceNow: StripColorSampler.interval * 2.6))
        let whileRunning = asked
        XCTAssertGreaterThanOrEqual(whileRunning, 3)
        XCTAssertLessThanOrEqual(whileRunning, 5, "about four times a second, not per frame")
        sampler.stop()
        XCTAssertFalse(sampler.isRunning)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: StripColorSampler.interval * 2))
        XCTAssertEqual(asked, whileRunning)
        XCTAssertEqual(try XCTUnwrap(seen.last).red, 200.0 / 255, accuracy: 0.04)
    }

    func testNoFrameYetMeansNoColour() {
        var seen = 0
        let sampler = StripColorSampler(source: { nil }, onColor: { _ in seen += 1 })
        sampler.sampleNow()
        XCTAssertEqual(seen, 0)
    }
}
