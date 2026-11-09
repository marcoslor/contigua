// The framed bar's system blur and haze (WIN-40): the extension view's
// backdrop filter is turned up to 15 pt, and a white haze fades over the bar
// band only. The hide rules are the cover's ground, the stall overlay,
// immersive and full screen.

import AppKit
import XCTest
@testable import PocketDeck

@MainActor
final class TopBarHazeTests: XCTestCase {
    private func makeChrome(in appearance: NSAppearance? = NSAppearance(named: .darkAqua),
                            barBlur: BarBlurTuner = BarBlurTuner())
        -> (NSWindow, StreamChromeView) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 628),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = appearance
        let video = VideoLayerView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        // The extension view builds its mirror (and its backdrop) only once
        // the stream it mirrors has a size, as after the first VIDEO_CONFIG.
        video.setVideoSizeForTesting(CGSize(width: 900, height: 600))
        let chrome = StreamChromeView(video: video, style: .framed, barBlur: barBlur)
        chrome.frame = NSRect(x: 0, y: 0, width: 900, height: 628)
        window.contentView = chrome
        window.makeKeyAndOrderFront(nil)
        pump(0.2)
        // The backdrop is built after the stream has a size: the next layout
        // pass is the first one that can see it.
        chrome.needsLayout = true
        chrome.layoutSubtreeIfNeeded()
        return (window, chrome)
    }

    private func pump(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date(timeIntervalSinceNow: seconds))
    }

    /// The filter the system's backdrop uses for its progressive blur.
    private func variableBlur(in root: CALayer?) -> NSObject? {
        guard let root else { return nil }
        if let filters = root.filters as? [NSObject] {
            for filter in filters where (filter.value(forKey: "name") as? String) == "variableBlur" {
                return filter
            }
        }
        for sub in root.sublayers ?? [] {
            if let found = variableBlur(in: sub) { return found }
        }
        return nil
    }

    private func radius(_ filter: NSObject?) -> Double? {
        (filter?.value(forKey: "inputRadius") as? NSNumber)?.doubleValue
    }

    private func barHaze(in root: CALayer?) -> CAGradientLayer? {
        guard let root else { return nil }
        if let gradient = root as? CAGradientLayer,
           let colors = gradient.colors as? [CGColor], colors.count == 2,
           let top = NSColor(cgColor: colors[0])?.usingColorSpace(.sRGB),
           let seam = NSColor(cgColor: colors[1])?.usingColorSpace(.sRGB),
           top.redComponent > 0.99, top.greenComponent > 0.99, top.blueComponent > 0.99,
           seam.alphaComponent == 0 {
            return gradient
        }
        for sub in root.sublayers ?? [] {
            if let found = barHaze(in: sub) { return found }
        }
        return nil
    }

    func testTheSystemBarBlurIsTurnedUpAndSurvivesLayoutAndAppearance() throws {
        let (window, chrome) = makeChrome()
        defer { window.close() }
        let afterFirstLayout = try XCTUnwrap(variableBlur(in: chrome.layer),
                                             "the extension view hosts a variableBlur backdrop")
        XCTAssertEqual(try XCTUnwrap(radius(afterFirstLayout)), 15, accuracy: 0.01,
                       "the bar's system blur is the picked 15 pt, not the system's own 5")

        chrome.layoutSubtreeIfNeeded()
        chrome.layoutChrome()
        XCTAssertEqual(try XCTUnwrap(radius(variableBlur(in: chrome.layer))), 15, accuracy: 0.01,
                       "a forced layout re-applies the radius")

        window.appearance = NSAppearance(named: .aqua)
        pump(0.2)
        chrome.layoutSubtreeIfNeeded()
        XCTAssertEqual(try XCTUnwrap(radius(variableBlur(in: chrome.layer))), 15, accuracy: 0.01,
                       "an appearance change re-applies the radius")
    }

    func testTheHazeSpansTheBarBandWithThePickedAlphasAndHidesOnCovers() throws {
        let (window, chrome) = makeChrome()
        defer { window.close() }
        chrome.layoutChrome()
        var haze = try XCTUnwrap(barHaze(in: chrome.layer), "the bar has a haze layer")
        let band = NSRect(x: 0, y: chrome.bounds.height - ChromeBar.height,
                          width: chrome.bounds.width, height: ChromeBar.height)
        XCTAssertEqual(haze.frame, band, "the haze spans the 28 pt bar and nothing below the seam")
        XCTAssertEqual(haze.startPoint, CGPoint(x: 0.5, y: 1), "white starts at the window's top edge")
        XCTAssertEqual(haze.endPoint, CGPoint(x: 0.5, y: 0), "and clears at the seam")
        let darkTop = try XCTUnwrap((haze.colors as? [CGColor])?.first.flatMap { NSColor(cgColor: $0) }
            .flatMap { $0.usingColorSpace(.sRGB) })
        XCTAssertEqual(darkTop.alphaComponent, 0.14, accuracy: 0.005, "the dark haze's top alpha")

        window.appearance = NSAppearance(named: .aqua)
        pump(0.2)
        chrome.layoutChrome()
        haze = try XCTUnwrap(barHaze(in: chrome.layer))
        let lightTop = try XCTUnwrap((haze.colors as? [CGColor])?.first.flatMap { NSColor(cgColor: $0) }
            .flatMap { $0.usingColorSpace(.sRGB) })
        XCTAssertEqual(lightTop.alphaComponent, 0.30, accuracy: 0.005, "the light haze's top alpha")

        // The opening cover's ground is up: no haze over it.
        chrome.openingCover.show(OpeningCover.display(.opening, name: "Chrome", phone: "Pixel 9",
                                                       phoneMode: false), icon: nil)
        chrome.layoutChrome()
        XCTAssertTrue(haze.isHidden, "the haze is hidden while the opening cover is up")
        chrome.openingCover.show(nil)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.3))
        chrome.layoutChrome()

        // The stall overlay's cover owns the bar.
        chrome.stallOverlay.show(StallOverlayDisplay(kind: .stalled, phone: "Pixel 9"), icon: nil)
        chrome.layoutChrome()
        XCTAssertTrue(haze.isHidden, "the haze is hidden while the stall overlay is up")
        chrome.stallOverlay.hide()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.3))
        chrome.layoutChrome()

        // Immersive has no bar.
        chrome.setStyle(.immersive)
        chrome.layoutChrome()
        XCTAssertTrue(haze.isHidden, "immersive has no bar and no haze")
        chrome.setStyle(.framed)
        chrome.layoutChrome()
        XCTAssertFalse(haze.isHidden, "the haze comes back with the framed bar")
    }

    func testAMissingSystemFilterKeepsTheSystemsOwnRadiusAndSaysSoOnce() throws {
        var facts = 0
        let tuner = BarBlurTuner(lookup: { _ in nil }, logFailure: { facts += 1 })
        let (window, chrome) = makeChrome(barBlur: tuner)
        defer { window.close() }
        let ownRadius = chrome.barBlurRadius
        XCTAssertGreaterThan(ownRadius, 0, "the system's own filter is still there, untouched")
        XCTAssertEqual(facts, 0, "a layout before the first frame is not evidence of a missing filter")
        chrome.layoutChrome()
        chrome.reapplyBarBlur(reportMissing: true)
        window.appearance = NSAppearance(named: .aqua)
        pump(0.2)
        chrome.layoutChrome()
        XCTAssertEqual(chrome.barBlurRadius, ownRadius,
                       "the fallback keeps the system's own radius")
        XCTAssertEqual(facts, 1, "missing is one fact per window, not one per event")
        XCTAssertTrue(chrome.hazeVisible, "the haze still shows with the fallback")
    }
}
