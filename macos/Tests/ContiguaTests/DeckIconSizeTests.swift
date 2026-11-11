// The Deck's icon size as an explicit choice (DECK-6): ⌘+ / ⌘− step and ⌘0
// returns to the default, 125 %, but only while the Deck is the key window — a
// stream window's same keys belong to that window's density. Pure, so the key
// filter is tested without a window.

import AppKit
import XCTest
@testable import Contigua

final class DeckIconSizeTests: XCTestCase {
    private func action(_ keyCode: UInt16, _ flags: NSEvent.ModifierFlags = .command,
                        deckIsKey: Bool = true) -> DeckKeyZoom.Action? {
        DeckKeyZoom.action(keyCode: keyCode, flags: flags, deckIsKey: deckIsKey)
    }

    /// The keys the View ▸ Density items already name step the Deck's icon
    /// size: ⌘+ / ⌘− one 25 % step, ⌘0 back to the default.
    func testTheKeysStepTheDecksIconSize() {
        XCTAssertEqual(action(24), .step(DeckZoom.step), "⌘=")
        XCTAssertEqual(action(69), .step(DeckZoom.step), "keypad +")
        XCTAssertEqual(action(27), .step(-DeckZoom.step), "⌘-")
        XCTAssertEqual(action(78), .step(-DeckZoom.step), "keypad -")
        XCTAssertEqual(action(29), .reset, "⌘0")
        XCTAssertEqual(action(82), .reset, "keypad 0")
        XCTAssertNil(action(3), "⌘F is the Deck's Find, not a size key")
    }

    /// A stream window's ⌘+ / ⌘− / ⌘0 are its density: the Deck's stored icon
    /// size must not move when another window is key.
    func testTheKeysDoNothingWhenAStreamWindowIsKey() {
        for keyCode: UInt16 in [24, 69, 27, 78, 29, 82] {
            XCTAssertNil(action(keyCode, deckIsKey: false), "key \(keyCode) with a stream window key")
        }
    }

    /// Only the command chord: ⌥⌘+, ⌃⌘− and a bare = are not size keys.
    /// Shift stays allowed, because ⌘+ is ⇧⌘= on most keyboards.
    func testOtherChordsAndBareKeysAreIgnored() {
        XCTAssertNil(action(24, [.command, .option]))
        XCTAssertNil(action(27, [.command, .control]))
        XCTAssertNil(action(24, []), "a bare = is not a size key")
        XCTAssertEqual(action(24, [.command, .shift]), .step(DeckZoom.step), "⇧⌘=")
    }

    /// The four View ▸ Icon Size titles are the density style's percentages.
    func testTheMenuTitlesAreTheFourPercentages() {
        XCTAssertEqual(DeckZoom.options.map { MenuModel.iconSizeTitle($0) },
                       ["75 %", "100 %", "125 %", "150 %"])
    }

    /// [DECK-6] A profile with no stored choice shows the Deck at the default,
    /// 125 % ("make less dense the default"). Named through the constant; the
    /// percentage is pinned by the menu's own title below.
    func testAFreshProfileShowsTheDefaultIconSize() {
        let name = "deckzoom-fresh-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertEqual(DeckZoom.stored(in: defaults), DeckZoom.defaultValue,
                       "a profile with no stored choice is the default")
        XCTAssertEqual(MenuModel.iconSizeTitle(DeckZoom.defaultValue), "125 %")
    }

    /// [DECK-6] A stored choice is kept, an explicit 100 % included: the new
    /// default is not a migration.
    func testAStoredChoiceIsKept() {
        let name = "deckzoom-stored-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(1.0, forKey: DeckZoom.key)
        XCTAssertEqual(DeckZoom.stored(in: defaults), 1.0)
        defaults.set(0.75, forKey: DeckZoom.key)
        XCTAssertEqual(DeckZoom.stored(in: defaults), 0.75)
    }

    /// [DECK-6] ⌘0 returns to the default, 125 %, not to 100 %: the same key
    /// that used to mean Actual Size.
    func testCommandZeroReturnsToTheDefault() {
        XCTAssertEqual(DeckZoom.applied(.reset, to: 0.75), DeckZoom.defaultValue)
        XCTAssertEqual(DeckZoom.applied(.reset, to: 1.5), DeckZoom.defaultValue)
    }
}
