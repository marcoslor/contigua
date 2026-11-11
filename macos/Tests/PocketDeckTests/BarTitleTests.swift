// The Framed bar's title: its tone machine, its luminance estimate, its pure
// layout, the names each window kind gives it, and the band read off a real
// pixel buffer (WIN-68, WIN-69, MIRROR-26).

import AppKit
import CoreVideo
import XCTest
@testable import PocketDeck

private final class FakeToneSource: BarToneSource {
    var frameStamp: UInt64 = 1
    var range: BandRange?
    private(set) var calls = 0

    func topBandRange(xFrom: CGFloat, xTo: CGFloat, bandFraction: CGFloat,
                      completion: @escaping (BandRange?) -> Void) {
        calls += 1
        completion(range)
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
        XCTAssertEqual(machine.handle(.sample(BandRange(low: 0.02, high: 0.03))), .baseline(.light),
                       "the first dark-band sample appears light")
        XCTAssertTrue(machine.hasSample)
        XCTAssertEqual(machine.handle(.sample(BandRange(low: 0.179, high: 0.182))), .ignored,
                       "inside the hysteresis band the light tone stays")
        XCTAssertEqual(machine.handle(.sample(BandRange(low: 0.179, high: 0.18333))), .ignored,
                       "at toDark white ink still passes, so the light tone stays")
        XCTAssertEqual(machine.handle(.sample(BandRange(low: 0.19, high: 0.3))), .changed(.dark),
                       "above toDark white ink can no longer pass")
        XCTAssertEqual(machine.handle(.sample(BandRange(low: 0.18, high: 0.183))), .ignored,
                       "inside the hysteresis band the dark tone stays")
        XCTAssertEqual(machine.handle(.sample(BandRange(low: 0.176, high: 0.18))), .ignored,
                       "both inks pass, so the dark tone stays")
        XCTAssertEqual(machine.handle(.sample(BandRange(low: 0.01, high: 0.1))), .changed(.light),
                       "below toLight black ink can no longer pass")
        XCTAssertEqual(machine.handle(.sample(BandRange(low: 0.02, high: 0.03))), .ignored,
                       "the light tone stays on a dark band")
        XCTAssertEqual(machine.handle(.sample(BandRange(low: 0.1, high: 0.5))), .unresolved(.light),
                       "neither ink reaches the limit: the tone is kept and said once")
        XCTAssertEqual(machine.tone, .light)
    }

    func testTheFirstSampleDecidesEitherToneAndNonFiniteIsIgnored() {
        var light = BarToneMachine()
        XCTAssertEqual(light.handle(.sample(BandRange(low: .nan, high: 0.1))), .ignored,
                       "a non-finite sample decides nothing")
        XCTAssertFalse(light.hasSample)
        XCTAssertEqual(light.handle(.sample(BandRange(low: 0.02, high: 0.03))), .baseline(.light))
        XCTAssertEqual(light.tone, .light)

        var dark = BarToneMachine()
        XCTAssertEqual(dark.handle(.sample(BandRange(low: 0.8, high: 0.95))), .baseline(.dark))
        XCTAssertEqual(dark.tone, .dark)

        var both = BarToneMachine()
        let change = both.handle(.sample(BandRange(low: 0.176, high: 0.182)))
        XCTAssertEqual(change, .baseline(both.tone),
                       "a band that both inks pass takes one tone and stays")
        XCTAssertTrue([.light, .dark].contains(both.tone))

        var neither = BarToneMachine()
        XCTAssertEqual(neither.handle(.sample(BandRange(low: 0.1, high: 0.5))),
                       .unresolved(neither.tone))
        XCTAssertTrue(neither.hasSample)
    }

    func testTheMachineKeepsTheToneInTheHysteresisBand() {
        var light = BarToneMachine()
        _ = light.handle(.sample(BandRange(low: 0.01, high: 0.02)))
        XCTAssertEqual(light.tone, .light)
        for low in stride(from: 0.175, through: 0.1833, by: 0.001) {
            XCTAssertEqual(light.handle(.sample(BandRange(low: low, high: low))), .ignored)
            XCTAssertEqual(light.tone, .light, "light holds at \(low)")
        }

        var dark = BarToneMachine()
        _ = dark.handle(.sample(BandRange(low: 0.8, high: 0.9)))
        XCTAssertEqual(dark.tone, .dark)
        for high in stride(from: 0.1833, through: 0.175, by: -0.001) {
            XCTAssertEqual(dark.handle(.sample(BandRange(low: high, high: high))), .ignored)
            XCTAssertEqual(dark.tone, .dark, "dark holds at \(high)")
        }
    }

    func testTheBandEstimateIncludesTheTintAndTheHazeInSRGB() {
        // One uniform band, top and bottom haze equal: `.low` is the value.
        func estimate(_ frame: Double, tint: Double = 1.0,
                      tintAlpha: CGFloat = 0, haze: Double = 0) -> Double {
            BarToneEstimate.blend(frame: BandRange(low: frame, high: frame),
                                  tintLuminance: tint, tintAlpha: tintAlpha,
                                  hazeTop: haze, hazeBottom: haze).low
        }
        let frame = 0.02
        let tint = 1.0
        let noTint = estimate(frame)
        XCTAssertEqual(noTint, frame, accuracy: 0.0001)
        let tinted = estimate(frame, tintAlpha: BarTitle.tintAlpha)
        let encode = BarToneEstimate.encode(frame)
        XCTAssertEqual(tinted, BarToneEstimate.decode(encode * 0.86 + 1 * 0.14), accuracy: 0.0001,
                       "the white tint lifts a dark frame in sRGB, not linear")
        let hazed = estimate(frame, tintAlpha: BarTitle.tintAlpha, haze: 0.15)
        XCTAssertGreaterThan(hazed, tinted)

        let range = BarToneEstimate.blend(frame: BandRange(low: 0.02, high: 0.4),
                                          tintLuminance: tint,
                                          hazeTop: 0.15, hazeBottom: 0.05)
        XCTAssertLessThan(range.low, range.high)
        XCTAssertLessThan(range.low, BarToneEstimate.blend(
            frame: BandRange(low: 0.02, high: 0.02), tintLuminance: tint,
            hazeTop: 0.15, hazeBottom: 0.05).high,
            "the bottom line sees less haze than the top")
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
        XCTAssertEqual(frame.midX, windowWidth / 2, accuracy: 0.01,
                       "the title is centred on the bar's own line")
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
        XCTAssertEqual(BarTitle.lineBreakMode(text: long, width: frame.width), .byTruncatingMiddle)
    }

