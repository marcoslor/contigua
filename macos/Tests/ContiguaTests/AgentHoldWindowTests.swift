// MCP-22 on a real window controller: the agent hold wins over a minimise, the
// path that paused without asking StreamPause (e2e suite_screen.py found it).

import AppKit
import XCTest
@testable import Contigua

@MainActor
final class AgentHoldWindowTests: XCTestCase {
    /// The controller holds its manager unowned: the test keeps it alive.
    private var manager: WindowManager?

    private func makeController() -> AppWindowController {
        let name = "app.contigua.tests.agenthold.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        let session = Session(endpoint: .hostPort(host: "127.0.0.1", port: 1), knownDeviceId: nil,
                              clientId: "test-client")
        let manager = WindowManager(session: session, defaults: defaults)
        self.manager = manager
        return AppWindowController(stream: 1, pkg: "com.example.app", activity: nil,
                                   label: "Example", manager: manager)
    }

    // [MCP-22] A window minimised while an agent holds it keeps streaming.
    func testAMinimiseDuringAHoldDoesNotPause() throws {
        let controller = makeController()
        defer { controller.window?.close() }
        controller.agentCalled(at: ProcessInfo.processInfo.systemUptime)
        XCTAssertFalse(controller.isPaused)
        controller.windowDidMiniaturize(Notification(name: NSWindow.didMiniaturizeNotification))
        XCTAssertFalse(controller.isPaused, "the hold wins over a minimise")
    }

    // [MCP-22] The watchdog's tick at the hold's end re-decides pause by WIN's
    // rule: a minimised window pauses again.
    func testTheHoldsEndPausesAMinimisedWindow() throws {
        let controller = makeController()
        defer { controller.window?.close() }
        let start = ProcessInfo.processInfo.systemUptime
        controller.agentCalled(at: start)
        controller.windowDidMiniaturize(Notification(name: NSWindow.didMiniaturizeNotification))
        controller.tickFrameWatchdog(at: start + 14.9)
        XCTAssertFalse(controller.isPaused, "still held before the end")
        controller.tickFrameWatchdog(at: start + AgentHold.holdSeconds)
        XCTAssertTrue(controller.isPaused, "the hold's end pauses a minimised window")
        XCTAssertEqual(controller.agentHold, .released)
    }
}
