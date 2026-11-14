// The menus' key-window machine (MENU-4, MENU-6, MENU-9, ISS-88): which window
// the stream-only menu items follow, and every transition between the two
// closed states. Only a stream window has per-window values; any other key
// window drops them whole.

import XCTest
@testable import Contigua

final class StreamMenuKeyTests: XCTestCase {
    private func values(stream: UInt32 = 1, style: WindowStyle = .framed,
                        liveText: Bool = false, frozen: Bool = false,
                        phoneWindow: Bool = false, densityPackage: String? = "com.example.app",
                        densityOverride: Double? = 1.25) -> StreamMenuValues {
        StreamMenuValues(stream: stream, style: style, liveText: liveText, frozen: frozen,
                         phoneWindow: phoneWindow, densityPackage: densityPackage,
                         densityOverride: densityOverride)
    }

    private func machineWithStreamKey() -> StreamMenuKeyMachine {
        var machine = StreamMenuKeyMachine()
        XCTAssertEqual(machine.handle(.streamBecameKey(values())), [.correctMenu])
        return machine
    }

    /// A stream window becoming key replaces whatever was there and asks for
    /// the menu's items to be corrected.
    func testAStreamWindowBecomingKeyCarriesItsValues() {
        var machine = StreamMenuKeyMachine()
        XCTAssertFalse(machine.hasStream)
        XCTAssertEqual(machine.handle(.streamBecameKey(values())), [.correctMenu])
        XCTAssertTrue(machine.hasStream)
        XCTAssertEqual(machine.values, values())
        XCTAssertEqual(machine.name, "stream key")
    }

    /// ISS-88: the Deck (or Settings, a sheet, the panel) becoming key is not
    /// a stream window, so every per-window value leaves with the last one.
    func testANonStreamKeyWindowDropsTheWholeSet() {
        var machine = machineWithStreamKey()
        XCTAssertEqual(machine.handle(.otherWindowBecameKey), [.correctMenu])
        XCTAssertFalse(machine.hasStream)
        XCTAssertNil(machine.values)
        XCTAssertEqual(machine.name, "no stream")
    }

    /// A late resign from another stream window never clears the window that
    /// is key: the event carries its stream id.
    func testAStreamResignDropsOnlyItsOwnWindow() {
        var machine = machineWithStreamKey()
        XCTAssertEqual(machine.handle(.streamResigned(stream: 2)), [])
        XCTAssertEqual(machine.values, values(), "another window's resign is not ours")
        XCTAssertEqual(machine.handle(.streamResigned(stream: 1)), [.correctMenu])
        XCTAssertNil(machine.values)
    }

    /// Key moving between stream windows (another window, or the same one
    /// again) replaces the values whole.
    func testAnotherStreamWindowReplacesTheValues() {
        var machine = machineWithStreamKey()
        let next = values(stream: 2, style: .compact, densityPackage: nil, densityOverride: nil)
        XCTAssertEqual(machine.handle(.streamBecameKey(next)), [.correctMenu])
        XCTAssertEqual(machine.values, next)
        XCTAssertEqual(machine.handle(.streamBecameKey(next)), [],
                       "the same key window twice is no change")
    }

    /// A value change on the key window follows; one from a window behind the
    /// Deck is ignored.
    func testValuesChangesFollowTheKeyWindowOnly() {
        var machine = machineWithStreamKey()
        let compact = values(style: .compact, liveText: true)
        XCTAssertEqual(machine.handle(.streamValuesChanged(compact)), [.correctMenu])
        XCTAssertEqual(machine.values, compact)
        XCTAssertEqual(machine.handle(.streamValuesChanged(compact)), [],
                       "the same values are no change")
        let behind = values(stream: 2, style: .compact)
        XCTAssertEqual(machine.handle(.streamValuesChanged(behind)), [])
        XCTAssertEqual(machine.values, compact, "the window behind the Deck cannot change the menu")
        XCTAssertEqual(machine.handle(.streamValuesChanged(values())), [.correctMenu])
    }

    /// Losing the app (the menu bar is not usable) and a reset both leave no
    /// key stream window; neither is a transition when there is none already.
    func testDeactivationAndResetDropWhatIsLeft() {
        var active = machineWithStreamKey()
        XCTAssertEqual(active.handle(.appDeactivated), [.correctMenu])
        XCTAssertFalse(active.hasStream)
        XCTAssertEqual(active.handle(.appDeactivated), [])

        var reset = machineWithStreamKey()
        XCTAssertEqual(reset.handle(.reset), [.correctMenu])
        XCTAssertFalse(reset.hasStream)
        XCTAssertEqual(reset.handle(.reset), [])
    }

    /// Every event that arrives with no stream key is ignored and asks for no
    /// correction, so a quiet Deck menu does not rewrite its items.
    func testIgnoredEventsLeaveTheStateAlone() {
        let ignored: [StreamMenuKeyMachine.Event] = [
            .streamValuesChanged(values()),
            .streamResigned(stream: 1),
            .otherWindowBecameKey,
            .appDeactivated,
            .reset,
        ]
        for event in ignored {
            var machine = StreamMenuKeyMachine()
            XCTAssertEqual(machine.handle(event), [], "\(event)")
            XCTAssertFalse(machine.hasStream)
        }
    }

    /// The log reads a closed state and event name, never a window's values.
    func testEveryTransitionHasANameForTheLog() {
        let events: [StreamMenuKeyMachine.Event] = [
            .streamBecameKey(values()), .streamValuesChanged(values()), .streamResigned(stream: 1),
            .otherWindowBecameKey, .appDeactivated, .reset,
        ]
        for event in events {
            XCTAssertFalse(StreamMenuKeyMachine.name(of: event).isEmpty)
        }
    }
}
