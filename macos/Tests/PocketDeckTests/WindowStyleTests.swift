// The two window styles, their storage, the sizes and frames they ask for, the
// immersive dwell and the reveal delay. All pure logic — the views are
// exercised in the e2e check (C14).

import AppKit
import XCTest
@testable import PocketDeck

final class WindowStyleStorageTests: XCTestCase {
    private func makeDefaults() -> UserDefaults {
        let name = "dev.pocketdeck.tests.style.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        return defaults
    }

    func testAnAppWithNoStoredChoiceOpensFramed() {
        let store = WindowStyleStore(defaults: makeDefaults())
        XCTAssertEqual(store.style(forKey: WindowStyleStore.key(forPackage: "com.example.app")), .framed)
        XCTAssertEqual(WindowStyle.standard, .framed)
    }

    func testTheChoiceIsRememberedPerPackage() {
        let defaults = makeDefaults()
        let store = WindowStyleStore(defaults: defaults)
        let inbox = WindowStyleStore.key(forPackage: "com.example.inbox")
        let maps = WindowStyleStore.key(forPackage: "com.example.maps")
        store.set(.immersive, forKey: inbox)
        XCTAssertEqual(store.style(forKey: inbox), .immersive)
        XCTAssertEqual(store.style(forKey: maps), .framed, "another app keeps its own choice")
        store.set(.framed, forKey: inbox)
        XCTAssertEqual(store.style(forKey: inbox), .framed)
    }

    func testTheKeysAreThePackagesAndThePhoneHasItsOwn() {
        XCTAssertEqual(WindowStyleStore.key(forPackage: "com.android.settings"), "chrome.style.com.android.settings")
        XCTAssertEqual(WindowStyleStore.key(forPackage: "com.example.app"), "chrome.style.com.example.app")
        XCTAssertEqual(WindowStyleStore.key(forPackage: nil), "chrome.style.phone")
        XCTAssertEqual(WindowStyleStore.key(forPackage: ""), "chrome.style.phone")
        XCTAssertEqual(WindowStyleStore.phoneKey, "chrome.style.phone")
    }

    func testThePhoneWindowsChoiceLivesUnderItsOwnKey() {
        let store = WindowStyleStore(defaults: makeDefaults())
        store.set(.immersive, forKey: WindowStyleStore.phoneKey)
        XCTAssertEqual(store.style(forKey: WindowStyleStore.phoneKey), .immersive)
        XCTAssertEqual(store.style(forKey: WindowStyleStore.key(forPackage: "com.example.app")), .framed)
    }

    func testAnUnreadableStoredValueFallsBackToFramed() {
        let defaults = makeDefaults()
        defaults.set("sideways", forKey: WindowStyleStore.key(forPackage: "com.example.app"))
        XCTAssertEqual(WindowStyleStore(defaults: defaults).style(forKey: WindowStyleStore.key(forPackage: "com.example.app")),
                       .framed)
    }

    func testAWindowWithNothingToRememberStoresNothing() {
        let defaults = makeDefaults()
        let store = WindowStyleStore(defaults: defaults)
        store.set(.immersive, forKey: nil)
        XCTAssertNil(defaults.string(forKey: WindowStyleStore.phoneKey))
        XCTAssertEqual(store.style(forKey: nil), .framed)
    }
}

final class WindowStyleSizeTests: XCTestCase {
    private let stream = CGSize(width: 900, height: 600)
    private let screen = NSRect(x: 0, y: 25, width: 1440, height: 875)

    func testFramedIsTheStreamPlusTheBar() {
        XCTAssertEqual(WindowStyle.framed.windowSize(stream: stream), CGSize(width: 900, height: 628))
        let pad = WindowStyle.framed.insets(fullScreen: false)
        XCTAssertEqual([pad.top, pad.left, pad.bottom, pad.right], [28, 0, 0, 0], "the bar at the top only")
    }

    func testImmersiveIsTheStreamExactly() {
        XCTAssertEqual(WindowStyle.immersive.windowSize(stream: stream), stream)
        let pad = WindowStyle.immersive.insets(fullScreen: false)
        XCTAssertEqual([pad.top, pad.left, pad.bottom, pad.right], [0, 0, 0, 0])
    }

