// The Framed bar's title: its tone machine, its luminance estimate, its pure
// layout, the names each window kind gives it, and the band read off a real
// pixel buffer (WIN-68, WIN-69, MIRROR-23).

import AppKit
import CoreVideo
import XCTest
@testable import PocketDeck

private final class FakeToneSource: BarToneSource {
    var frameStamp: UInt64 = 1
    var luminance: Double?
    private(set) var calls = 0

    func topBandLuminance(xFrom: CGFloat, xTo: CGFloat, bandFraction: CGFloat,
                          completion: @escaping (Double?) -> Void) {
        calls += 1
        completion(luminance)
    }
}

final class BarTitleToneTests: XCTestCase {
    func testTheTwoThresholdsComeFromTheNFRContrastLimit() {
        let limit = NFRTestLimits.shared.double("bar_title_contrast_min")
        XCTAssertEqual(BarTitle.minimumContrast, limit, accuracy: 0.0001,
                       "the app's limit and nfr-limits.json are the same number")
        let thresholds = BarToneThresholds.standard
        XCTAssertEqual(thresholds.toDark, 0.18333, accuracy: 0.0001,
                       "white ink first reaches 4.5:1 at this band luminance")
        XCTAssertEqual(thresholds.toLight, 0.175, accuracy: 0.0001,
                       "black ink first reaches 4.5:1 at this band luminance")
        XCTAssertGreaterThan(thresholds.toDark, thresholds.toLight,
                             "the hysteresis interval is between them")
        for luminance in [thresholds.toLight, (thresholds.toLight + thresholds.toDark) / 2,
                          thresholds.toDark] {
            XCTAssertGreaterThanOrEqual(BarTone.contrast(.light, over: luminance), limit - 1e-9,
                                        "white ink at \(luminance)")
            XCTAssertGreaterThanOrEqual(BarTone.contrast(.dark, over: luminance), limit - 1e-9,
                                        "black ink at \(luminance)")
        }
    }

    func testTheLuminanceToToneMappingPicksTheReadableInk() {
        for luminance in [0.0, 0.05, 0.1] {
            XCTAssertEqual(BarTone.preferred(for: luminance), .light, "dark band \(luminance)")
        }
        for luminance in [0.5, 0.8, 0.9, 1.0] {
            XCTAssertEqual(BarTone.preferred(for: luminance), .dark, "light band \(luminance)")
        }
        XCTAssertEqual(BarTone.preferred(for: 0.20), .dark, "above the crossover black wins")
        XCTAssertEqual(BarTone.preferred(for: 0.17), .light, "below the crossover white wins")
    }

    func testEveryToneTransitionAndIgnoredSample() {
        var machine = BarToneMachine()
        XCTAssertEqual(machine.handle(.sample(0.05)), .baseline(.light),
                       "the first dark-band sample appears light")
        XCTAssertTrue(machine.hasSample)
        XCTAssertEqual(machine.handle(.sample(0.18)), .ignored,
                       "inside the band the light tone stays")
        XCTAssertEqual(machine.handle(.sample(0.17)), .ignored,
                       "at toLight the light tone still stays (it only leaves above it)")
        XCTAssertEqual(machine.handle(.sample(0.19)), .changed(.dark),
                       "above toDark white ink can no longer pass")
        XCTAssertEqual(machine.handle(.sample(0.18)), .ignored,
                       "inside the band the dark tone stays")
        XCTAssertEqual(machine.handle(.sample(0.18333)), .ignored,
                       "exactly at toDark the dark tone stays")
        XCTAssertEqual(machine.handle(.sample(0.175)), .changed(.light),
                       "at toLight black ink can still pass, but the dark tone only leaves at or below it")
    }

