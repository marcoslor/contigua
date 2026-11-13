// The window's own band is never the phone's (WIN-61). In Compact the band is
// AppKit's title bar, above the content view: the content view is exactly the
// stream, so its top row is the picture's and a title-bar click never reaches
// our view. Framed's own bar buttons keep their clicks over the frame.

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

    func testCompactsContentIsThePictureUpToItsTopRow() {
        let chrome = makeChrome(.compact)
        XCTAssertEqual(chrome.video.frame, chrome.bounds, "the content view is the stream")
        for x in stride(from: 8.0, through: chrome.bounds.width - 8, by: 40) {
            let point = NSPoint(x: x, y: chrome.bounds.height - 1)
            XCTAssertTrue(chrome.hitTest(point) === chrome.video,
                          "the stream's top row at x=\(x) is the phone's: the title bar is above it")
        }
    }

    /// A point in AppKit's title bar is outside the content view, so our
    /// view never sees its clicks: AppKit drags and zooms there.
    func testCompactsTitleBarIsOutsideOurView() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 780),
                              styleMask: WindowStyle.compact.styleMask, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let video = VideoLayerView(frame: NSRect(x: 0, y: 0, width: 360, height: 780))
        let chrome = StreamChromeView(video: video, style: .compact)
        window.contentView = chrome
        window.orderFront(nil)
        window.layoutIfNeeded()
        let titlebar = window.frame.height - window.contentLayoutRect.height
        XCTAssertGreaterThan(titlebar, 0)
        XCTAssertEqual(chrome.frame.height, 780, "the content view stops under the title bar")
        let inTitlebar = NSPoint(x: 180, y: chrome.frame.maxY + titlebar / 2)
        XCTAssertNil(chrome.hitTest(inTitlebar), "the title bar is AppKit's, not ours")
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