    func testFullScreenHasNoBarInEitherStyle() {
        XCTAssertEqual(WindowStyle.framed.windowSize(stream: stream, fullScreen: true), stream)
        XCTAssertEqual(WindowStyle.immersive.windowSize(stream: stream, fullScreen: true), stream)
    }

    func testTheStreamSizeIsTheWindowSizeWithoutTheBar() {
        XCTAssertEqual(WindowStyle.framed.streamSize(window: CGSize(width: 900, height: 628)), stream)
        XCTAssertEqual(WindowStyle.immersive.streamSize(window: CGSize(width: 900, height: 600)), stream)
        XCTAssertEqual(WindowStyle.framed.streamSize(window: CGSize(width: 900, height: 600), fullScreen: true), stream)
        XCTAssertEqual(WindowStyle.framed.streamSize(window: CGSize(width: 900, height: 20)), CGSize(width: 900, height: 0),
                       "never negative")
    }

    func testTheBarNeverChangesTheStreamsWidthOrFullScreenSize() {
        for style in WindowStyle.allCases {
            XCTAssertEqual(style.windowSize(stream: stream).width, stream.width, "\(style)")
            let full = style.windowSize(stream: stream, fullScreen: true)
            XCTAssertEqual(style.streamSize(window: full, fullScreen: true), stream, "\(style)")
        }
    }

    func testSwitchingToFramedGrowsTheWindowUpwards() {
        let current = NSRect(x: 200, y: 100, width: 900, height: 600)
        let framed = WindowStyle.immersive.frame(switchedTo: .framed, current: current, visible: screen)
        XCTAssertEqual(framed, NSRect(x: 200, y: 100, width: 900, height: 628),
                       "the stream stays put and the bar goes above it")
    }

    func testSwitchingToImmersiveShrinksItFromTheTop() {
        let current = NSRect(x: 200, y: 100, width: 900, height: 628)
        let immersive = WindowStyle.framed.frame(switchedTo: .immersive, current: current, visible: screen)
        XCTAssertEqual(immersive, NSRect(x: 200, y: 100, width: 900, height: 600),
                       "the stream keeps its place; the bar above it goes")
    }

    func testSwitchingNearTheTopMovesTheWindowDownJustEnough() {
        // The stream's top edge is at the screen's top: the bar has nowhere to go.
        let current = NSRect(x: 200, y: screen.maxY - 600, width: 900, height: 600)
        let framed = WindowStyle.immersive.frame(switchedTo: .framed, current: current, visible: screen)
        XCTAssertEqual(framed.maxY, screen.maxY, "the bar fits under the screen's top edge")
        XCTAssertEqual(framed.origin.y, screen.maxY - 628, "moved down by exactly the bar")
        XCTAssertEqual(framed.size, CGSize(width: 900, height: 628))
    }

    func testSwitchingNearTheTopMovesItDownOnlyByWhatItOverflows() {
        // 10 pt of the bar would poke above the visible area.
        let current = NSRect(x: 200, y: screen.maxY - 610, width: 900, height: 600)
        let framed = WindowStyle.immersive.frame(switchedTo: .framed, current: current, visible: screen)
        XCTAssertEqual(framed.origin.y, screen.maxY - 628, "down by 10 pt, not a whole bar")
        XCTAssertEqual(framed.height, 628)
    }

    func testShrinkingNeverMovesTheWindow() {
        let current = NSRect(x: 200, y: screen.maxY - 628, width: 900, height: 628)
        let immersive = WindowStyle.framed.frame(switchedTo: .immersive, current: current, visible: screen)
        XCTAssertEqual(immersive.origin.y, current.origin.y, "the stream stays where it is")
        XCTAssertEqual(immersive.height, 600)
    }

