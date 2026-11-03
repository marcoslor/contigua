// Focus core: wanted state from the filter, menu and intent commands, and the
// stored values. The connect rule (the edge rule) is the shared control
// machine's, tested in ControlIntentTests.

import XCTest
@testable import PocketDeck

final class FocusCoreTests: XCTestCase {

    // MARK: Filter values

    func testNoFilterIsNotWanted() {
        XCTAssertNil(FocusFilterValues().wanted)
    }

    func testSilenceOffIsNotWanted() {
        var values = FocusFilterValues(enabled: true, silence: false, allow: .alarms)
        XCTAssertNil(values.wanted)
        values.silence = true
        XCTAssertEqual(values.wanted, .alarms)
    }

    func testAllowMapsToTheWireModes() {
        XCTAssertEqual(FocusAllow.priority.dnd, .priority)
        XCTAssertEqual(FocusAllow.alarms.dnd, .alarms)
        XCTAssertEqual(FocusAllow.nothing.dnd, .none)
    }

    func testEnabledFilterWithEachAllow() {
        for allow in FocusAllow.allCases {
            let values = FocusFilterValues(enabled: true, silence: true, allow: allow)
            XCTAssertEqual(values.wanted, allow.dnd)
        }
    }

    // MARK: Reconcile

    // The connect rule itself is the shared control machine's `connected`
    // transition (ControlIntentTests): it sends only what this phone has not
    // had, and a person's own change on the phone stands until the Mac intent
    // changes again. The old-phone skip is the controller's `phoneDnd` guard,
    // proved by the e2e `focus` check.

    // MARK: Menu and intent commands

    func testMenuTogglesBetweenPriorityAndOff() {
        XCTAssertEqual(FocusReconciler.menuCommand(current: .off), .priority)
        XCTAssertEqual(FocusReconciler.menuCommand(current: .priority), .off)
        XCTAssertEqual(FocusReconciler.menuCommand(current: .alarms), .off)
        XCTAssertEqual(FocusReconciler.menuCommand(current: PhoneDndMode.none), .off)
    }

    func testMenuWithoutDndDoesNothing() {
        XCTAssertNil(FocusReconciler.menuCommand(current: nil))
    }

    func testIntentCommand() {
        XCTAssertEqual(FocusReconciler.intentCommand(on: true, mode: .alarms), .alarms)
        XCTAssertEqual(FocusReconciler.intentCommand(on: true, mode: PhoneDndMode.none), PhoneDndMode.none)
        XCTAssertEqual(FocusReconciler.intentCommand(on: false, mode: .alarms), .off)
        // "on" with the off sentinel still asks for the default mode.
        XCTAssertEqual(FocusReconciler.intentCommand(on: true, mode: .off), .priority)
    }

    // MARK: Debug hooks

    func testDebugFilterParsing() {
        XCTAssertEqual(FocusDebugCommand.parseFilter("on"), FocusFilterValues(enabled: true))
        XCTAssertEqual(FocusDebugCommand.parseFilter("on priority"), FocusFilterValues(enabled: true))
        XCTAssertEqual(FocusDebugCommand.parseFilter("ON alarms"),
                       FocusFilterValues(enabled: true, silence: true, allow: .alarms))
        XCTAssertEqual(FocusDebugCommand.parseFilter("on none"),
                       FocusFilterValues(enabled: true, silence: true, allow: .nothing))
        XCTAssertEqual(FocusDebugCommand.parseFilter("off"),
                       FocusFilterValues(enabled: false, silence: true, allow: .priority))
    }

    func testDebugFilterRejectsGarbage() {
        XCTAssertNil(FocusDebugCommand.parseFilter(""))
        XCTAssertNil(FocusDebugCommand.parseFilter("on loud"))
        XCTAssertNil(FocusDebugCommand.parseFilter("off priority"))
        XCTAssertNil(FocusDebugCommand.parseFilter("maybe"))
    }

    func testDebugDndParsing() {
        XCTAssertEqual(FocusDebugCommand.parseDnd("on"), true)
        XCTAssertEqual(FocusDebugCommand.parseDnd(" OFF "), false)
        XCTAssertNil(FocusDebugCommand.parseDnd("toggle"))
    }

    // MARK: Store

    func testStoreRoundTrip() {
        let suite = "focus-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = FocusStore(defaults: defaults)
        XCTAssertEqual(store.load(), FocusFilterValues())

        let values = FocusFilterValues(enabled: true, silence: true, allow: .nothing)
        store.save(values)
        XCTAssertEqual(store.load(), values)

        store.clear()
        XCTAssertEqual(store.load(), FocusFilterValues())
    }
}
