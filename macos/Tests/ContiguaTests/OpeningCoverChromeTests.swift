// WIN-11's opening cover in the chrome: while the cover is up the window wears
// one sheet from its top edge — no style bar or frame, the traffic lights and
// our controls on the bar's row — and the windowed chrome (Immersive's mirror
// or Framed's material) waits for the first frame. The stored style never
// changes; the stall overlay (WIN-39) still spans the whole window.

import AppKit
import XCTest
@testable import Contigua

@MainActor
final class OpeningCoverChromeTests: XCTestCase {
    private func makeChrome(style: WindowStyle = .framed, actions: [HeaderAction] = [],
                            coverUp: Bool = true) -> (NSWindow, StreamChromeView) {
        let size = style.windowSize(stream: CGSize(width: 900, height: 600))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        let video = VideoLayerView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        video.setVideoSizeForTesting(CGSize(width: 900, height: 600))
        let chrome = StreamChromeView(video: video, style: style)
        chrome.frame = NSRect(origin: .zero, size: size)
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

    /// The cover is one sheet over the whole content, the stream keeps the
    /// stored style's rect, and nothing of the style's chrome shows. The first
    /// frame brings the Framed frame back exactly as it was.
    func testTheCoverIsOneSheetAndTheWindowedChromeWaitsForTheFirstFrame() throws {
        let (window, chrome) = makeChrome()
        defer { window.close() }
        XCTAssertEqual(chrome.style, .framed, "the window's stored style is framed")
        XCTAssertEqual(chrome.openingCover.frame, chrome.bounds,
                       "the cover is one sheet over the whole content, the frame's band included")
        XCTAssertEqual(chrome.barHeight, 0, "no style band is laid out while the cover shows")
        XCTAssertEqual(chrome.streamContentRect,
                       NSRect(x: FramedChrome.sideInset, y: FramedChrome.bottomInset,
                              width: 900, height: 600),
                       "the stream keeps the framed style's rect, so the virtual display does not move")
        XCTAssertFalse(chrome.barMirrorVisible, "the mirror's band is under the cover, not on screen")
        XCTAssertFalse(chrome.hazeVisible, "the Immersive haze is not over the cover")
        XCTAssertTrue(chrome.framedTitleView.isHidden, "the Framed frame is not drawn under the cover")

        chrome.openingCover.show(nil, icon: nil)
        chrome.layoutChrome()
        XCTAssertFalse(chrome.openingCover.isShowing, "the cover is logically gone at once")
        XCTAssertEqual(chrome.barHeight, FramedChrome.topInset,
                       "the first frame brings the Framed frame back at once, under the fade")
        XCTAssertFalse(chrome.openingCover.isHidden, "the old sheet is still fading out")
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.3))
        XCTAssertTrue(chrome.openingCover.isHidden, "the 200 ms fade-out ends hidden")
        XCTAssertEqual(chrome.style, .framed, "the first frame does not change the stored style")
        XCTAssertEqual(chrome.barHeight, FramedChrome.topInset, "the frame comes back with the picture")
        XCTAssertEqual(chrome.streamContentRect,
                       NSRect(x: FramedChrome.sideInset, y: FramedChrome.bottomInset,
                              width: 900, height: 600),
                       "the stream keeps its framed area")
    }

    /// The cover's controls are the bar's row in either style: the lights at
    /// the window's top-left and our controls at the right, never a floating
    /// pill in the picture.
    func testTheCoverPutsTheControlsOnTheBarRow() throws {
        let actions: [HeaderAction] = [.back {}, .home {}, .recents {}]
        let (window, chrome) = makeChrome(actions: actions)
        defer { window.close() }
        chrome.placeTrafficLights()

        let liveText = chrome.liveTextButton.frame
        XCTAssertFalse(chrome.liveTextButton.isHidden)
        let barRightEnd = chrome.bounds.width - HeaderBar.rightInset - HeaderBar.liveTextSide
        XCTAssertEqual(liveText.minX, barRightEnd, accuracy: 0.5,
                       "Live Text stays at the bar's right end")

        let close = try XCTUnwrap(window.standardWindowButton(.closeButton))
        let light = close.convert(close.bounds, to: nil)
        XCTAssertEqual(light.midX, ChromeBar.trafficLightInset + ChromeBar.trafficLightButtonSide / 2,
                       accuracy: 0.5, "the lights sit on the cover's top row")
        XCTAssertEqual(window.frame.height - light.midY,
                       ChromeBar.trafficLightInset + ChromeBar.trafficLightButtonSide / 2,
                       accuracy: 0.5)
    }

    /// WIN-39 is unchanged: the stall overlay still spans the window, with its
    /// words in the body under the style's top band — and with the cover up it
    /// still spans the same window.
    func testTheStallOverlayKeepsItsGeometry() throws {
        let (window, chrome) = makeChrome(coverUp: false)
        defer { window.close() }
        chrome.stallOverlay.show(StallOverlayDisplay(kind: .stalled, phone: "Pixel 9"), icon: nil)
        chrome.layoutChrome()
        XCTAssertEqual(chrome.stallOverlay.frame, chrome.bounds, "the overlay is one sheet")
        XCTAssertEqual(chrome.stallOverlay.topInset, FramedChrome.topInset,
                       "its words stay centred in the body under the bar")

        chrome.openingCover.show(openingDisplay(), icon: nil)
        chrome.layoutChrome()
        XCTAssertEqual(chrome.openingCover.frame, chrome.bounds)
        XCTAssertEqual(chrome.stallOverlay.frame, chrome.bounds)
        XCTAssertEqual(chrome.barHeight, 0, "the cover's one sheet leaves no style band")
    }
}