    func testSwitchingInFullScreenChangesNothing() {
        let current = NSRect(x: 0, y: 0, width: 1440, height: 900)
        for (from, to) in [(WindowStyle.framed, WindowStyle.immersive), (.immersive, .framed)] {
            XCTAssertEqual(from.frame(switchedTo: to, current: current, visible: screen, fullScreen: true), current)
        }
    }
}

final class DwellPillTests: XCTestCase {
    /// The hot zone and a pill that covers it.
    private func makePill() -> DwellPill {
        DwellPill(zone: CGRect(x: 0, y: 0, width: 72, height: 32),
                  pill: CGRect(x: 0, y: 0, width: 100, height: 28))
    }

    func testNothingShowsBeforeTheDwell() {
        var pill = makePill()
        XCTAssertFalse(pill.shown)
        pill.pointerMoved(to: CGPoint(x: 20, y: 10), now: 0)
        pill.update(now: 0.34)
        XCTAssertFalse(pill.shown, "349 ms is not a rest")
        pill.update(now: 0.35)
        XCTAssertTrue(pill.shown, "350 ms in the zone is")
    }

    func testThePointerHasToBeInTheZone() {
        var pill = makePill()
        pill.pointerMoved(to: CGPoint(x: 200, y: 100), now: 0)
        pill.update(now: 1)
        XCTAssertFalse(pill.shown, "a rest elsewhere in the stream shows nothing")
        pill.pointerMoved(to: CGPoint(x: 71, y: 31), now: 1)
        pill.update(now: 1.4)
        XCTAssertTrue(pill.shown, "the zone's far corner counts")
    }

    func testAClickBeforeTheDwellGoesThroughAndStartsTheRestAgain() {
        var pill = makePill()
        pill.pointerMoved(to: CGPoint(x: 20, y: 10), now: 0)
        pill.clickReachedApp(at: CGPoint(x: 20, y: 10), now: 0.2)
        pill.update(now: 0.3)
        XCTAssertFalse(pill.shown, "the click was the app's, and the rest is younger than the dwell")
        pill.update(now: 0.55)
        XCTAssertTrue(pill.shown, "350 ms of quiet after the tap is a rest")
    }

    func testMovementOverThreePointsRestartsTheRest() {
        var pill = makePill()
        pill.pointerMoved(to: CGPoint(x: 20, y: 10), now: 0)
        pill.pointerMoved(to: CGPoint(x: 22, y: 10), now: 0.2)
        pill.update(now: 0.4)
        XCTAssertTrue(pill.shown, "2 pt of drift is still a rest")
    }

    func testMovementBeyondTheToleranceRestartsTheRest() {
        var pill = makePill()
        pill.pointerMoved(to: CGPoint(x: 20, y: 10), now: 0)
        pill.pointerMoved(to: CGPoint(x: 24, y: 10), now: 0.3)
        pill.update(now: 0.4)
        XCTAssertFalse(pill.shown, "4 pt of travel is a new rest")
        pill.update(now: 0.65)
        XCTAssertTrue(pill.shown)
    }

    func testLeavingTheZoneCancelsTheRest() {
        var pill = makePill()
        pill.pointerMoved(to: CGPoint(x: 20, y: 10), now: 0)
        pill.pointerMoved(to: CGPoint(x: 300, y: 200), now: 0.2)
        pill.update(now: 2)
        XCTAssertFalse(pill.shown, "the pointer left; the rest is gone with it")
    }

    func testThePillHidesSixHundredMsAfterThePointerLeavesIt() {
        var pill = makePill()
        pill.pointerMoved(to: CGPoint(x: 20, y: 10), now: 0)
        pill.update(now: 0.4)
        XCTAssertTrue(pill.shown)
        pill.pointerMoved(to: CGPoint(x: 400, y: 300), now: 1)
        pill.update(now: 1.5)
        XCTAssertTrue(pill.shown, "still there half a second later")
        pill.update(now: 1.6)
        XCTAssertFalse(pill.shown, "gone at 600 ms")
    }

