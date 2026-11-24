// The window's own band is never the phone's (WIN-61). In Compact the band is
// the stream's top edge mirrored up under AppKit's transparent title bar: the
// mirror's content view is the picture, so the hit test decides from the band
// itself, never from where the picture's view ends up. Framed's own bar
// buttons keep their clicks over the frame.

import AppKit
import XCTest
@testable import Contigua

/// A window kept at the size it is given: a small screen (the runner's
/// 1024x768) must not clamp the band out of it.
private final class UnclampedWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

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

    func testCompactsBandIsNeverThePhonesWhereverThePictureEndsUp() throws {
        let chrome = makeChrome(.compact)
        XCTAssertEqual(chrome.contentRect, NSRect(x: 0, y: 0, width: 360, height: 780), "the stream is under the band")
        XCTAssertGreaterThan(chrome.barHeight, 0)
        // The chrome in a container wholly below a titled window's own title
        // bar: no AppKit title bar is over the band, so the window's dispatch
        // (#245: NSWindow.sendEvent, the route a person's click takes, not
        // which view hitTest names) reaches the chrome's own decision.
        let window = UnclampedWindow(contentRect: NSRect(origin: .zero, size: chrome.frame.size),
                                     styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let container = NSView(frame: NSRect(origin: .zero, size: chrome.frame.size))
        window.contentView = container
        container.addSubview(chrome)
        chrome.frame = container.bounds
        chrome.layoutSubtreeIfNeeded()
        // A window that was never ordered in drops the clicks it is sent.
        window.orderFront(nil)
        XCTAssertEqual(container.frame.size, chrome.frame.size, "the whole chrome is in the window")
        XCTAssertGreaterThan(window.frame.height, window.contentLayoutRect.height, "a title bar above the container")
        var downs = 0
        chrome.video.onPointerDown = { downs += 1 }
        func click(_ point: NSPoint) {
            let inWindow = chrome.convert(point, to: nil)
            window.sendEvent(windowClick(.leftMouseDown, at: inWindow, in: window))
            window.sendEvent(windowClick(.leftMouseUp, at: inWindow, in: window))
        }
        let band = chrome.bounds.height - chrome.barHeight / 2
        for stretched in [false, true] {
            // The mirror may stretch its content view over itself, as the
            // system does in a real window: the band still decides.
            if stretched { chrome.video.frame = chrome.bandMirror.bounds }
            for x in stride(from: 8.0, through: chrome.bounds.width - 8, by: 40) {
                click(NSPoint(x: x, y: band))
                XCTAssertEqual(downs, 0, "the band at x=\(x) reached the picture (stretched \(stretched)): "
                                   + "a click there is a touch on the phone")
                XCTAssertTrue(chrome.ownsPoint(NSPoint(x: x, y: band)), "hover in the band is the window's too")
            }
        }
        chrome.layoutChrome()
        let topRow = NSPoint(x: 180, y: chrome.contentRect.maxY - 1)
        click(topRow)
        XCTAssertEqual(downs, 1, "the stream's own top row is the phone's")
        XCTAssertFalse(chrome.ownsPoint(topRow))
    }

    /// A left click at a point in the window's base coordinates, for
    /// `NSWindow.sendEvent`.
    private func windowClick(_ type: NSEvent.EventType, at point: NSPoint, in window: NSWindow) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                           timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                           context: nil, eventNumber: 0, clickCount: 1,
                           pressure: type == .leftMouseDown ? 1 : 0)!
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
