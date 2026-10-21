// View ▸ Bar Prototype (temporary): both proportions keep the traffic lights
// equally inset left/top/bottom, put the Live Text button the same distance in
// from the right, and centre it on the lights' line. Compact keeps today's
// 28 pt bar; Standard is Finder's measured 52 pt bar.

import AppKit
import XCTest
@testable import PocketDeck

@MainActor
final class BarPrototypeTests: XCTestCase {
    private func makeManager() -> WindowManager {
        let name = "dev.pocketdeck.tests.bar.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        let session = Session(endpoint: .hostPort(host: "127.0.0.1", port: 1), knownDeviceId: nil,
                              clientId: "test-client")
        return WindowManager(session: session, defaults: defaults)
    }

    /// The numbers, without a window.
    func testBothPrototypesHaveEqualLightInsetsAndAMirroredLiveTextInset() {
        XCTAssertEqual(BarPrototype.compact.barHeight, 28)
        XCTAssertEqual(BarPrototype.compact.lightSide, 14)
        XCTAssertEqual(BarPrototype.compact.lightInset, 7)
        // Finder on macOS 26, measured 2026-10-21: 16 pt lights, 18 pt in.
        XCTAssertEqual(BarPrototype.standard.barHeight, 52)
        XCTAssertEqual(BarPrototype.standard.lightSide, 16)
        XCTAssertEqual(BarPrototype.standard.lightInset, 18)

        for prototype in BarPrototype.allCases {
            XCTAssertEqual(prototype.barHeight,
                           prototype.lightInset * 2 + prototype.lightSide,
                           "\(prototype): the bar is the lights plus the equal top/bottom insets")
            XCTAssertEqual(prototype.rightInset, prototype.lightInset,
                           "\(prototype): the Live Text button mirrors the lights' left inset")
            XCTAssertEqual(prototype.lightSpacing, 23, "Finder's measured spacing")
            XCTAssertEqual(prototype.liveTextSide, 28)
        }
    }

    /// The real view tree: the standard buttons and the Live Text button.
    func testTheBarPlacesTheLightsAndLiveTextForEachPrototype() throws {
        let saved = BarPrototype.current
        defer { BarPrototype.current = saved }

        for prototype in BarPrototype.allCases {
            // The manager reads the profile's stored prototype at init; set
            // the variant after it exists.
            let manager = makeManager()
            BarPrototype.current = prototype
            let app = AppWindowController(stream: 1, pkg: "com.example.app", activity: nil,
                                          label: "Example", manager: manager)
            defer { app.window?.close() }
            let window = try XCTUnwrap(app.window)
            window.orderFront(nil)
            app.chrome.layoutChrome()
            app.chrome.placeTrafficLights()
            let chrome = app.chrome
            let bar = chrome.barHeight
            XCTAssertEqual(bar, prototype.barHeight)

            let close = try XCTUnwrap(window.standardWindowButton(.closeButton))
            let light = chrome.convert(close.convert(close.bounds, to: nil), from: nil)
            let left = light.minX
            let top = window.frame.height - light.maxY
            let bottom = light.minY - (window.frame.height - bar)
            XCTAssertEqual(left, prototype.lightInset, accuracy: 1, "\(prototype): left inset")
            XCTAssertEqual(top, prototype.lightInset, accuracy: 1, "\(prototype): top inset")
            XCTAssertEqual(bottom, prototype.lightInset, accuracy: 1, "\(prototype): bottom inset")
            XCTAssertEqual(left, top, accuracy: 1, "\(prototype): left = top")
            XCTAssertEqual(top, bottom, accuracy: 1, "\(prototype): top = bottom")
            XCTAssertEqual(light.width, prototype.lightSide, accuracy: 0.5)

            let button = chrome.liveTextButton.frame
            XCTAssertEqual(button.width, prototype.liveTextSide, accuracy: 0.5)
            XCTAssertEqual(chrome.bounds.width - button.maxX, prototype.lightInset, accuracy: 1,
                           "\(prototype): the Live Text right inset is the lights' left inset")
            XCTAssertEqual(button.midY, light.midY, accuracy: 1,
                           "\(prototype): the button is centred on the lights' line")
        }
    }

    /// Switching prototypes grows the framed window at its top: the stream
    /// keeps its size and its top-left corner, only the bar gets taller.
    func testSwitchingPrototypesKeepsTheStreamAndTheTopEdge() throws {
        let manager = makeManager()
        BarPrototype.current = .compact
        manager.setBarPrototype(.compact)
        let app = manager.openApp(pkg: "com.example.app")
        defer { app.window?.close() }
        let window = try XCTUnwrap(app.window)
        window.orderFront(nil)
        app.chrome.layoutChrome()
        XCTAssertEqual(BarPrototype.current, .compact)
        let stream = app.videoView.frame.size
        let top = window.frame.maxY
        let height = window.frame.height

        manager.setBarPrototype(.standard)
        XCTAssertEqual(BarPrototype.current, .standard)
        XCTAssertEqual(app.chrome.barHeight, 52)
        XCTAssertEqual(app.videoView.frame.size, stream, "the stream keeps its size")
        XCTAssertEqual(window.frame.maxY, top, accuracy: 0.5, "the top edge stays")
        XCTAssertEqual(window.frame.height, height + 24, accuracy: 0.5, "the bar took the difference")

        manager.setBarPrototype(.compact)
        XCTAssertEqual(BarPrototype.current, .compact)
        XCTAssertEqual(app.videoView.frame.size, stream)
        XCTAssertEqual(window.frame.height, height, accuracy: 0.5)
    }
}
