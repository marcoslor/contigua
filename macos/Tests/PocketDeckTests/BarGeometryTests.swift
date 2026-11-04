// The framed bar's geometry: the traffic lights equally inset left/top/bottom,
// the Live Text button the same distance in from the right, centred on the
// lights' line.

import AppKit
import XCTest
@testable import PocketDeck

@MainActor
final class BarGeometryTests: XCTestCase {
    private func makeManager() -> WindowManager {
        let name = "dev.pocketdeck.tests.bar.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        let session = Session(endpoint: .hostPort(host: "127.0.0.1", port: 1), knownDeviceId: nil,
                              clientId: "test-client")
        return WindowManager(session: session, defaults: defaults)
    }

    /// The numbers, without a window.
    func testTheBarIsTheLightsPlusEqualInsets() {
        XCTAssertEqual(BarGeometry.barHeight, 28)
        XCTAssertEqual(BarGeometry.lightSide, 14)
        XCTAssertEqual(BarGeometry.lightInset, 7)
        XCTAssertEqual(BarGeometry.lightSpacing, 23)
        XCTAssertEqual(BarGeometry.liveTextSide, 28)
        XCTAssertEqual(BarGeometry.rightInset, BarGeometry.lightInset,
                       "the Live Text button mirrors the lights' left inset")
        XCTAssertEqual(BarGeometry.barHeight,
                       BarGeometry.lightInset * 2 + BarGeometry.lightSide,
                       "the bar is the lights plus the equal top/bottom insets")
    }

    /// The real view tree: the standard buttons and the Live Text button.
    func testTheBarPlacesTheLightsAndLiveText() throws {
        let manager = makeManager()
        let app = AppWindowController(stream: 1, pkg: "com.example.app", activity: nil,
                                      label: "Example", manager: manager)
        defer { app.window?.close() }
        let window = try XCTUnwrap(app.window)
        window.orderFront(nil)
        app.noteFirstFrame()
        app.chrome.layoutChrome()
        app.chrome.placeTrafficLights()
        let chrome = app.chrome
        XCTAssertEqual(chrome.barHeight, BarGeometry.barHeight)

        let close = try XCTUnwrap(window.standardWindowButton(.closeButton))
        let light = chrome.convert(close.convert(close.bounds, to: nil), from: nil)
        let left = light.minX
        let top = window.frame.height - light.maxY
        let bottom = light.minY - (window.frame.height - chrome.barHeight)
        XCTAssertEqual(left, BarGeometry.lightInset, accuracy: 1, "left inset")
        XCTAssertEqual(top, BarGeometry.lightInset, accuracy: 1, "top inset")
        XCTAssertEqual(bottom, BarGeometry.lightInset, accuracy: 1, "bottom inset")
        XCTAssertEqual(light.width, BarGeometry.lightSide, accuracy: 0.5)

        let button = chrome.liveTextButton.frame
        XCTAssertEqual(button.width, BarGeometry.liveTextSide, accuracy: 0.5)
        XCTAssertEqual(chrome.bounds.width - button.maxX, BarGeometry.rightInset, accuracy: 1,
                       "the Live Text right inset is the lights' left inset")
        XCTAssertEqual(button.midY, light.midY, accuracy: 1,
                       "the button is centred on the lights' line")
    }
}
