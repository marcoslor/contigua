// The Deck's frame across launches (DECK-19, CONV-MAC-12): one pure function
// over screen frames decides where it opens, the pattern SettingsPlacement uses
// (SET-WIN-09). The tests pin each rule the brief names: a stored frame that
// fits comes back, one that is on no screen is centred, and neither is ever
// larger than the screen it opens on.

import AppKit
import XCTest
@testable import PocketDeck

final class DeckPlacementTests: XCTestCase {
    private let screen = CGRect(x: 0, y: 0, width: 1280, height: 800)
    private let minimum = CGSize(width: 640, height: 420)

    func testNoStoredFrameOpensAtTheDefaultCentred() {
        let frame = DeckPlacement.frame(saved: nil, screens: [screen], visible: [screen], minimum: minimum)
        XCTAssertEqual(frame.size, CGSize(width: 760, height: 600))
        XCTAssertEqual(frame.origin, DeckPlacement.centred(frame.size, in: screen).origin)
    }

    func testAStoredFrameThatFitsComesBackExactly() {
        let saved = CGRect(x: 100, y: 20, width: 1000, height: 770)
        let frame = DeckPlacement.frame(saved: saved, screens: [screen], visible: [screen], minimum: minimum)
        XCTAssertEqual(frame, saved)
    }

    /// A second display was unplugged: the stored frame is on no screen now, so
    /// the Deck opens centred on the home screen with the size the person chose
    /// (as long as the home screen can hold it).
    func testAFrameOnNoScreenOpensCentredWithItsSize() {
        let saved = CGRect(x: 4000, y: 4000, width: 900, height: 700)
        let frame = DeckPlacement.frame(saved: saved, screens: [screen], visible: [screen], minimum: minimum)
        XCTAssertEqual(frame.size, CGSize(width: 900, height: 700))
        XCTAssertEqual(frame, DeckPlacement.centred(CGSize(width: 900, height: 700), in: screen))
    }

    /// A frame that fits on the second screen stays there: the home screen only
    /// decides where a lost frame goes.
    func testAFrameOnAnotherScreenStaysThere() {
        let second = CGRect(x: 1280, y: 0, width: 1920, height: 1080)
        let saved = CGRect(x: 1400, y: 100, width: 800, height: 600)
        let frame = DeckPlacement.frame(saved: saved, screens: [screen, second], visible: [screen, second], minimum: minimum)
        XCTAssertEqual(frame, saved)
    }

    /// A window that stands outside the visible frame but on its screen still
    /// stands on it: a person (or AppKit's own constraint) left the Deck there,
    /// so it comes back there, not centred. The quiet e2e's virtual display
    /// keeps a 30 pt strip at its top out of the visible frame, and AppKit lets
    /// the window's top reach the screen's top there.
    func testAFrameUnderTheDockComesBack() {
        let full = CGRect(x: 1440, y: 100, width: 1280, height: 800)
        let visible = CGRect(x: 1440, y: 100, width: 1280, height: 770)
        let saved = CGRect(x: 1700, y: 200, width: 1000, height: 700)
        XCTAssertFalse(visible.contains(saved), "the frame reaches under the Dock")
        let frame = DeckPlacement.frame(saved: saved, screens: [full], visible: [visible],
                                        minimum: minimum)
        XCTAssertEqual(frame, saved)
    }

    func testAFrameLargerThanTheScreenIsShrunkAndCentred() {
        let saved = CGRect(x: -400, y: -300, width: 3000, height: 2000)
        let frame = DeckPlacement.frame(saved: saved, screens: [screen], visible: [screen], minimum: minimum)
        XCTAssertEqual(frame.size, screen.size, "never larger than the screen")
        XCTAssertEqual(frame, screen)
    }

    /// A stored frame below the Deck's minimum is raised to it where it stands:
    /// the window's minimum is the layout's floor (DECK-19).
    func testTheMinimumWinsOverATinyStoredFrame() {
        let saved = CGRect(x: 10, y: 10, width: 200, height: 100)
        let frame = DeckPlacement.frame(saved: saved, screens: [screen], visible: [screen], minimum: minimum)
        XCTAssertEqual(frame, CGRect(x: 10, y: 10, width: 640, height: 420))
    }

    /// The store is four numbers, per profile. Anything else is no frame at all,
    /// so a stale value opens the default instead of a broken window.
    func testTheStoredFrameRoundTripsAndGarbageIsNoFrame() {
        let name = "deck-placement-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertNil(DeckPlacement.saved(in: defaults))
        let frame = CGRect(x: 120, y: 240, width: 1000, height: 770)
        DeckPlacement.save(frame, in: defaults)
        XCTAssertEqual(DeckPlacement.saved(in: defaults), frame)
        for junk in ["", "1000,770", "a,b,c,d", "0,0,0,0", "1,2,3"] {
            defaults.set(junk, forKey: DeckPlacement.frameKey)
            XCTAssertNil(DeckPlacement.saved(in: defaults), "junk: \(junk)")
        }
    }
}
