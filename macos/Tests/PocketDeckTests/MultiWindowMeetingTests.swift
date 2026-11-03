// Where main's behaviour and this branch's several windows of one app meet
// (ISS-4): the Dock shim across an app's windows (dock-race × WIN-26), the
// disconnection overlay and the New items (WIN-34 × main's overlay), and a
// targeted drop from any of the app's windows (SHARE-17).

import AppKit
import XCTest
@testable import PocketDeck

@MainActor
final class MultiWindowMeetingTests: XCTestCase {
    private var fixture: MultiWindowFixture!

    override func setUp() {
        super.setUp()
        fixture = MultiWindowFixture()
    }

    override func tearDown() {
        fixture.closeAll()
        fixture = nil
        super.tearDown()
    }

    // MARK: The Dock shim with several windows (dock-race × WIN-26)

    private func dockApps() -> (DockApps, () -> Void) {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("dock-follow-\(UUID().uuidString)")
        let apps = DockApps(folder: folder, profile: Profile(name: "e2e")!)
        return (apps, { try? FileManager.default.removeItem(at: folder) })
    }

    /// One shim serves the app: closing one of its windows moves the identity to
    /// the window that is still open instead of taking the Dock icon away.
    func testClosingOneOfTwoWindowsKeepsTheAppsShim() throws {
        let (apps, cleanUp) = dockApps()
        defer { cleanUp() }
        let first = fixture.open(taskLabel: "Docs")
        let second = try XCTUnwrap(fixture.add(taskLabel: "Mail"))

        let next = DockWindowFollow.survivor(closing: first.stream,
                                             pkg: MultiWindowFixture.chrome.pkg,
                                             windows: fixture.manager.openAppWindows)
        XCTAssertEqual(second.stream, next, "the shim follows the app's other window")

        let pid = Int(getpid())
        apps.bind(pid: pid, stream: first.stream, pkg: MultiWindowFixture.chrome.pkg)
        apps.rebind(pid: pid, to: try XCTUnwrap(next))
        XCTAssertEqual(second.stream, apps.stream(forPid: pid))
        XCTAssertNil(apps.binding(stream: first.stream))
        XCTAssertEqual([second.stream], Array(apps.boundStreams),
                       "the app's shim is still there, standing for its other window")
    }

    /// Closing the app's last window lets the shim go, as it did before several
    /// windows existed.
    func testClosingTheAppsLastWindowQuitsItsShim() throws {
        let (apps, cleanUp) = dockApps()
        defer { cleanUp() }
        let only = fixture.open(taskLabel: "Docs")

        XCTAssertNil(DockWindowFollow.survivor(closing: only.stream,
                                               pkg: MultiWindowFixture.chrome.pkg,
                                               windows: fixture.manager.openAppWindows),
                     "the app has no other window for the shim to stand for")

        let pid = Int(getpid())
        apps.bind(pid: pid, stream: only.stream, pkg: MultiWindowFixture.chrome.pkg)
        apps.streamClosed(only.stream)
        XCTAssertNil(apps.binding(stream: only.stream))
        XCTAssertTrue(apps.boundStreams.isEmpty, "the shim is told to exit with no window")
    }

    /// Another app's window is not a survivor: the shim belongs to one app.
    func testAnotherAppsWindowDoesNotKeepTheShim() {
        _ = fixture.open(taskLabel: "Docs")
        _ = fixture.open(MultiWindowFixture.settings)
        XCTAssertNil(DockWindowFollow.survivor(closing: 1, pkg: MultiWindowFixture.chrome.pkg,
                                               windows: fixture.manager.openAppWindows))
    }

    // MARK: The disconnection overlay (WIN-34 × main's overlay)

    /// The link drops: every window of the app wears main's overlay, and the
    /// New items say "Reconnecting…" and then "Phone offline" (WIN-16).
    func testEveryWindowShowsTheOverlayAndTheNewItemsFollowThePhase() throws {
        let first = fixture.open(taskLabel: "Docs")
        let second = try XCTUnwrap(fixture.add(taskLabel: "Mail"))
        let t0 = ProcessInfo.processInfo.systemUptime

        fixture.manager.linkLost(at: t0)
        XCTAssertEqual(fixture.manager.linkPhase, .reconnecting)
        XCTAssertEqual(fixture.manager.newWindowItem(for: MultiWindowFixture.chrome.pkg).help,
                       "Reconnecting…")
        for window in [first, second] {
            XCTAssertFalse(window.chrome.stallOverlay.isShowing,
                           "the first second of a drop says nothing")
            window.tickPicture(at: t0 + 1)
            XCTAssertTrue(window.chrome.stallOverlay.isShowing, "stream \(window.stream)")
            XCTAssertEqual(window.chrome.stallOverlay.titleText, "Reconnecting…")
        }

        fixture.manager.linkPhaseTicked(at: t0 + 15)
        XCTAssertEqual(fixture.manager.newWindowItem(for: MultiWindowFixture.chrome.pkg).help,
                       "Phone offline")
        for window in [first, second] {
            window.tickPicture(at: t0 + 15)
            XCTAssertTrue(window.chrome.stallOverlay.isShowing, "stream \(window.stream)")
            XCTAssertEqual(window.chrome.stallOverlay.titleText, "Phone offline")
        }

        fixture.manager.linkRestored()
        XCTAssertNil(fixture.manager.newWindowItem(for: MultiWindowFixture.chrome.pkg).help)
        for window in [first, second] {
            XCTAssertFalse(window.chrome.stallOverlay.isShowing,
                           "the reconnect takes every overlay away")
        }
    }

    // MARK: The targeted drop (SHARE-17)

    /// A drop on any of the app's windows shares straight to that app, once for
    /// the gesture, whichever window it landed on.
    func testADropOnTheSecondWindowSharesToTheAppOnce() throws {
        fixture.open(taskLabel: "Docs")
        let second = try XCTUnwrap(fixture.add(taskLabel: "Mail"))
        var calls: [(urls: [URL], target: String?)] = []
        fixture.manager.onFilesDropped = { urls, target in calls.append((urls, target)) }

        let url = URL(fileURLWithPath: "/tmp/report.pdf")
        second.videoView.onDroppedFiles?([url])
        XCTAssertEqual(1, calls.count, "one gesture, one share")
        XCTAssertEqual([url], calls.first?.urls)
        XCTAssertEqual(MultiWindowFixture.chrome.pkg, calls.first?.target,
                       "the share lands on the app the window shows")
    }
}