    func testTheFirstSampleDecidesEitherToneAndNonFiniteIsIgnored() {
        var light = BarToneMachine()
        XCTAssertEqual(light.handle(.sample(.nan)), .ignored, "a non-finite sample decides nothing")
        XCTAssertFalse(light.hasSample)
        XCTAssertEqual(light.handle(.sample(0.02)), .baseline(.light))
        XCTAssertEqual(light.tone, .light)

        var dark = BarToneMachine()
        XCTAssertEqual(dark.handle(.sample(0.95)), .baseline(.dark))
        XCTAssertEqual(dark.tone, .dark)
    }

    func testTheMachineHasOnlyTheTwoStatesAndKeepsTheToneInTheBand() {
        var machine = BarToneMachine()
        _ = machine.handle(.sample(0.01))
        XCTAssertEqual(machine.tone, .light)
        for luminance in stride(from: 0.1751, through: 0.1832, by: 0.001) {
            XCTAssertEqual(machine.handle(.sample(luminance)), .ignored)
            XCTAssertEqual(machine.tone, .light, "light holds at \(luminance)")
        }
        _ = machine.handle(.sample(0.5))
        XCTAssertEqual(machine.tone, .dark)
        for luminance in stride(from: 0.1832, through: 0.1751, by: -0.001) {
            XCTAssertEqual(machine.handle(.sample(luminance)), .ignored)
            XCTAssertEqual(machine.tone, .dark, "dark holds at \(luminance)")
        }
    }

    func testTheBandEstimateIncludesTheTintAndTheHaze() {
        let frame = 0.02
        let tint = 0.84
        let noTint = BarToneEstimate.band(frameLuminance: frame, tintLuminance: tint,
                                          tintAlpha: 0, hazeAtTitle: 0)
        XCTAssertEqual(noTint, frame, accuracy: 0.0001)
        let tinted = BarToneEstimate.band(frameLuminance: frame, tintLuminance: tint,
                                          tintAlpha: BarTitle.tintAlpha, hazeAtTitle: 0)
        XCTAssertEqual(tinted, frame * 0.86 + tint * 0.14, accuracy: 0.0001,
                       "the 14 % window background lifts a dark frame")
        let hazed = BarToneEstimate.band(frameLuminance: frame, tintLuminance: tint,
                                         tintAlpha: BarTitle.tintAlpha,
                                         hazeAtTitle: 0.15)
        XCTAssertEqual(hazed, tinted * 0.85 + 0.15, accuracy: 0.0001,
                       "the white haze lifts it again at the title's line")
        XCTAssertGreaterThan(hazed, tinted)
    }
}

final class BarTitleLayoutTests: XCTestCase {
    private let windowWidth: CGFloat = 900
    private let barHeight = ChromeBar.height
    private let rowStart: CGFloat = 763  // 900 - 7 - (3*32 + 6 + 28)

    func testTheTitleIsCentredBetweenTheLightsAndTheRow() throws {
        let text = "Quarterly notes"
        let frame = try XCTUnwrap(BarTitle.frame(text: text, windowWidth: windowWidth,
                                                barHeight: barHeight, boundsHeight: 628,
                                                lightsEnd: BarTitle.lightsEnd,
                                                rightRowStart: rowStart))
        XCTAssertEqual(frame.minX, BarTitle.lightsEnd + BarTitle.sideGap
                       + (rowStart - BarTitle.sideGap - (BarTitle.lightsEnd + BarTitle.sideGap) - frame.width) / 2,
                       accuracy: 0.01)
        XCTAssertEqual(frame.midX, (BarTitle.lightsEnd + rowStart) / 2, accuracy: 0.01,
                       "the title's centre is the bar's centre, not the room's")
        XCTAssertGreaterThanOrEqual(frame.minX, BarTitle.lightsEnd + BarTitle.sideGap)
        XCTAssertLessThanOrEqual(frame.maxX, rowStart - BarTitle.sideGap)
        XCTAssertEqual(frame.width, BarTitle.textWidth(text), accuracy: 0.5)
        XCTAssertEqual(frame.minY, 628 - barHeight + (barHeight - frame.height) / 2, accuracy: 0.01,
                       "centred on the bar's line")
    }

