// The window's own band is never the phone's (WIN-61). In Compact the band is
// the stream's top edge mirrored up under AppKit's transparent title bar: the
// mirror's content view is the picture, so the hit test decides from the band
// itself, never from where the picture's view ends up. Framed's own bar
// buttons keep their clicks over the frame.

import AppKit
import XCTest
@testable import Contigua

@MainActor
final class BarInertTests: XCTestCase {
    private func makeChrome(_ style: WindowStyle) -> StreamChromeView {
        let stream = NSSize(width: 360, height: 780)
        let video = VideoLayerView(frame: NSRect(origin: .zero, size: stream))
        let chrome = StreamChromeView(video: video, style: style)
        chrome.frame = NSRect(origin: .zero, size: style.contentSize(stream: stream))
        chrome.layoutSubtreeIfNeeded()
        return chrome
    }

    func testCompactsBandIsNeverThePhonesWhereverThePictureEndsUp() {
        let chrome = makeChrome(.compact)
        XCTAssertEqual(chrome.contentRect, NSRect(x: 0, y: 0, width: 360, height: 780), "the stream is under the band")
        XCTAssertGreaterThan(chrome.barHeight, 0)
        let band = chrome.bounds.height - chrome.barHeight / 2
        for stretched in [false, true] {
            // The mirror may stretch its content view over itself, as the
            // system does in a real window: the band still decides.
            if stretched { chrome.video.frame = chrome.bandMirror.bounds }
            for x in stride(from: 8.0, through: chrome.bounds.width - 8, by: 40) {
                XCTAssertFalse(chrome.hitTest(NSPoint(x: x, y: band)) === chrome.video,
                               "the band at x=\(x) reached the picture: a click there is a touch on the phone")
                XCTAssertTrue(chrome.ownsPoint(NSPoint(x: x, y: band)), "hover in the band is the window's too")
            }
        }
        chrome.layoutChrome()
        let topRow = NSPoint(x: 180, y: chrome.contentRect.maxY - 1)
        XCTAssertTrue(chrome.hitTest(topRow) === chrome.video, "the stream's own top row is the phone's")
        XCTAssertFalse(chrome.ownsPoint(topRow))
    }

    /// A real click in the band lands in AppKit's transparent title bar,
    /// which drags and zooms; it never reaches the picture.
    func testARealClickInTheBandIsTheTitleBarsNotThePictures() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 812),
                              styleMask: WindowStyle.compact.styleMask, backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let video = VideoLayerView(frame: NSRect(x: 0, y: 0, width: 360, height: 780))
        let chrome = StreamChromeView(video: video, style: .compact)
        window.contentView = chrome
        window.orderFront(nil)
        window.layoutIfNeeded()
        chrome.layoutChrome()
        let frameView = try XCTUnwrap(chrome.superview)
        let titlebar = window.frame.height - window.contentLayoutRect.height
        XCTAssertGreaterThan(titlebar, 0)
        let inBand = NSPoint(x: 180, y: window.frame.height - titlebar / 2)
        let hit = frameView.hitTest(inBand)
        XCTAssertFalse(hit === chrome.video || hit?.isDescendant(of: chrome.video) == true,
                       "the band is the window's: \(String(describing: hit))")
    }

    func testTheBarsOwnButtonsStillTakeTheirClicks() {
        let chrome = makeChrome(.framed)
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
}
