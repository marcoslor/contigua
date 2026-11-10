// BP-09/R4: the controller's link reconcile, not just the Link value. A
// window must stay down on a pairing failure: needsPairing/pairing/connecting
// are not "down", but they are no live session either.

import AppKit
import XCTest
@testable import PocketDeck

@MainActor
final class ConnectionLinkReconcileTests: XCTestCase {
    private var controller: ConnectionController!
    private var profile: Profile!
    private var window: AppWindowController!
    private let phone = PhoneRef(id: "aaa", name: "Pixel 9", model: "Pixel 9")

    override func setUp() async throws {
        profile = Profile(name: "unit-reconcile-\(UUID().uuidString.prefix(8).lowercased())")!
        controller = ConnectionController(options: LaunchOptions.parse(["PocketDeck"]), profile: profile)
        controller.machine = LinkMachine(link: .online(phone))
        window = AppWindowController(stream: 1, pkg: "com.example.app", activity: nil,
                                     label: "Example", manager: controller.windows)
        controller.windows.registerForTesting(window, stream: 1)
        window.window?.orderFront(nil)
    }

    override func tearDown() async throws {
        window.window?.close()
        controller.shutdown()
        if let suite = profile.defaultsSuiteName {
            profile.defaults.removePersistentDomain(forName: suite)
        }
        try? FileManager.default.removeItem(at: profile.supportDirectoryUrl)
    }

    /// The regression: the old `!isDown -> restore` condition called
    /// `linkRestored()` here and put a live window over no session.
    func testAPairingFailureLeavesTheWindowDown() {
        let states: [Link] = [
            .needsPairing(phone),
            .pairing(phone, .contacting),
            .connecting(phone),
        ]
        for state in states {
            controller.machine = LinkMachine(link: .online(phone))
            controller.windows.linkRestored()
            XCTAssertFalse(window.isLinkDown, "\(state): setup")

            controller.windows.linkLost()
            XCTAssertTrue(window.isLinkDown, "\(state): the one-shot linkLost ran")
            controller.machine = LinkMachine(link: state)
            controller.apply(PhoneBookEventResult(affectsCurrent: true))
            XCTAssertTrue(window.isLinkDown, "\(state) must not restore the window")
        }
    }

    func testAnOnlineLinkRestoresTheWindow() {
        controller.windows.linkLost()
        XCTAssertTrue(window.isLinkDown)
        controller.machine = LinkMachine(link: .online(phone))
        controller.apply(PhoneBookEventResult(affectsCurrent: true))
        XCTAssertFalse(window.isLinkDown)
    }

    func testAnOfflineLinkReconcilesAWindowThatMissedTheBroadcast() {
        // A window that opened after the one-shot broadcast: the per-window
        // reconcile still marks it down.
        controller.machine = LinkMachine(link: .offline(phone, .unreachable))
        XCTAssertFalse(window.isLinkDown)
        controller.apply(PhoneBookEventResult(affectsCurrent: true))
        XCTAssertTrue(window.isLinkDown)
    }
}
