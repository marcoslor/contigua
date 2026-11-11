// The menu's snapshot and the gate that keeps SwiftUI from rebuilding items
// while a menu tracks (the 10-27 report: a submenu that kept closing under the
// pointer). What a menu shows is a small value; everything else the controller
// publishes must not reach the commands.

import XCTest
@testable import Contigua

final class MenuSnapshotTests: XCTestCase {
    private func stream(style: WindowStyle = .immersive, showTouches: Bool = true,
                        frozen: Bool = false, liveText: Bool = false,
                        package: String? = "com.example.app",
                        density: Double? = 1.25) -> StreamMenuState {
        let state = StreamMenuState()
        state.handle(.streamBecameKey(StreamMenuValues(
            stream: 1, style: style, liveText: liveText, frozen: frozen,
            densityPackage: package, densityOverride: density)))
        state.showTouches = showTouches
        return state
    }

    private func phone() -> PhoneControlsState {
        var state = PhoneControlsState()
        state.connection = .online
        state.phoneName = "Test Phone"
        state.battery = 87
        state.charging = false
        state.volume = 6
        state.volumeMax = 15
        state.media = MediaState(playing: true, pkg: "com.example.player")
        state.liveTick = Date()
        return state
    }

    // MARK: What the menu shows

    func testTheSnapshotCarriesTheValuesTheItemsRead() {
        let state = stream()
        let snapshot = MenuSnapshot(stream: state, phone: MenuSnapshot.Phone(phone()))
        XCTAssertTrue(snapshot.hasStream)
        XCTAssertEqual(snapshot.style, .immersive)
        XCTAssertTrue(snapshot.showTouches)
        XCTAssertEqual(snapshot.densityPackage, "com.example.app")
        XCTAssertEqual(snapshot.densityOverride, 1.25)
        XCTAssertEqual(snapshot.settingsDensity, 1.0)
        XCTAssertTrue(snapshot.phone.mirrorEnabled, "an online phone can mirror")
    }

    /// The person's suspects: a battery report, a Now Playing change, the live
    /// tick and a stall flip are not menu values, so none of them may reach the
    /// commands as a new snapshot.
    func testAChangeTheMenuDoesNotShowLeavesTheSnapshotEqual() {
        let reference = MenuSnapshot(stream: stream(), phone: MenuSnapshot.Phone(phone()))
        var moved = phone()
        moved.battery = 42
        moved.charging = true
        moved.volume = 12
        moved.liveTick = Date().addingTimeInterval(30)
        moved.media = MediaState(playing: false, pkg: "com.example.other", positionMs: 9000)
        moved.live = []
        XCTAssertEqual(MenuSnapshot(stream: stream(), phone: MenuSnapshot.Phone(moved)), reference)

        let stalled = stream(frozen: false)
        XCTAssertEqual(MenuSnapshot(stream: stalled, phone: MenuSnapshot.Phone(moved)), reference)
    }

    func testAChangeTheMenuDoesShowIsANewSnapshot() {
        let reference = MenuSnapshot(stream: stream(), phone: MenuSnapshot.Phone(phone()))
        let other = stream(style: .framed)
        XCTAssertNotEqual(MenuSnapshot(stream: other, phone: MenuSnapshot.Phone(phone())), reference)

        var ringing = phone()
        ringing.ringing = true
        XCTAssertNotEqual(MenuSnapshot(stream: stream(), phone: MenuSnapshot.Phone(ringing)), reference,
                          "Ring Phone reads Stop Ringing while it rings")

        var offline = phone()
        offline.connection = .offline
        XCTAssertNotEqual(MenuSnapshot(stream: stream(), phone: MenuSnapshot.Phone(offline)), reference,
                          "the Phone items disable with the link")
    }

    func testThePhoneBlockIsThePanelsOwnMapping() {
        var state = PhoneControlsState()
        state.connection = .idle
        let idle = MenuSnapshot.Phone(state)
        XCTAssertFalse(idle.mirrorEnabled)
        XCTAssertFalse(idle.installEnabled)
        state.connection = .online
        let online = MenuSnapshot.Phone(state)
        XCTAssertTrue(online.mirrorEnabled)
        XCTAssertEqual(online.ringTitle, "Ring Phone")
        XCTAssertEqual(online.installTitle, "Install APK…")
    }

    // MARK: When a snapshot may reach the commands

    func testAChangeOutsideATrackedMenuIsPublishedAtOnce() {
        var gate = MenuSnapshotGate()
        let a = MenuSnapshot()
        XCTAssertEqual(gate.update(a), a)
        XCTAssertEqual(gate.update(a), nil, "the same value is no change")
        var b = MenuSnapshot()
        b.frozen = true
        XCTAssertEqual(gate.update(b), b)
    }

    func testAChangeWhileAMenuTracksWaitsForItToClose() {
        var gate = MenuSnapshotGate()
        let a = MenuSnapshot()
        _ = gate.update(a)
        _ = gate.tracking(true)
        var b = MenuSnapshot()
        b.style = .framed
        XCTAssertNil(gate.update(b), "nothing may rebuild the items under the pointer")
        XCTAssertEqual(gate.applied, a)
        XCTAssertEqual(gate.tracking(false), b, "and it lands when the menu closes")
        XCTAssertEqual(gate.applied, b)
    }

    func testOnlyTheLatestWaitingValueLands() {
        var gate = MenuSnapshotGate()
        _ = gate.update(MenuSnapshot())
        _ = gate.tracking(true)
        var first = MenuSnapshot()
        first.showTouches = true
        var last = MenuSnapshot()
        last.liveText = true
        XCTAssertNil(gate.update(first))
        XCTAssertNil(gate.update(last))
        XCTAssertEqual(gate.tracking(false), last)
    }

    func testAValueThatComesBackToWhatIsShownPublishesNothing() {
        var gate = MenuSnapshotGate()
        let a = MenuSnapshot()
        _ = gate.update(a)
        _ = gate.tracking(true)
        var b = MenuSnapshot()
        b.frozen = true
        XCTAssertNil(gate.update(b))
        XCTAssertNil(gate.update(a), "back to the built value: nothing to rebuild")
        XCTAssertNil(gate.tracking(false))
    }

    func testTrackingWithNoChangeIsQuiet() {
        var gate = MenuSnapshotGate()
        let a = MenuSnapshot()
        _ = gate.update(a)
        _ = gate.tracking(true)
        XCTAssertNil(gate.tracking(false))
        XCTAssertEqual(gate.applied, a)
    }
}

final class StreamPauseTests: XCTestCase {
    private func pause(miniaturized: Bool = false, key: Bool = false, main: Bool = false,
                       visible: Bool = false, menu: Bool = false) -> Bool {
        StreamPause.shouldPause(miniaturized: miniaturized, key: key, main: main,
                                occludedVisible: visible, menuTracking: menu)
    }

    func testACoveredWindowPauses() {
        XCTAssertTrue(pause(visible: false))
        XCTAssertFalse(pause(visible: true))
    }

    func testAMenuOverTheWindowNeverPausesIt() {
        XCTAssertFalse(pause(visible: false, menu: true),
                       "the menu is what covers us; it is not a reason to stop the stream")
        XCTAssertFalse(pause(key: false, main: false, visible: false, menu: true))
    }

    func testAKeyOrMainWindowNeverPauses() {
        XCTAssertFalse(pause(key: true))
        XCTAssertFalse(pause(main: true))
    }

    func testAMinimisedWindowStillPausesWhileAMenuTracks() {
        XCTAssertTrue(pause(miniaturized: true, menu: true))
    }
}
