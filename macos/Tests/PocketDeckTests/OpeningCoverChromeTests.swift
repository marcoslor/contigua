// WIN-11's opening cover in the chrome: while the cover is up a framed window
// lays out with the immersive geometry — one sheet from the window's top edge,
// the lights and Live Text on the immersive pill's row — and the framed bar
// (mirror, blur and haze) waits for the first frame. The stored style never
// changes; the stall overlay (WIN-39) still spans the whole window.

import AppKit
import XCTest
@testable import PocketDeck

@MainActor
final class OpeningCoverChromeTests: XCTestCase {
    private func makeChrome(style: WindowStyle = .framed, actions: [HeaderAction] = [],
                            coverUp: Bool = true) -> (NSWindow, StreamChromeView) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 628),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        let video = VideoLayerView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        video.setVideoSizeForTesting(CGSize(width: 900, height: 600))
        let chrome = StreamChromeView(video: video, style: style)
        chrome.frame = NSRect(x: 0, y: 0, width: 900, height: 628)
        window.contentView = chrome
        window.makeKeyAndOrderFront(nil)
        chrome.setActions(actions)
        if coverUp {
            chrome.openingCover.show(OpeningCover.display(.opening, name: "Chrome", phone: "Pixel 9",
                                                          phoneMode: false), icon: nil)
        }
        chrome.layoutChrome()
        return (window, chrome)
    }

    private func openingDisplay() -> OpeningCover.Display {
        OpeningCover.display(.opening, name: "Chrome", phone: "Pixel 9", phoneMode: false)!
    }

    /// The cover is one sheet over the whole content, the stream's area is the
    /// window's, and nothing of the bar's mirror band or haze shows. The first
    /// frame brings the framed bar back exactly as it was.
    func testTheCoverIsOneSheetAndTheFramedBarWaitsForTheFirstFrame() throws {
        let (window, chrome) = makeChrome()
        defer { window.close() }
        XCTAssertEqual(chrome.style, .framed, "the window's stored style is framed")
        XCTAssertEqual(chrome.openingCover.frame, chrome.bounds,
                       "the cover is one sheet over the whole content, the bar's band included")
        XCTAssertEqual(chrome.barHeight, 0, "no bar is laid out while the cover shows")
        XCTAssertEqual(chrome.video.frame, chrome.bounds, "the stream's area is the whole window")
        XCTAssertEqual(chrome.bounds.height - chrome.video.frame.maxY, 0,
                       "the bar's mirror band has no height to show")
        XCTAssertFalse(chrome.hazeVisible, "the framed haze is not over the cover")

        chrome.openingCover.show(nil, icon: nil)
        chrome.layoutChrome()
        XCTAssertEqual(chrome.style, .framed, "the first frame does not change the stored style")
        XCTAssertEqual(chrome.barHeight, ChromeBar.height, "the framed bar comes back with the picture")
        XCTAssertEqual(chrome.video.frame, NSRect(x: 0, y: 0, width: 900, height: 600),
                       "the stream keeps its framed area")
        XCTAssertEqual(chrome.bounds.height - chrome.video.frame.maxY, ChromeBar.height,
                       "the mirror band is back over the stream")
        XCTAssertTrue(chrome.hazeVisible, "and the framed haze with it")
    }

    /// The pill comes up as immersive shows it: at the window's top-left, the
    /// lights on its row and Live Text next to them — never at the framed
    /// bar's right end.
    func testTheCoverPutsTheControlsOnTheImmersivePillRow() throws {
        let actions: [HeaderAction] = [.back {}, .home {}, .recents {}]
        let (window, chrome) = makeChrome(actions: actions)
        defer { window.close() }
        chrome.setPill(true)
        chrome.placeTrafficLights()

        let pill = chrome.pill.frame
        XCTAssertEqual(pill.minX, DwellChrome.pillInset, accuracy: 0.5,
                       "the pill sits at the window's top-left corner")
        XCTAssertEqual(pill.maxY, chrome.bounds.height - DwellChrome.pillInset, accuracy: 0.5)

        let liveText = chrome.liveTextButton.frame
        XCTAssertFalse(chrome.liveTextButton.isHidden)
        let nextToTheActions = pill.minX + DwellChrome.pillActionsX + HeaderBar.rowWidth(actions)
            + HeaderBar.capsuleGap
        XCTAssertEqual(liveText.minX, nextToTheActions, accuracy: 0.5,
                       "Live Text rides the pill's row, after the action capsules")
        let barRightEnd = chrome.bounds.width - HeaderBar.rightInset - HeaderBar.liveTextSide
        XCTAssertNotEqual(liveText.minX, barRightEnd, accuracy: 0.5,
                          "it is not at the framed bar's right end")

        let close = try XCTUnwrap(window.standardWindowButton(.closeButton))
        let light = close.convert(close.bounds, to: nil)
        XCTAssertEqual(light.midX, DwellChrome.pillInset + ChromeBar.trafficLightInset
                       + ChromeBar.trafficLightButtonSide / 2, accuracy: 0.5,
                       "the lights sit on the pill's row")
        XCTAssertEqual(window.frame.height - light.midY,
                       DwellChrome.pillInset + DwellChrome.pillHeight / 2, accuracy: 0.5)
    }

    /// WIN-39 is unchanged: the stall overlay still spans the window, with its
    /// words in the body under the framed bar — and with the cover up it still
    /// spans the same window.
    func testTheStallOverlayKeepsItsGeometry() throws {
        let (window, chrome) = makeChrome(coverUp: false)
        defer { window.close() }
        chrome.stallOverlay.show(StallOverlayDisplay(kind: .stalled, phone: "Pixel 9"), icon: nil)
        chrome.layoutChrome()
        XCTAssertEqual(chrome.stallOverlay.frame, chrome.bounds, "the overlay is one sheet")
        XCTAssertEqual(chrome.stallOverlay.topInset, ChromeBar.height,
                       "its words stay centred in the body under the bar")

        chrome.openingCover.show(openingDisplay(), icon: nil)
        chrome.layoutChrome()
        XCTAssertEqual(chrome.openingCover.frame, chrome.bounds)
        XCTAssertEqual(chrome.stallOverlay.frame, chrome.bounds)
        XCTAssertEqual(chrome.barHeight, 0, "the cover's immersive geometry leaves no bar")
    }
}
