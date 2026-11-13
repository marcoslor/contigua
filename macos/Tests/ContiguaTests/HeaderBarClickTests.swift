// The bar's buttons take a real click (v103 regression): a hit test at each
// button's centre returns that button — not the capsule, the bar or the stream
// behind it — and a mouseDown/mouseUp pair at its location runs the action
// exactly once. AppKit's `hitTest` hands a view a point in its superview's
// coordinates, which is the space the buttons must test.

import AppKit
import XCTest
@testable import Contigua

@MainActor
final class HeaderBarClickTests: XCTestCase {
    /// A real chrome (framed, the phone window's default) laid out as the phone
    /// window lays it out: 380 x 800 pt, the bar's row at the right end.
    private func makeChrome() -> StreamChromeView {
        let video = VideoLayerView(frame: NSRect(x: 0, y: 0, width: 360, height: 780))
        let chrome = StreamChromeView(video: video, style: .compact)
        chrome.frame = NSRect(x: 0, y: 0, width: 380, height: 800)
        return chrome
    }

    private func allButtons(in view: NSView) -> [HeaderActionButton] {
        var found: [HeaderActionButton] = []
        for sub in view.subviews {
            if let button = sub as? HeaderActionButton { found.append(button) }
            found += allButtons(in: sub)
        }
        return found
    }

    private func phoneActions(_ fired: @escaping (String) -> Void) -> [HeaderAction] {
        [.back { fired("back") }, .home { fired("home") }, .recents { fired("recents") }]
    }

    private func event(_ type: NSEvent.EventType, at point: NSPoint) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                           windowNumber: 0, context: nil, eventNumber: 0,
                           clickCount: 1, pressure: 1)!
    }

    func testTheHitTestAtEachButtonsCentreReturnsThatButton() {
        let chrome = makeChrome()
        chrome.setActions(phoneActions { _ in })
        chrome.layoutSubtreeIfNeeded()
        let buttons = allButtons(in: chrome)
        XCTAssertEqual(buttons.map(\.action.kind), [.back, .home, .recents])
        for button in buttons {
            let centre = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: chrome)
            XCTAssertTrue(chrome.hitTest(centre) === button,
                          "\(button.action.help)'s centre did not hit its button")
        }
    }

    func testAMouseDownAndUpOnAButtonRunsItsActionOnce() {
        let chrome = makeChrome()
        var fired: [String] = []
        chrome.setActions(phoneActions { fired.append($0) })
        chrome.layoutSubtreeIfNeeded()
        for (index, button) in allButtons(in: chrome).enumerated() {
            let centre = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: chrome)
            guard let hit = chrome.hitTest(centre) else {
                XCTFail("\(button.action.help)'s centre hit nothing")
                continue
            }
            hit.mouseDown(with: event(.leftMouseDown, at: centre))
            hit.mouseUp(with: event(.leftMouseUp, at: centre))
            XCTAssertEqual(fired, Array(["back", "home", "recents"].prefix(index + 1)),
                           "\(button.action.help) did not fire exactly once")
        }
    }

    func testAReleaseOutsideTheButtonDoesNotFire() {
        let chrome = makeChrome()
        var fired = 0
        chrome.setActions(phoneActions { _ in fired += 1 })
        chrome.layoutSubtreeIfNeeded()
        guard let button = allButtons(in: chrome).first else { return XCTFail("no buttons") }
        let centre = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: chrome)
        let outside = NSPoint(x: centre.x, y: centre.y - 40)
        button.mouseDown(with: event(.leftMouseDown, at: centre))
        button.mouseUp(with: event(.leftMouseUp, at: outside))
        XCTAssertEqual(fired, 0, "a release outside the button is not its action")
    }

    func testTheBarsEmptyRunIsNotAButton() {
        let chrome = makeChrome()
        chrome.setActions(phoneActions { _ in })
        chrome.layoutSubtreeIfNeeded()
        guard let first = allButtons(in: chrome).first else { return XCTFail("no buttons") }
        // Four points left of the first capsule, on the bar's empty run, which
        // is the bar's own (a drag).
        let point = first.convert(NSPoint(x: -4, y: first.bounds.midY), to: chrome)
        XCTAssertFalse(chrome.hitTest(point) is HeaderActionButton,
                       "the bar's empty run must not hit a button")
    }
}
