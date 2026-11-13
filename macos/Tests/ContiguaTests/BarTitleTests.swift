// The Framed bar's title: its pure layout, the names each window kind gives
// it, and the label Framed draws (WIN-68, MIRROR-26). Compact and full screen
// show the window's own title in AppKit's title bar.

import AppKit
import XCTest
@testable import Contigua

final class BarTitleLayoutTests: XCTestCase {
    /// The zoom light's right edge in a 28 pt row: where the title's
    /// clearance from the lights begins.
    private let lightsEnd: CGFloat = 7 + 2 * 23 + 14
    private let windowWidth: CGFloat = 900
    private let barHeight = ChromeBar.height
    private let rowStart: CGFloat = 763  // 900 - 7 - (3*32 + 6 + 28)

    func testTheTitleIsCentredBetweenTheLightsAndTheRow() throws {
        let text = "Quarterly notes"
        let frame = try XCTUnwrap(BarTitle.frame(text: text, windowWidth: windowWidth,
                                                barHeight: barHeight, boundsHeight: 628,
                                                lightsEnd: lightsEnd,
                                                rightRowStart: rowStart))
        XCTAssertEqual(frame.midX, windowWidth / 2, accuracy: 0.01,
                       "the title is centred on the bar's own line")
        XCTAssertGreaterThanOrEqual(frame.minX, lightsEnd + BarTitle.sideGap)
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
                                                lightsEnd: lightsEnd,
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

    /// Issue #45's captures read "Settings (FakePhone" — the field drew the
    /// name clipped by its cell's own edges: a clipping field must be at
    /// least as wide as the cell needs to draw the whole line.
    @MainActor func testAWholeNamesFieldIsAsWideAsItsCellDraws() {
        for name in ["Settings (FakePhone)", "Spotify (Galaxy S25+)", "Settings", "Quarterly notes",
                     "WhatsApp (Nicky)", "Phone Mirror"] {
            let field = NSTextField(labelWithString: name)
            BarTitle.configure(field)
            field.lineBreakMode = .byClipping  // as `layOut` draws a name that fits
            let needed = field.cell?.cellSize.width ?? 0
            XCTAssertGreaterThanOrEqual(BarTitle.textWidth(name), needed, "\(name) fits its own cell")
            XCTAssertEqual(BarTitle.lineBreakMode(text: name, width: BarTitle.textWidth(name)), .byClipping)
        }
    }

    func testTheTitleHidesBelowItsMinimumWidth() {
        // "Mail" is narrower than the 40 pt minimum, so only the minimum hides it.
        XCTAssertLessThan(BarTitle.textWidth("Mail"), BarTitle.minimumWidth)
        XCTAssertNil(BarTitle.frame(text: "Mail", windowWidth: 900, barHeight: barHeight,
                                    boundsHeight: 628, lightsEnd: 100,
                                    rightRowStart: 100 + 2 * BarTitle.sideGap
                                        + BarTitle.minimumWidth - 1),
                     "one point too narrow")
        XCTAssertNotNil(BarTitle.frame(text: "Mail", windowWidth: 900, barHeight: barHeight,
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

    /// The bar's name carries the phone: "<App> (<phone>)"; the Mirror's own
    /// name already is the phone's and stays alone.
    func testTheNameCarriesThePhoneAsASuffix() {
        XCTAssertEqual(BarTitleName.withPhone("Settings", phone: "Pixel 9"), "Settings (Pixel 9)")
        XCTAssertEqual(BarTitleName.withPhone(" Settings ", phone: " Pixel 9 "), "Settings (Pixel 9)")
        XCTAssertEqual(BarTitleName.withPhone("Settings", phone: nil), "Settings")
        XCTAssertEqual(BarTitleName.withPhone("Settings", phone: "  "), "Settings")
        XCTAssertEqual(BarTitleName.withPhone("Pixel 9", phone: "Pixel 9"), "Pixel 9",
                       "the Phone Mirror's name is the phone's already")
        XCTAssertNil(BarTitleName.withPhone(nil, phone: "Pixel 9"))
        XCTAssertNil(BarTitleName.withPhone("   ", phone: "Pixel 9"))
    }

    /// The suffix is dropped before the app's name is touched; then the name
    /// keeps WIN-68's thresholds and middle truncation.
    func testThePhoneSuffixGoesFirstWhenTheRoomIsShort() throws {
        let full = "Settings (Pixel 9)"
        let base = "Settings"
        let lightsEnd: CGFloat = 100
        let widthForBase = lightsEnd + 2 * BarTitle.sideGap + BarTitle.textWidth(base) + 0.5
        let dropped = try XCTUnwrap(BarTitle.fitting(
            text: full, base: base, windowWidth: 900, barHeight: barHeight, boundsHeight: 628,
            lightsEnd: lightsEnd, rightRowStart: widthForBase))
        XCTAssertEqual(dropped.text, base, "the phone suffix goes first")
        XCTAssertEqual(dropped.frame.width, BarTitle.textWidth(base), accuracy: 0.5)

        let whole = try XCTUnwrap(BarTitle.fitting(
            text: full, base: base, windowWidth: 900, barHeight: barHeight, boundsHeight: 628,
            lightsEnd: lightsEnd, rightRowStart: 700))
        XCTAssertEqual(whole.text, full, "the whole name when it fits")

        // A long app name: the phone still goes first, then the app's own name
        // is the one that truncates.
        let longApp = String(repeating: "A very long app name ", count: 8)
        let longFull = longApp + " (Pixel 9)"
        let truncated = try XCTUnwrap(BarTitle.fitting(
            text: longFull, base: longApp, windowWidth: 900, barHeight: barHeight, boundsHeight: 628,
            lightsEnd: lightsEnd, rightRowStart: lightsEnd + BarTitle.sideGap + 200))
        XCTAssertEqual(truncated.text, longApp)
        XCTAssertLessThan(truncated.frame.width, BarTitle.textWidth(longApp))

        // One point under 96 pt of room with an app name that cannot fit
        // whole: the title hides rather than showing a couple of letters.
        XCTAssertNil(BarTitle.fitting(
            text: longFull, base: longApp, windowWidth: 900, barHeight: barHeight, boundsHeight: 628,
            lightsEnd: lightsEnd,
            rightRowStart: lightsEnd + 2 * BarTitle.sideGap + BarTitle.minimumTruncatedWidth - 1))
    }
}

final class FramedTitleViewTests: XCTestCase {
    private func makeChrome(width: CGFloat = 910) -> (NSWindow, StreamChromeView) {
        let size = WindowStyle.framed.contentSize(stream: CGSize(width: width - 10, height: 600))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: WindowStyle.framed.styleMask, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        let video = VideoLayerView(frame: NSRect(x: 0, y: 0, width: width - 10, height: 600))
        video.setVideoSizeForTesting(CGSize(width: width - 10, height: 600))
        let chrome = StreamChromeView(video: video, style: .framed)
        chrome.frame = NSRect(origin: .zero, size: size)
        window.contentView = chrome
        window.makeKeyAndOrderFront(nil)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
        chrome.layoutSubtreeIfNeeded()
        return (window, chrome)
    }

    private func layOut(_ chrome: StreamChromeView, width: CGFloat) {
        chrome.frame = NSRect(x: 0, y: 0, width: width, height: chrome.frame.height)
        chrome.layoutChrome()
        chrome.framedTitleView.layoutSubtreeIfNeeded()
    }

    func testTheTitleShowsOnlyInFramedAndOnlyWithAName() {
        let (window, chrome) = makeChrome()
        defer { window.close() }
        chrome.setBarTitle("Maps")
        chrome.layoutChrome()
        XCTAssertTrue(chrome.barTitleVisible)
        XCTAssertNotNil(chrome.barTitleRect)

        chrome.setStyle(.compact)
        chrome.layoutChrome()
        XCTAssertFalse(chrome.barTitleVisible, "Compact's title is the system's, in AppKit's title bar")
        XCTAssertNil(chrome.barTitleRect)
        chrome.setStyle(.immersive)
        chrome.layoutChrome()
        XCTAssertFalse(chrome.barTitleVisible, "Immersive has no bar")
        chrome.setStyle(.framed)
        chrome.layoutChrome()
        XCTAssertTrue(chrome.barTitleVisible)

        chrome.setBarTitle(nil)
        chrome.layoutChrome()
        chrome.framedTitleView.layoutSubtreeIfNeeded()
        XCTAssertFalse(chrome.barTitleVisible, "a window with no name has no title")
    }

    func testTheTitleDrawsThePhoneSuffixAndDropsItFirst() {
        let (window, chrome) = makeChrome()
        defer { window.close() }
        let title = chrome.framedTitleView
        chrome.setBarTitle("Settings", phone: "Pixel 9")
        chrome.layoutChrome()
        XCTAssertEqual(title.titleText, "Settings (Pixel 9)")
        XCTAssertEqual(title.titleLineBreakMode, .byClipping, "the whole name fits at 910 pt")

        // Narrow the window one point at a time: the suffix goes before the
        // app's own name is cut, and the name is cut before it hides.
        var seen: [String] = []
        var width: CGFloat = 910
        while width > 120 {
            layOut(chrome, width: width)
            let state = title.titleIsHidden ? "hidden"
                : title.titleText == "Settings (Pixel 9)" ? "whole"
                : title.titleText == "Settings" && title.titleLineBreakMode == .byClipping ? "base"
                : title.titleText == "Settings" ? "truncated" : "other: \(title.titleText)"
            if seen.last != state { seen.append(state) }
            width -= 1
        }
        XCTAssertEqual(seen, ["whole", "base", "hidden"],
                       "a short name hides at the minimum rather than shrink to two letters")

        // The Mirror's title already is the phone's: no doubled suffix.
        layOut(chrome, width: 910)
        chrome.setBarTitle("Pixel 9", phone: "Pixel 9")
        chrome.layoutChrome()
        XCTAssertEqual(title.titleText, "Pixel 9")
    }

    func testALongNameTruncatesInTheMiddleAndAShortOneIsWhole() {
        let (window, chrome) = makeChrome()
        defer { window.close() }
        let title = chrome.framedTitleView
        chrome.setBarTitle("Settings")
        chrome.layoutChrome()
        XCTAssertEqual(title.titleLineBreakMode, .byClipping, "a name that fits is drawn whole")
        chrome.setBarTitle(String(repeating: "A very long app name ", count: 8))
        chrome.layoutChrome()
        chrome.framedTitleView.layoutSubtreeIfNeeded()
        XCTAssertFalse(title.titleIsHidden)
        XCTAssertEqual(title.titleLineBreakMode, .byTruncatingMiddle,
                       "a name wider than the bar truncates in the middle")
    }
}
