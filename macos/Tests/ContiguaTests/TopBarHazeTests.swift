// The Compact bar's system blur, tint and haze (WIN-40, WIN-67): the
// extension view's backdrop filter is turned up to 30 pt, a 14 % tint and a
// white haze fade over the bar band only. The hide rules are the cover's
// ground, the stall overlay, compact and full screen.

import AppKit
import XCTest
@testable import Contigua

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
        let chrome = StreamChromeView(video: video, style: .compact, barBlur: barBlur)
        chrome.frame = NSRect(x: 0, y: 0, width: 900, height: 628)
        window.contentView = chrome
        window.makeKeyAndOrderFront(nil)
        // The extension view builds its backdrop in a pass of its own; the
        // radius follows that pass (testTheRadiusIsSetWhen…), nothing forced.
        pump(0.2)
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

    /// The 14 % window-background tint: a solid fill over the bar band.
    private func barTint(in root: CALayer?) -> CALayer? {
        guard let root else { return nil }
        if let colour = root.backgroundColor.flatMap({ NSColor(cgColor: $0) })?.usingColorSpace(.sRGB),
           abs(colour.alphaComponent - 0.14) < 0.005,
           root.frame.height == ChromeBar.height, root.frame.width == 900 {
            return root
        }
        for sub in root.sublayers ?? [] {
            if let found = barTint(in: sub) { return found }
        }
        return nil
    }

    func testTheSystemBarBlurIsTurnedUpAndSurvivesLayoutAndAppearance() throws {
        let (window, chrome) = makeChrome()
        defer { window.close() }
        let afterFirstLayout = try XCTUnwrap(variableBlur(in: chrome.layer),
                                             "the extension view hosts a variableBlur backdrop")
        XCTAssertEqual(try XCTUnwrap(radius(afterFirstLayout)), 30, accuracy: 0.01,
                       "the bar's system blur is the picked 30 pt, not the system's own 5")

        chrome.layoutSubtreeIfNeeded()
        chrome.layoutChrome()
        XCTAssertEqual(try XCTUnwrap(radius(variableBlur(in: chrome.layer))), 30, accuracy: 0.01,
                       "a forced layout re-applies the radius")

        window.appearance = NSAppearance(named: .aqua)
        pump(0.2)
        chrome.layoutSubtreeIfNeeded()
        XCTAssertEqual(try XCTUnwrap(radius(variableBlur(in: chrome.layer))), 30, accuracy: 0.01,
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

        // Framed has no mirrored bar.
        chrome.setStyle(.framed)
        chrome.layoutChrome()
        XCTAssertTrue(haze.isHidden, "Framed has no mirror and no haze")
        chrome.setStyle(.compact)
        chrome.layoutChrome()
        XCTAssertFalse(haze.isHidden, "the haze comes back with the Compact bar")
    }

    func testTheTintSpansTheBarBandAndHidesWithTheHaze() throws {
        let (window, chrome) = makeChrome()
        defer { window.close() }
        chrome.layoutChrome()
        let tint = try XCTUnwrap(barTint(in: chrome.layer), "the bar has its 14 % tint")
        XCTAssertEqual(tint.frame, NSRect(x: 0, y: chrome.bounds.height - ChromeBar.height,
                                          width: chrome.bounds.width, height: ChromeBar.height),
                       "the tint spans the 28 pt bar and nothing below the seam")
        XCTAssertGreaterThan(tint.zPosition, 0.5, "the tint sits above the haze")
        XCTAssertTrue(chrome.barTintVisible, "the tint shows with the Compact bar")

        chrome.openingCover.show(OpeningCover.display(.opening, name: "Chrome", phone: "Pixel 9",
                                                       phoneMode: false), icon: nil)
        chrome.layoutChrome()
        XCTAssertFalse(chrome.barTintVisible, "the opening cover's ground takes the tint with the haze")
        chrome.openingCover.show(nil)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.3))
        chrome.layoutChrome()

        chrome.stallOverlay.show(StallOverlayDisplay(kind: .stalled, phone: "Pixel 9"), icon: nil)
        chrome.layoutChrome()
        XCTAssertFalse(chrome.barTintVisible, "the stall overlay owns the bar")
        chrome.stallOverlay.hide()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.3))
        chrome.layoutChrome()

        chrome.setStyle(.framed)
        chrome.layoutChrome()
        XCTAssertFalse(chrome.barTintVisible, "Framed has no mirror and no tint")
        chrome.setStyle(.compact)
        chrome.layoutChrome()
        XCTAssertTrue(chrome.barTintVisible, "the tint comes back with the Compact bar")
    }

    func testAMissingSystemFilterKeepsTheSystemsOwnRadiusAndSaysSoOnceAtClose() throws {
        var facts: [String] = []
        let tuner = BarBlurTuner(lookup: { _ in nil }, diagnosis: { _ in "backdrops=1 filters=[x]" },
                                 logFailure: { facts.append($0) })
        let (window, chrome) = makeChrome(barBlur: tuner)
        let ownRadius = chrome.barBlurRadius
        XCTAssertGreaterThan(ownRadius, 0, "the system's own filter is still there, untouched")
        chrome.layoutChrome()
        chrome.reapplyBarBlur()
        window.appearance = NSAppearance(named: .aqua)
        pump(0.2)
        chrome.layoutChrome()
        XCTAssertEqual(chrome.barBlurRadius, ownRadius,
                       "the fallback keeps the system's own radius")
        XCTAssertTrue(chrome.hazeVisible, "the haze still shows with the fallback")
        XCTAssertEqual(facts, [], "a backdrop not found yet is not evidence: the system builds it late")
        chrome.releaseGraphics()
        window.close()
        XCTAssertEqual(facts, ["backdrops=1 filters=[x]"],
                       "a window that never found it says so once, when it closes, with what it held")
    }

    func testAWindowThatFoundTheFilterOrNeverWoreTheBarSaysNothing() {
        var facts = 0
        let found = BarBlurTuner(lookup: { _ in 30 }, logFailure: { _ in facts += 1 })
        XCTAssertTrue(found.apply(in: CALayer()))
        found.windowClosing(root: CALayer())
        let neverTried = BarBlurTuner(lookup: { _ in nil }, logFailure: { _ in facts += 1 })
        neverTried.windowClosing(root: CALayer())
        XCTAssertEqual(facts, 0)
        XCTAssertEqual(BarBlur.diagnosis(in: CALayer()), "backdrops=0 portals=0 filters=[]")
    }

    /// The reported see-through bar (issue #45): the extension view builds its
    /// backdrop in a pass of its own, after the chrome's layout has looked for
    /// it, so a window whose first frame came before that pass kept the
    /// system's 5 pt blur — a near-sharp mirror that reads as a transparent
    /// bar — until some later event happened to re-layout the chrome. No
    /// forced layout here: the window opens, the run loop runs, and the radius
    /// must be the picked one.
    func testTheRadiusIsSetWhenTheSystemBuildsItsBackdropWithNoOtherEvent() throws {
        for withFrameFirst in [false, true] {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 628),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: .darkAqua)
            let video = VideoLayerView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
            if withFrameFirst { video.setVideoSizeForTesting(CGSize(width: 900, height: 600)) }
            let chrome = StreamChromeView(video: video, style: .compact)
            chrome.frame = NSRect(x: 0, y: 0, width: 900, height: 628)
            window.contentView = chrome
            window.makeKeyAndOrderFront(nil)
            pump(0.3)
            XCTAssertNotNil(variableBlur(in: chrome.layer), "the system built its backdrop")
            XCTAssertEqual(try XCTUnwrap(radius(variableBlur(in: chrome.layer))), 30, accuracy: 0.01,
                           "the radius follows the backdrop's own build (frame first: \(withFrameFirst))")
            window.close()
        }
    }
}