    func testTheTitleYieldsWidthToTheControlsAndTruncates() throws {
        let long = String(repeating: "A very long app name ", count: 8)
        let narrowRow: CGFloat = 320
        let frame = try XCTUnwrap(BarTitle.frame(text: long, windowWidth: 900,
                                                barHeight: barHeight, boundsHeight: 628,
                                                lightsEnd: BarTitle.lightsEnd,
                                                rightRowStart: narrowRow))
        XCTAssertEqual(frame.maxX, narrowRow - BarTitle.sideGap, accuracy: 0.01)
        XCTAssertGreaterThan(BarTitle.textWidth(long), frame.width,
                             "the field truncates in the middle at this width")
    }

    func testTheTitleHidesBelowItsMinimumWidth() {
        XCTAssertNil(BarTitle.frame(text: "Maps", windowWidth: 900, barHeight: barHeight,
                                    boundsHeight: 628, lightsEnd: 100,
                                    rightRowStart: 100 + 2 * BarTitle.sideGap
                                        + BarTitle.minimumWidth - 1),
                     "one point too narrow")
        XCTAssertNotNil(BarTitle.frame(text: "Maps", windowWidth: 900, barHeight: barHeight,
                                       boundsHeight: 628, lightsEnd: 100,
                                       rightRowStart: 100 + 2 * BarTitle.sideGap
                                        + BarTitle.minimumWidth))
        XCTAssertNil(BarTitle.frame(text: "", windowWidth: 900, barHeight: barHeight,
                                    boundsHeight: 628, lightsEnd: 0, rightRowStart: 900),
                     "no name, no title")
        XCTAssertNil(BarTitle.frame(text: "Maps", windowWidth: 900, barHeight: 0,
                                    boundsHeight: 628, lightsEnd: 0, rightRowStart: 900),
                     "no bar, no title")
    }

    func testTheNamesAreOnlyNames() {
        XCTAssertEqual(BarTitleName.app("  Maps "), "Maps")
        XCTAssertNil(BarTitleName.app("   "))
        XCTAssertNil(BarTitleName.app(nil))
        XCTAssertEqual(BarTitleName.phone(displayName: "Pixel 9 (Kitchen)", fallback: "Pixel 9"),
                       "Pixel 9 (Kitchen)")
        XCTAssertEqual(BarTitleName.phone(displayName: "  ", fallback: "Pixel 9"), "Pixel 9")
        XCTAssertNil(BarTitleName.phone(displayName: "", fallback: nil))
        XCTAssertEqual(BarTitleName.adoptedApp("Maps"), "Maps")
        XCTAssertNil(BarTitleName.adoptedApp(nil), "a link before its app is known has no title")
        XCTAssertNil(BarTitleName.adoptedApp("  "))
    }
}