    func testComingBackBeforeTheHideCancelsIt() {
        var pill = makePill()
        pill.pointerMoved(to: CGPoint(x: 20, y: 10), now: 0)
        pill.update(now: 0.4)
        pill.pointerMoved(to: CGPoint(x: 400, y: 300), now: 1)
        pill.pointerMoved(to: CGPoint(x: 30, y: 10), now: 1.2)
        pill.update(now: 5)
        XCTAssertTrue(pill.shown, "the pointer came back to the pill")
    }

    func testTheZoneKeepsThePillAliveBelowThePill() {
        var pill = makePill()
        pill.pointerMoved(to: CGPoint(x: 20, y: 10), now: 0)
        pill.update(now: 0.4)
        // Under the pill's 28 pt but still in the 32 pt zone.
        pill.pointerMoved(to: CGPoint(x: 60, y: 30), now: 1)
        pill.update(now: 10)
        XCTAssertTrue(pill.shown, "the zone is the pill's own resting place")
    }

    func testOnceHiddenARestCanShowItAgain() {
        var pill = makePill()
        pill.pointerMoved(to: CGPoint(x: 20, y: 10), now: 0)
        pill.update(now: 0.4)
        pill.pointerMoved(to: CGPoint(x: 400, y: 300), now: 1)
        pill.update(now: 2)
        XCTAssertFalse(pill.shown)
        pill.pointerMoved(to: CGPoint(x: 20, y: 10), now: 3)
        pill.update(now: 3.1)
        XCTAssertFalse(pill.shown, "the rest starts from the re-entry")
        pill.update(now: 3.36)
        XCTAssertTrue(pill.shown)
    }

    func testTheHotZoneAndPillAreTheOnesTheDesignAsksFor() {
        XCTAssertEqual(DwellChrome.hotZone, CGSize(width: 72, height: 32))
        XCTAssertEqual(DwellChrome.pillHeight, 28)
        XCTAssertEqual(DwellChrome.pillCornerRadius, 8)
        XCTAssertEqual(DwellChrome.dwell, 0.35)
        XCTAssertEqual(DwellChrome.hideDelay, 0.6)
        XCTAssertEqual(DwellChrome.fadeIn, 0.12)
        XCTAssertEqual(DwellChrome.tolerance, 3)
    }
}

final class ChromeBarTests: XCTestCase {
    func testTheBarIsTwentyEightPointsWithTheLightsAtTheStandardInset() {
        XCTAssertEqual(ChromeBar.height, 28)
        XCTAssertEqual(ChromeBar.trafficLightInset, 20)
        XCTAssertEqual(ChromeBar.trafficLightButtonSide, 14)
        XCTAssertEqual(ChromeBar.trafficLightSpacing, 23)
    }
}

final class PhoneChromeTests: XCTestCase {
    func testThePhoneTurnsOnlyWhenTheStreamsOrientationDiffers() {
        let phone = CGSize(width: 1080, height: 2340)
        XCTAssertNil(PhoneChrome.turnedPhone(phone: phone, video: CGSize(width: 368, height: 800)))
        XCTAssertEqual(PhoneChrome.turnedPhone(phone: phone, video: CGSize(width: 800, height: 368)),
                       CGSize(width: 2340, height: 1080))
        XCTAssertNil(PhoneChrome.turnedPhone(phone: phone, video: .zero))
    }

    func testThePhoneFrameKeepsThePhonesAspectRatioInTheStream() {
        let phone = CGSize(width: 1080, height: 2400)
        let pad = WindowStyle.framed.windowSize(stream: .zero)
        XCTAssertEqual(PhoneChrome.frame(proposed: CGSize(width: 540 + pad.width, height: 1100),
                                         current: CGSize(width: 450 + pad.width, height: 1100),
                                         phone: phone, style: .framed),
                       CGSize(width: 540 + pad.width, height: 1200 + pad.height), "the width led")
        XCTAssertEqual(PhoneChrome.frame(proposed: CGSize(width: 450 + pad.width, height: 1200 + pad.height),
                                         current: CGSize(width: 450 + pad.width, height: 1000 + pad.height),
                                         phone: phone, style: .framed),
                       CGSize(width: 540 + pad.width, height: 1200 + pad.height), "the height led")
    }
}
