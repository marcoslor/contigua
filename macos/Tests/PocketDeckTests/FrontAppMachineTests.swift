// The foreground machine (docs/PROTOCOL.md "Foreground app", PANEL-26): a
// reply only moves the state while it is for the newest request, and a stale
// package never comes back after a link loss or a phone change.

import XCTest
@testable import PocketDeck

final class FrontAppMachineTests: XCTestCase {
    func testIdleUntilTheCardAsks() {
        var machine = FrontAppMachine()
        XCTAssertEqual(machine.state, .idle)
        XCTAssertNil(machine.pkg)
        XCTAssertFalse(machine.isNone)
        XCTAssertFalse(machine.reply(seq: 1, pkg: "com.example.maps"),
                       "a reply with no request is stale")
        XCTAssertEqual(machine.state, .idle)
    }

    func testAnAskedReplyMovesToKnownOrNone() {
        var known = FrontAppMachine()
        known.ask(seq: 4)
        XCTAssertEqual(known.state, .asking(seq: 4))
        XCTAssertTrue(known.reply(seq: 4, pkg: "com.example.maps"))
        XCTAssertEqual(known.state, .known(pkg: "com.example.maps"))
        XCTAssertEqual(known.pkg, "com.example.maps")
        XCTAssertFalse(known.isNone)

        var none = FrontAppMachine()
        none.ask(seq: 1)
        XCTAssertTrue(none.reply(seq: 1, pkg: nil))
        XCTAssertEqual(none.state, .none)
        XCTAssertNil(none.pkg)
        XCTAssertTrue(none.isNone)
    }

    func testAnOlderReplyIsIgnored() {
        var machine = FrontAppMachine()
        machine.ask(seq: 1)
        machine.ask(seq: 2)
        XCTAssertFalse(machine.reply(seq: 1, pkg: "com.example.maps"),
                       "the reply to the first request arrived after the second went out")
        XCTAssertEqual(machine.state, .asking(seq: 2))
        XCTAssertTrue(machine.reply(seq: 2, pkg: nil))
        XCTAssertEqual(machine.state, .none)
    }

    func testResetForgetsThePackageAndMakesAnInFlightReplyStale() {
        var machine = FrontAppMachine()
        machine.ask(seq: 1)
        machine.reply(seq: 1, pkg: "com.example.maps")
        machine.reset()
        XCTAssertEqual(machine.state, .idle)
        XCTAssertNil(machine.pkg)
        XCTAssertFalse(machine.reply(seq: 1, pkg: "com.example.maps"))
        XCTAssertEqual(machine.state, .idle)
    }

    func testFreshnessIsTheMenusTwoSeconds() {
        let now = Date(timeIntervalSinceReferenceDate: 1_000)
        XCTAssertFalse(FrontAppFreshness.isFresh(nil, now: now))
        XCTAssertTrue(FrontAppFreshness.isFresh(now.addingTimeInterval(-1.9), now: now))
        XCTAssertTrue(FrontAppFreshness.isFresh(now.addingTimeInterval(-2), now: now))
        XCTAssertFalse(FrontAppFreshness.isFresh(now.addingTimeInterval(-2.1), now: now))
    }

    func testTheRowNamesTheKnownAppAndFallsBackForAnUnknownPackage() {
        let known = FrontAppRow(pkg: "com.example.maps", label: "Maps", icon: nil)
        XCTAssertEqual(known.title, "Open Maps on Mac")
        XCTAssertEqual(known.help,
                       "Moves Maps from your phone's screen into its own Mac window, where you left off (⇧⌘C)")

        let unknown = FrontAppRow(pkg: "com.example.unknown", label: nil, icon: nil)
        XCTAssertEqual(unknown.title, "Open Current App on Mac")
        XCTAssertEqual(unknown.help, FrontAppRow.genericHelp)
        XCTAssertEqual(FrontAppRow.fallbackTitle, "Open Current App on Mac")
        XCTAssertEqual(FrontAppRow.nothingToOpen,
                       "Nothing to move. Your phone is showing its home screen or PocketDeck.")
    }
}