    func testTheFieldOnlyTruncatesWhenTheNameDoesNotFit() {
        let name = "Settings"
        XCTAssertEqual(BarTitle.lineBreakMode(text: name, width: BarTitle.textWidth(name)),
                       .byClipping,
                       "a full line is drawn whole; the cell reserves the ellipsis otherwise")
        XCTAssertEqual(BarTitle.lineBreakMode(text: name, width: BarTitle.textWidth(name) - 1),
                       .byTruncatingMiddle,
                       "one point short and the middle truncation takes over")
        XCTAssertEqual(BarTitle.lineBreakMode(text: nil, width: 100), .byTruncatingMiddle)
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
        let long = "A Phone With A Long Display Name"
        XCTAssertNil(BarTitle.frame(text: long, windowWidth: 900, barHeight: barHeight,
                                    boundsHeight: 628, lightsEnd: 100,
                                    rightRowStart: 100 + 2 * BarTitle.sideGap
                                        + BarTitle.minimumTruncatedWidth - 1),
                     "[WIN-68] a name that would truncate to a few letters hides instead")
        XCTAssertNotNil(BarTitle.frame(text: long, windowWidth: 900, barHeight: barHeight,
                                       boundsHeight: 628, lightsEnd: 100,
                                       rightRowStart: 100 + 2 * BarTitle.sideGap
                                        + BarTitle.minimumTruncatedWidth))
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
        let chrome = StreamChromeView(video: video, style: .immersive, toneSource: tone,
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
        tone.range = BandRange(low: 0.8, high: 0.9)
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
        XCTAssertEqual(chrome.barTitleLineBreakMode, .byClipping,
                       "the whole name fits, so the field must not reserve an ellipsis")

        tone.range = BandRange(low: 0.02, high: 0.03)
        tone.frameStamp += 1
        chrome.sampleBarToneForTesting()
        XCTAssertEqual(chrome.barTitleToneName, BarTone.light.rawValue,
                       "a dark band gets white ink")
        XCTAssertEqual(chrome.barTitleAlpha(.light), 1, accuracy: 0.01)
        XCTAssertEqual(chrome.barTitleAlpha(.dark), 0, accuracy: 0.01)
    }

    func testReduceMotionChangesTheToneAtOnce() throws {
        let tone = FakeToneSource()
        tone.range = BandRange(low: 0.8, high: 0.9)
        let (window, chrome) = makeChrome(tone: tone, reduceMotion: { true })
        defer { window.close() }
        chrome.setBarTitle("Maps")
        chrome.layoutChrome()
        XCTAssertEqual(chrome.barTitleToneName, BarTone.dark.rawValue)
        tone.range = BandRange(low: 0.02, high: 0.03)
        tone.frameStamp += 1
        chrome.sampleBarToneForTesting()
        XCTAssertEqual(chrome.barTitleToneName, BarTone.light.rawValue)
        XCTAssertEqual(chrome.barTitleAlpha(.light), 1, accuracy: 0.01,
                       "Reduce Motion swaps the ink with no fade")
        XCTAssertEqual(chrome.barTitleAlpha(.dark), 0, accuracy: 0.01)
    }

    func testTheTitleHidesForEveryCoverAndComesBack() {
        let tone = FakeToneSource()
        tone.range = BandRange(low: 0.8, high: 0.9)
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

        chrome.setStyle(.framed)
        chrome.layoutChrome()
        XCTAssertTrue(chrome.barTitleVisible, "Framed has its title on the frame")
        chrome.setStyle(.immersive)
        chrome.layoutChrome()
        XCTAssertTrue(chrome.barTitleVisible, "Immersive has its title on the bar too")

        chrome.setBarTitle(nil)
        chrome.layoutChrome()
        XCTAssertFalse(chrome.barTitleVisible, "a window with no name has no title")
    }

    func testTheTitleHidesBelowItsMinimumWidth() {
        let tone = FakeToneSource()
        tone.range = BandRange(low: 0.8, high: 0.9)
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

    func testTheFieldTruncatesAMiddleThatDoesNotFitAndClipsOneThatDoes() {
        let tone = FakeToneSource()
        tone.range = BandRange(low: 0.8, high: 0.9)
        let (window, chrome) = makeChrome(tone: tone)
        defer { window.close() }
        chrome.setBarTitle("Settings")
        chrome.layoutChrome()
        XCTAssertTrue(chrome.barTitleVisible)
        XCTAssertEqual(chrome.barTitleLineBreakMode, .byClipping,
                       "a name that fits is drawn whole")
        chrome.setBarTitle(String(repeating: "A very long app name ", count: 8))
        chrome.layoutChrome()
        XCTAssertTrue(chrome.barTitleVisible)
        XCTAssertEqual(chrome.barTitleLineBreakMode, .byTruncatingMiddle,
                       "a name wider than the bar truncates in the middle")
    }
}