final class BarTitleBandLuminanceTests: XCTestCase {
    private func bgra(width: Int, height: Int, top: UInt8, bottom: UInt8) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                         kCVPixelFormatType_32BGRA, nil, &buffer)
        let made = try XCTUnwrap(buffer)
        XCTAssertEqual(status, kCVReturnSuccess)
        CVPixelBufferLockBaseAddress(made, [])
        defer { CVPixelBufferUnlockBaseAddress(made, []) }
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(made))
        let stride = CVPixelBufferGetBytesPerRow(made)
        for y in 0..<height {
            let value = y < height / 2 ? top : bottom
            for x in 0..<width {
                let offset = y * stride + x * 4
                base.storeBytes(of: value, toByteOffset: offset, as: UInt8.self)
                base.storeBytes(of: value, toByteOffset: offset + 1, as: UInt8.self)
                base.storeBytes(of: value, toByteOffset: offset + 2, as: UInt8.self)
                base.storeBytes(of: 255, toByteOffset: offset + 3, as: UInt8.self)
            }
        }
        return made
    }

    func testABGRAFrameReadsTheTopBandAndNotTheBottom() throws {
        let buffer = try bgra(width: 64, height: 32, top: 255, bottom: 0)
        let top = try XCTUnwrap(BandLuminance.mean(of: buffer, rect: CGRect(x: 0, y: 0, width: 64, height: 16)))
        let bottom = try XCTUnwrap(BandLuminance.mean(of: buffer, rect: CGRect(x: 0, y: 16, width: 64, height: 16)))
        XCTAssertEqual(top, 1.0, accuracy: 0.01)
        XCTAssertEqual(bottom, 0.0, accuracy: 0.01)
    }

    func testACoreImageRegionReadsTheTopOfTheFrame() throws {
        // The lossless formats a display layer hands back are read through
        // Core Image; this is the same call on a frame whose top is known.
        let buffer = try bgra(width: 64, height: 32, top: 255, bottom: 0)
        let top = try XCTUnwrap(BandLuminance.meanThroughCoreImage(
            of: buffer, rect: CGRect(x: 8, y: 0, width: 32, height: 12)))
        let bottom = try XCTUnwrap(BandLuminance.meanThroughCoreImage(
            of: buffer, rect: CGRect(x: 8, y: 20, width: 32, height: 12)))
        XCTAssertEqual(top, 1.0, accuracy: 0.01, "the top band is white")
        XCTAssertEqual(bottom, 0.0, accuracy: 0.01, "the bottom band is black")
    }

    func testABiPlanarFrameReadsItsLumaPlaneTopDown() throws {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, 64, 32,
                                         kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                                         nil, &buffer)
        let made = try XCTUnwrap(buffer)
        XCTAssertEqual(status, kCVReturnSuccess)
        CVPixelBufferLockBaseAddress(made, [])
        defer { CVPixelBufferUnlockBaseAddress(made, []) }
        let luma = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(made, 0))
        let stride = CVPixelBufferGetBytesPerRowOfPlane(made, 0)
        for y in 0..<32 {
            let value: UInt8 = y < 16 ? 255 : 0
            for x in 0..<64 { luma.storeBytes(of: value, toByteOffset: y * stride + x, as: UInt8.self) }
        }
        let top = try XCTUnwrap(BandLuminance.mean(of: made, rect: CGRect(x: 0, y: 0, width: 64, height: 16)))
        let bottom = try XCTUnwrap(BandLuminance.mean(of: made, rect: CGRect(x: 0, y: 16, width: 64, height: 16)))
        XCTAssertEqual(top, 1.0, accuracy: 0.02, "full-range white is full white")
        XCTAssertEqual(bottom, 0.0, accuracy: 0.02, "full-range black is full black")
    }

    func testAnUnreadableFormatIsAMeasurementNotACrash() throws {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 16, 16,
                            kCVPixelFormatType_32ARGB, nil, &buffer)
        let made = try XCTUnwrap(buffer)
        XCTAssertNil(BandLuminance.mean(of: made, rect: CGRect(x: 0, y: 0, width: 16, height: 16)))
        XCTAssertNil(BandLuminance.mean(of: made, rect: .zero))
    }
}

