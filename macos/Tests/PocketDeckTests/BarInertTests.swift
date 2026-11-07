// The Framed bar is a blurred mirror of the stream's top edge, not the
// picture: a click on it drags the window and must never become a touch on
// the phone (WIN-61). The extension view fills the window with the stream as
// its content view — that is how the bar draws its mirror — so the hit test
// must decide from the bar's own band, never from where the picture's view
// ends up.

import AppKit
import XCTest
@testable import PocketDeck

@MainActor
final class BarInertTests: XCTestCase {
    private func makeChrome() -> StreamChromeView {
        let video = VideoLayerView(frame: NSRect(x: 0, y: 0, width: 360, height: 780))
        let chrome = StreamChromeView(video: video, style: .framed)
        chrome.frame = NSRect(x: 0, y: 0, width: 360, height: 800)
        return chrome
    }

    func testAClickOnTheFramedBarsMirrorIsInert() {
        let chrome = makeChrome()
        chrome.layoutSubtreeIfNeeded()
        // The extension view stretches its content view over the whole window;
        // model it, as the system does in a real window.
        chrome.video.frame = chrome.bounds
        let band = chrome.bounds.height - ChromeBar.height / 2
        for x in stride(from: 8.0, through: chrome.bounds.width - 8, by: 40) {
            let point = NSPoint(x: x, y: band)
            let hit = chrome.hitTest(point)
            XCTAssertFalse(hit === chrome.video,
                           "the bar's mirror at x=\(x) reached the picture: a click there is a touch on the phone")
        }
    }

    func testTheBarsOwnButtonsStillTakeTheirClicks() {
        let chrome = makeChrome()
        var fired = 0
        chrome.setActions([.back { fired += 1 }])
        chrome.layoutSubtreeIfNeeded()
        var button: NSView?
        func find(_ view: NSView) {
            for sub in view.subviews {
                if sub is HeaderActionButton { button = sub }
                find(sub)
            }
        }
        find(chrome)
        guard let button else { return XCTFail("no bar action button") }
        let point = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: chrome)
        let hit = chrome.hitTest(point)
        XCTAssertTrue(hit === button || hit?.isDescendant(of: button) == true,
                      "the bar's own button must keep its click")
    }

    /// The native titlebar is taller than the 28 pt bar (32 pt on macOS 26):
    /// its bottom rows are still the window's edge above the stream's first
    /// visible row, so a click there must drag, not reach the picture.
    func testAClickUnderTheTitlebarIsStillTheBars() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 800),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable,
                                          .fullSizeContentView],
                              backing: .buffered, defer: false)
        defer { window.close() }
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        let video = VideoLayerView(frame: NSRect(x: 0, y: 0, width: 360, height: 800))
        let chrome = StreamChromeView(video: video, style: .framed)
        window.contentView = chrome
        window.orderFront(nil)
        window.layoutIfNeeded()
        chrome.layoutSubtreeIfNeeded()
        let titlebar = window.frame.height - window.contentLayoutRect.maxY
        try XCTSkipIf(titlebar <= ChromeBar.height,
                      "this titlebar (\(titlebar) pt) is not taller than the bar")
        // The extension view stretches the picture over the window, as it
        // does in a real window.
        chrome.video.frame = chrome.bounds
        let point = NSPoint(x: chrome.bounds.midX,
                            y: chrome.bounds.height - titlebar + 1)
        let hit = chrome.hitTest(point)
        XCTAssertFalse(hit === chrome.video,
                       "the titlebar's bottom row is the bar's edge, not the picture's")
        XCTAssertTrue(hit === chrome, "the titlebar's bottom row drags the window")
        // The stream's first visible row below the titlebar is still the
        // picture's and keeps its touch.
        let stream = NSPoint(x: chrome.bounds.midX,
                             y: chrome.bounds.height - titlebar - 1)
        XCTAssertFalse(chrome.hitTest(stream) === chrome,
                       "the stream below the titlebar must stay the picture's")
    }
}
