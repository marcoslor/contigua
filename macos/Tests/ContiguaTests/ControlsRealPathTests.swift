// The real-control family (AGENTS.md "Drive the real control"): every bar
// button and the Live Text button take a hit test at their own centre and run
// their action exactly once from a mouse down/up pair — not from a debug verb.
// The phone window's Back/Home/Recents and the Live Text button are the
// controls the v103 regression broke; the app window has no kind actions, so
// its Live Text button is checked there too. The Navigate menu items share
// these selectors and are pinned by NavShortcutTests.

import AppKit
import XCTest
@testable import Contigua

@MainActor
final class ControlsRealPathTests: XCTestCase {
    private func makeChrome(style: WindowStyle) -> StreamChromeView {
        let video = VideoLayerView(frame: NSRect(x: 0, y: 0, width: 360, height: 780))
        let chrome = StreamChromeView(video: video, style: style)
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

    private func centre(of view: NSView, in root: NSView) -> NSPoint {
        view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: root)
    }

    /// The action a click at the control's own location runs.
    private func click<R: NSView>(_ view: R, in root: NSView) -> NSView? {
        let point = centre(of: view, in: root)
        guard let hit = root.hitTest(point) else { return nil }
        hit.mouseDown(with: event(.leftMouseDown, at: point))
        hit.mouseUp(with: event(.leftMouseUp, at: point))
        return hit
    }

    func testEveryPhoneBarButtonHitsItselfAndFiresOnce() {
        for style in [WindowStyle.framed, .immersive] {
            let chrome = makeChrome(style: style)
            var fired: [String] = []
            chrome.setActions(phoneActions { fired.append($0) })
            chrome.layoutSubtreeIfNeeded()
            let buttons = allButtons(in: chrome)
            XCTAssertEqual(buttons.map(\.action.kind), [.back, .home, .recents],
                           "\(style): the phone window's trio")
            for (index, button) in buttons.enumerated() {
                let point = centre(of: button, in: chrome)
                XCTAssertTrue(chrome.hitTest(point) === button,
                              "\(style): \(button.action.help)'s centre must hit its button")
                _ = click(button, in: chrome)
                XCTAssertEqual(fired, Array(["back", "home", "recents"].prefix(index + 1)),
                               "\(style): \(button.action.help) must fire exactly once")
            }
        }
    }

    func testTheLiveTextButtonHitsItselfAndFiresOnceInEveryWindowKind() {
        for style in [WindowStyle.framed, .immersive] {
            for actions in [[], phoneActions { _ in }] {
                let chrome = makeChrome(style: style)
                chrome.setActions(actions)
                var presses = 0
                chrome.liveTextButton.onPress = { presses += 1 }
                chrome.layoutSubtreeIfNeeded()
                let point = centre(of: chrome.liveTextButton, in: chrome)
                XCTAssertTrue(chrome.hitTest(point) === chrome.liveTextButton,
                              "\(style) with \(actions.count) kind actions: Live Text's centre")
                _ = click(chrome.liveTextButton, in: chrome)
                XCTAssertEqual(presses, 1, "\(style): one click, one toggle")
            }
        }
    }

    func testLiveTextFreezesTheKindActionsButNotItsOwnButton() {
        for style in [WindowStyle.framed, .immersive] {
            let chrome = makeChrome(style: style)
            var fired: [String] = []
            chrome.setActions(phoneActions { fired.append($0) })
            chrome.setLiveText(active: true)
            chrome.layoutSubtreeIfNeeded()
            let buttons = allButtons(in: chrome)
            XCTAssertEqual(buttons.count, 3)
            for button in buttons {
                let point = centre(of: button, in: chrome)
                // The frozen button still takes the click and swallows it: if
                // it answered nil, the click would fall through to the video
                // under the bar and become a tap on the phone. It runs nothing.
                XCTAssertTrue(chrome.hitTest(point) === button,
                              "\(style): \(button.action.help) swallows its click while frozen")
                _ = click(button, in: chrome)
            }
            XCTAssertTrue(fired.isEmpty, "\(style): no kind action ran while frozen")

            var presses = 0
            chrome.liveTextButton.onPress = { presses += 1 }
            _ = click(chrome.liveTextButton, in: chrome)
            XCTAssertEqual(presses, 1, "\(style): Live Text's own button stays live")
        }
    }
}