@MainActor
final class BarTitleViewTests: XCTestCase {
    private func makeChrome(tone: FakeToneSource,
                            reduceMotion: @escaping () -> Bool = { false })
        -> (NSWindow, StreamChromeView) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 628),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        let video = VideoLayerView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        video.setVideoSizeForTesting(CGSize(width: 900, height: 600))
        let chrome = StreamChromeView(video: video, style: .framed, toneSource: tone,
                                      reduceMotion: reduceMotion)
        chrome.frame = NSRect(x: 0, y: 0, width: 900, height: 628)
        window.contentView = chrome
        window.makeKeyAndOrderFront(nil)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
        chrome.layoutSubtreeIfNeeded()
        return (window, chrome)
    }

    func testTheTitleAppearsInTheBandsOwnToneAndFollowsIt() throws {
        let tone = FakeToneSource()
        tone.luminance = 0.9
        let (window, chrome) = makeChrome(tone: tone)
        defer { window.close() }
        chrome.setBarTitle("Quarterly notes")
        chrome.layoutChrome()
        XCTAssertTrue(chrome.barTitleVisible)
        XCTAssertEqual(chrome.barTitleToneName, BarTone.dark.rawValue,
                       "a bright band gets black ink")
        let frame = try XCTUnwrap(chrome.barTitleRect)
        XCTAssertGreaterThanOrEqual(frame.minX, BarTitle.lightsEnd + BarTitle.sideGap)
        XCTAssertLessThanOrEqual(frame.maxX, 900 - 7 - 28 - BarTitle.sideGap,
                                 "the title keeps clear of the Live Text capsule")
        XCTAssertEqual(chrome.barTitleLineBreakMode, .byTruncatingMiddle)

        tone.luminance = 0.01
        tone.frameStamp += 1
        chrome.sampleBarToneForTesting()
        XCTAssertEqual(chrome.barTitleToneName, BarTone.light.rawValue,
                       "a dark band gets white ink")
        XCTAssertEqual(chrome.barTitleAlpha(.light), 1, accuracy: 0.01)
        XCTAssertEqual(chrome.barTitleAlpha(.dark), 0, accuracy: 0.01)
    }

    func testReduceMotionChangesTheToneAtOnce() throws {
        let tone = FakeToneSource()
        tone.luminance = 0.9
        let (window, chrome) = makeChrome(tone: tone, reduceMotion: { true })
        defer { window.close() }
        chrome.setBarTitle("Maps")
        chrome.layoutChrome()
        XCTAssertEqual(chrome.barTitleToneName, BarTone.dark.rawValue)
        tone.luminance = 0.01
        tone.frameStamp += 1
        chrome.sampleBarToneForTesting()
        XCTAssertEqual(chrome.barTitleToneName, BarTone.light.rawValue)
        XCTAssertEqual(chrome.barTitleAlpha(.light), 1, accuracy: 0.01,
                       "Reduce Motion swaps the ink with no fade")
        XCTAssertEqual(chrome.barTitleAlpha(.dark), 0, accuracy: 0.01)
    }

    func testTheTitleHidesForEveryCoverAndStyleAndComesBack() {
        let tone = FakeToneSource()
        tone.luminance = 0.9
        let (window, chrome) = makeChrome(tone: tone)
        defer { window.close() }
        chrome.setBarTitle("Maps")
        chrome.layoutChrome()
        XCTAssertTrue(chrome.barTitleVisible)

        chrome.phoneOverlay.show(.screenOff)
        chrome.layoutChrome()
        XCTAssertFalse(chrome.barTitleVisible, "the phone cover owns the bar")
        chrome.phoneOverlay.show(nil as PhoneCover?)
        chrome.layoutChrome()
        XCTAssertTrue(chrome.barTitleVisible)

        chrome.setStyle(.immersive)
        chrome.layoutChrome()
        XCTAssertFalse(chrome.barTitleVisible, "immersive has no bar")
        chrome.setStyle(.framed)
        chrome.layoutChrome()
        XCTAssertTrue(chrome.barTitleVisible, "the title comes back with the bar")

        chrome.setBarTitle(nil)
        chrome.layoutChrome()
        XCTAssertFalse(chrome.barTitleVisible, "a window with no name has no title")
    }

    func testTheTitleHidesBelowItsMinimumWidth() {
        let tone = FakeToneSource()
        tone.luminance = 0.9
        let (window, chrome) = makeChrome(tone: tone)
        defer { window.close() }
        chrome.setBarTitle("Maps")
        chrome.layoutChrome()
        XCTAssertTrue(chrome.barTitleVisible)
        chrome.frame = NSRect(x: 0, y: 0,
                              width: BarTitle.lightsEnd + 2 * BarTitle.sideGap
                                  + BarTitle.minimumWidth - 1 + 7 + 28,
                              height: 628)
        chrome.layoutChrome()
        XCTAssertFalse(chrome.barTitleVisible, "one point under the minimum hides the title")
    }
}
