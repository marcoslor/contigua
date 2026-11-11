// The two window styles, their storage, the sizes and frames they ask for, the
// full-screen reveal machine and the reveal delay. All pure logic — the views are
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

    func testAnAppWithNoStoredChoiceOpensImmersive() {
        let store = WindowStyleStore(defaults: makeDefaults())
        XCTAssertEqual(store.style(forKey: WindowStyleStore.key(forPackage: "com.example.app")), .immersive)
        XCTAssertEqual(WindowStyle.standard, .immersive)
    }

    func testTheChoiceIsRememberedPerPackage() {
        let defaults = makeDefaults()
        let store = WindowStyleStore(defaults: defaults)
        let inbox = WindowStyleStore.key(forPackage: "com.example.inbox")
        let maps = WindowStyleStore.key(forPackage: "com.example.maps")
        store.set(.framed, forKey: inbox)
        XCTAssertEqual(store.style(forKey: inbox), .framed)
        XCTAssertEqual(store.style(forKey: maps), .immersive, "another app keeps its own choice")
        store.set(.immersive, forKey: inbox)
        XCTAssertEqual(store.style(forKey: inbox), .immersive)
        XCTAssertEqual(defaults.string(forKey: inbox), "immersive")
        store.set(.framed, forKey: inbox)
        XCTAssertEqual(defaults.string(forKey: inbox), "mat",
                       "Framed's stored value is its own; the old \"framed\" string never means it")
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
        store.set(.framed, forKey: WindowStyleStore.phoneKey)
        XCTAssertEqual(store.style(forKey: WindowStyleStore.phoneKey), .framed)
        XCTAssertEqual(store.style(forKey: WindowStyleStore.key(forPackage: "com.example.app")), .immersive)
    }

    /// No migration: an unknown stored value — the old names included — is
    /// ignored and the window opens the default, Immersive.
    func testAnUnknownStoredValueOpensImmersive() {
        for raw in ["sideways", "framed", "compact", "minimal", ""] {
            let defaults = makeDefaults()
            defaults.set(raw, forKey: WindowStyleStore.key(forPackage: "com.example.app"))
            XCTAssertEqual(WindowStyleStore(defaults: defaults)
                            .style(forKey: WindowStyleStore.key(forPackage: "com.example.app")),
                           .immersive, raw)
        }
    }

    func testAWindowWithNothingToRememberStoresNothing() {
        let defaults = makeDefaults()
        let store = WindowStyleStore(defaults: defaults)
        store.set(.framed, forKey: nil)
        XCTAssertNil(defaults.string(forKey: WindowStyleStore.phoneKey))
        XCTAssertEqual(store.style(forKey: nil), .immersive)
    }
}

final class ChromeConfigTests: XCTestCase {
    func testBothStatesHideTheSystemTitleAndOwnTheLights() {
        for fullScreen in [false, true] {
            let config = ChromeConfig.forState(fullScreen: fullScreen)
            XCTAssertFalse(config.titleVisible, "\(fullScreen)")
            XCTAssertTrue(config.titlebarTransparent, "\(fullScreen)")
            XCTAssertFalse(config.lightsManagedByAppKit, "\(fullScreen)")
        }
    }

    func testTheStyleDoesNotChangeTheTitlebarRule() {
        XCTAssertEqual(ChromeConfig.forState(fullScreen: false), ChromeConfig.forState(fullScreen: true))
    }
}

final class WindowStyleSizeTests: XCTestCase {
    private let stream = CGSize(width: 900, height: 600)
    private let screen = NSRect(x: 0, y: 25, width: 1440, height: 875)

    func testImmersiveIsTheStreamPlusTheBar() {
        XCTAssertEqual(WindowStyle.immersive.windowSize(stream: stream), CGSize(width: 900, height: 628))
        let pad = WindowStyle.immersive.insets(fullScreen: false)
        XCTAssertEqual([pad.top, pad.left, pad.bottom, pad.right], [28, 0, 0, 0], "the bar at the top only")
    }

    func testFramedIsTheStreamInsideTheFrame() {
        XCTAssertEqual(WindowStyle.framed.windowSize(stream: stream), CGSize(width: 910, height: 643))
        let pad = WindowStyle.framed.insets(fullScreen: false)
        XCTAssertEqual([pad.top, pad.left, pad.bottom, pad.right], [38, 5, 5, 5])
        XCTAssertEqual(WindowStyle.framed.streamSize(window: CGSize(width: 910, height: 643)), stream)
        XCTAssertEqual(WindowStyle.framed.windowSize(stream: CGSize(width: 320, height: 240)),
                       CGSize(width: 330, height: 283), "the minimum stream plus the frame")
    }

    func testFullScreenHasNoWindowedChromeInEitherStyle() {
        for style in WindowStyle.allCases {
            XCTAssertEqual(style.windowSize(stream: stream, fullScreen: true), stream, "\(style)")
            XCTAssertEqual(style.streamSize(window: stream, fullScreen: true), stream, "\(style)")
        }
    }

    func testTheStreamSizeIsTheWindowSizeWithoutTheChrome() {
        XCTAssertEqual(WindowStyle.immersive.streamSize(window: CGSize(width: 900, height: 628)), stream)
        XCTAssertEqual(WindowStyle.framed.streamSize(window: CGSize(width: 900, height: 600)),
                       CGSize(width: 890, height: 557))
        XCTAssertEqual(WindowStyle.immersive.streamSize(window: CGSize(width: 900, height: 20)),
                       CGSize(width: 900, height: 0), "never negative")
    }

    func testTheChromeNeverChangesTheStreamsWidthOrFullScreenSize() {
        for style in WindowStyle.allCases {
            XCTAssertEqual(style.streamSize(window: style.windowSize(stream: stream)), stream, "\(style)")
            let full = style.windowSize(stream: stream, fullScreen: true)
            XCTAssertEqual(style.streamSize(window: full, fullScreen: true), stream, "\(style)")
        }
    }

    func testSwitchingToFramedGrowsTheWindowAroundTheSameStream() {
        let current = NSRect(x: 200, y: 100, width: 900, height: 628)
        let framed = WindowStyle.immersive.frame(switchedTo: .framed, current: current, visible: screen)
        XCTAssertEqual(framed, NSRect(x: 195, y: 95, width: 910, height: 643),
                       "the stream keeps its place: 5 pt on the left and bottom, 38 above")
    }

    func testSwitchingBackToImmersiveShrinksTheWindowAroundTheStream() {
        let current = NSRect(x: 195, y: 95, width: 910, height: 643)
        let immersive = WindowStyle.framed.frame(switchedTo: .immersive, current: current, visible: screen)
        XCTAssertEqual(immersive, NSRect(x: 200, y: 100, width: 900, height: 628))
    }

    func testSwitchingNearTheTopMovesTheWindowDownJustEnough() {
        // The window's top edge is at the screen's top: the frame's 10 pt of
        // extra band above the stream has nowhere to go.
        let current = NSRect(x: 200, y: screen.maxY - 628, width: 900, height: 628)
        let framed = WindowStyle.immersive.frame(switchedTo: .framed, current: current, visible: screen)
        XCTAssertEqual(framed.maxY, screen.maxY, "the frame fits under the screen's top edge")
        XCTAssertEqual(framed.origin.y, screen.maxY - 643, "moved down by exactly what overflowed")
        XCTAssertEqual(framed.size, CGSize(width: 910, height: 643))
    }

    func testSwitchingNearTheTopMovesItDownOnlyByWhatItOverflows() {
        // The window starts 4 pt under the top; the frame's 10 pt above the
        // stream leaves 6 pt to move down.
        let current = NSRect(x: 200, y: screen.maxY - 632, width: 900, height: 628)
        let framed = WindowStyle.immersive.frame(switchedTo: .framed, current: current, visible: screen)
        XCTAssertEqual(framed.maxY, screen.maxY)
        XCTAssertEqual(framed.origin.y, screen.maxY - 643, "down by 6 pt, not a whole bar")
        XCTAssertEqual(framed.height, 643)
        XCTAssertEqual(framed.origin.y - (current.origin.y - FramedChrome.sideInset), -6,
                       "just the overflow, never more")
    }

    func testShrinkingKeepsTheStreamAndNeverMovesDown() {
        let current = NSRect(x: 200, y: screen.maxY - 643, width: 910, height: 643)
        let immersive = WindowStyle.framed.frame(switchedTo: .immersive, current: current, visible: screen)
        XCTAssertEqual(immersive.origin.y, current.origin.y + FramedChrome.sideInset,
                       "the stream stays where it is: the window sheds the frame's bottom")
        XCTAssertEqual(immersive.height, 628)
        XCTAssertLessThan(immersive.maxY, screen.maxY, "shrinking never moves the window down")
    }

    func testSwitchingInFullScreenChangesNothing() {
        let current = NSRect(x: 0, y: 0, width: 1440, height: 900)
        for (from, to) in [(WindowStyle.framed, WindowStyle.immersive), (.immersive, .framed)] {
            XCTAssertEqual(from.frame(switchedTo: to, current: current, visible: screen, fullScreen: true), current)
        }
    }
}

final class RevealDelayTests: XCTestCase {
    private func makeDefaults() -> UserDefaults {
        let name = "dev.pocketdeck.tests.reveal.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        return defaults
    }

    func testShortIsTheDefault() {
        XCTAssertEqual(RevealDelay.stored(in: makeDefaults()), .short, "nothing stored opens Short")
        XCTAssertEqual(RevealDelay.short.seconds, FullScreenBar.revealDelay)
        XCTAssertEqual(RevealDelay.short.seconds, 0.35)
    }

    func testTheThreeChoicesAreZeroTheDefaultAndTwiceIt() {
        XCTAssertEqual(RevealDelay.instantly.seconds, 0)
        XCTAssertEqual(RevealDelay.short.seconds, 0.35)
        XCTAssertEqual(RevealDelay.long.seconds, 0.7)
        XCTAssertEqual(RevealDelay.long.seconds, RevealDelay.short.seconds * 2)
    }

    func testTheStoredChoiceRoundTrips() {
        let defaults = makeDefaults()
        for delay in RevealDelay.allCases {
            defaults.set(delay.rawValue, forKey: RevealDelay.key)
            XCTAssertEqual(RevealDelay.stored(in: defaults), delay)
        }
    }

    func testAnUnreadableValueFallsBackToShort() {
        let defaults = makeDefaults()
        defaults.set("soon", forKey: RevealDelay.key)
        XCTAssertEqual(RevealDelay.stored(in: defaults), .short)
    }

    func testTheLabelsTheSettingsPickerShows() {
        XCTAssertEqual(RevealDelay.instantly.label, "Instantly")
        XCTAssertEqual(RevealDelay.short.label, "Short")
        XCTAssertEqual(RevealDelay.long.label, "Long")
        XCTAssertEqual(RevealDelay.alwaysVisible.label, "Always Visible")
        XCTAssertEqual(RevealDelay.allCases, [.instantly, .short, .long, .alwaysVisible])
    }
}

final class FramedGeometryTests: XCTestCase {
    private let bounds = NSRect(x: 0, y: 0, width: 910, height: 643)

    func testTheHairlineIsHalfAPointAndTheRimOnePoint() {
        XCTAssertEqual(FramedChrome.hairline, 0.5)
        XCTAssertEqual(FramedChrome.rim, 1)
    }

    func testTheOuterRadiusIs21AndTheContentRadiusIs12() {
        XCTAssertEqual(FramedChrome.outerRadius, 21)
        XCTAssertEqual(FramedChrome.contentRadius, 12)
        XCTAssertNotEqual(FramedChrome.contentRadius, FramedChrome.outerRadius - FramedChrome.sideInset,
                          "deliberately not concentric")
    }

    func testTheTopHighlightFadesOverTenPoints() {
        XCTAssertEqual(FramedChrome.highlightHeight, 10)
    }

    func testTheFrameInsetsAndLightSlotsAreTheMeasuredOnes() {
        XCTAssertEqual([FramedChrome.topInset, FramedChrome.sideInset,
                        FramedChrome.bottomInset, FramedChrome.sideInset],
                       [38, 5, 5, 5])
        XCTAssertEqual(FramedChrome.lightInset, 12, "the 14 pt lights centred in the 38 pt bar")
        XCTAssertEqual(FramedChrome.controlsRightInset, 12, "the controls mirror the lights")
    }

    func testTheContentRectIsTheStreamInsideTheFrame() {
        XCTAssertEqual(FramedChrome.contentRect(in: bounds),
                       NSRect(x: 5, y: 5, width: 900, height: 600))
    }

    func testTheOneToOneRectIsTheContentRectNotTheWindow() {
        let content = WindowStyle.framed.streamSize(window: CGSize(width: 910, height: 643))
        XCTAssertEqual(content, CGSize(width: 900, height: 600))
        XCTAssertEqual(VideoSize.displayPixels(bounds: content, backingScale: 2,
                                               encoder: EncoderSpec(widthAlign: 2, heightAlign: 2,
                                                                    maxWidth: 4096, maxHeight: 4096,
                                                                    maxPixelsAt60: 4096 * 4096)),
                       CGSize(width: 1800, height: 1200))
    }

    func testTheLiteralCornerIsRoundedOffAndTheEdgeIsThePicturesEdge() {
        XCTAssertTrue(FramedChrome.contentRect(in: bounds).contains(NSPoint(x: 6, y: 6)))
        XCTAssertFalse(FramedChrome.contentPath(in: bounds).contains(NSPoint(x: 6, y: 6)),
                       "the rect's literal corner lies outside the 12 pt circle")
        XCTAssertTrue(FramedChrome.contentPath(in: bounds).contains(NSPoint(x: 5.1, y: 300)))
        XCTAssertFalse(FramedChrome.contentPath(in: bounds).contains(NSPoint(x: 4.9, y: 300)))
    }
}

final class FullScreenBarTests: XCTestCase {
    private func run(_ machine: inout FullScreenBarMachine,
                     _ events: [FullScreenBarEvent]) -> [[FullScreenBarAction]] {
        events.map { machine.handle($0) }
    }

    func testTheNumbersAreTheDesigns() {
        XCTAssertEqual(FullScreenBar.height, 28)
        XCTAssertEqual(FullScreenBar.edgeHeight, 8)
        XCTAssertEqual(FullScreenBar.revealDelay, 0.35)
        XCTAssertEqual(FullScreenBar.hideDelay, 0.6)
        XCTAssertEqual(FullScreenBar.revealDuration, 0.18)
        XCTAssertEqual(FullScreenBar.hideDuration, 0.15)
        XCTAssertEqual(FullScreenBar.material, .fullScreenUI)
        XCTAssertEqual(FullScreenBar.titleColor, .labelColor)
    }

    func testEnteringFullScreenStartsHiddenWithNoTimer() {
        var machine = FullScreenBarMachine(reveal: .long)
        let actions = machine.handle(.enterFullScreen)
        XCTAssertEqual(machine.mode, .hidden)
        XCTAssertNil(machine.pending)
        XCTAssertEqual(actions, [.cancelTimer, .hide(animated: false)])
    }

    func testARestAtTheTopEdgeRevealsAfterTheChoice() {
        for (delay, want) in [(RevealDelay.instantly, 0.0), (.short, 0.35), (.long, 0.7)] {
            var machine = FullScreenBarMachine(reveal: delay)
            XCTAssertEqual(machine.handle(.pointerAtTopEdge), [.cancelTimer, .scheduleReveal(want)], "\(delay)")
            XCTAssertEqual(machine.mode, .hidden)
            XCTAssertEqual(machine.pending, .reveal)
            XCTAssertEqual(machine.handle(.delayElapsed), [.reveal(animated: true)], "\(delay)")
            XCTAssertEqual(machine.mode, .revealing)
            XCTAssertEqual(machine.handle(.animationFinished), [])
            XCTAssertEqual(machine.mode, .shown)
        }
    }

    func testAPointerThatLeavesBeforeTheRestCancelsTheReveal() {
        var machine = FullScreenBarMachine(reveal: .long)
        _ = machine.handle(.pointerAtTopEdge)
        XCTAssertEqual(machine.handle(.pointerLeaves), [.cancelTimer])
        XCTAssertNil(machine.pending)
        XCTAssertEqual(machine.handle(.delayElapsed), [], "the late timer does nothing")
        XCTAssertEqual(machine.mode, .hidden)
    }

    func testThePointerReturningDuringTheHideGraceKeepsTheBar() {
        var machine = FullScreenBarMachine()
        _ = run(&machine, [.pointerAtTopEdge, .delayElapsed, .animationFinished])
        XCTAssertEqual(machine.mode, .shown)
        XCTAssertEqual(machine.handle(.pointerLeaves), [.cancelTimer, .scheduleHide(0.6)])
        XCTAssertEqual(machine.handle(.pointerAtTopEdge), [.cancelTimer])
        XCTAssertEqual(machine.handle(.delayElapsed), [], "the cancelled grace does nothing")
        XCTAssertEqual(machine.mode, .shown)
    }

    func testTheBarHidesAfterTheGrace() {
        var machine = FullScreenBarMachine()
        _ = run(&machine, [.pointerAtTopEdge, .delayElapsed, .animationFinished, .pointerLeaves])
        XCTAssertEqual(machine.handle(.delayElapsed), [.hide(animated: true)])
        XCTAssertEqual(machine.mode, .hiding)
        XCTAssertEqual(machine.handle(.animationFinished), [])
        XCTAssertEqual(machine.mode, .hidden)
    }

    func testLeavingDuringTheSlideInReversesIt() {
        var machine = FullScreenBarMachine()
        _ = run(&machine, [.pointerAtTopEdge, .delayElapsed])
        XCTAssertEqual(machine.mode, .revealing)
        XCTAssertEqual(machine.handle(.pointerLeaves), [.hide(animated: true)])
        XCTAssertEqual(machine.mode, .hiding)
        XCTAssertEqual(machine.handle(.animationFinished), [])
        XCTAssertEqual(machine.mode, .hidden)
    }

    func testReturningDuringTheSlideOutRevealsAgain() {
        var machine = FullScreenBarMachine()
        _ = run(&machine, [.pointerAtTopEdge, .delayElapsed, .animationFinished, .pointerLeaves, .delayElapsed])
        XCTAssertEqual(machine.mode, .hiding)
        XCTAssertEqual(machine.handle(.pointerAtTopEdge), [.cancelTimer, .reveal(animated: true)])
        XCTAssertEqual(machine.mode, .revealing)
    }

    func testASlideInThatFinishesAfterThePointerLeftHidesAgain() {
        var machine = FullScreenBarMachine()
        _ = run(&machine, [.pointerAtTopEdge, .delayElapsed, .pointerLeaves])
        // pointerLeaves reversed the slide, so a stale animationFinished is
        // ignored for the revealing state's opposite; a fresh one ends hiding.
        XCTAssertEqual(machine.mode, .hiding)
        XCTAssertEqual(machine.handle(.animationFinished), [])
        XCTAssertEqual(machine.mode, .hidden)

        var slow = FullScreenBarMachine()
        _ = run(&slow, [.pointerAtTopEdge, .delayElapsed])
        slow.handle(.pointerLeaves)
        _ = slow.handle(.pointerAtTopEdge) // back in, revealing
        // The reveal completes while the pointer is still at the edge.
        XCTAssertEqual(slow.handle(.animationFinished), [])
        XCTAssertEqual(slow.mode, .shown)
    }

    func testAMenuRevealsTheBarAndKeepsIt() {
        var machine = FullScreenBarMachine()
        XCTAssertEqual(machine.handle(.menuTracking(true)), [.cancelTimer, .reveal(animated: true)])
        XCTAssertEqual(machine.mode, .revealing)
        _ = machine.handle(.animationFinished)
        XCTAssertEqual(machine.handle(.pointerLeaves), [], "a menu keeps the bar up")
        XCTAssertEqual(machine.handle(.delayElapsed), [])
        XCTAssertEqual(machine.mode, .shown)
    }

    func testTheMenuEndingSchedulesTheHideOnlyWhenThePointerIsAway() {
        var machine = FullScreenBarMachine()
        _ = run(&machine, [.menuTracking(true), .animationFinished])
        XCTAssertEqual(machine.handle(.menuTracking(false)), [.scheduleHide(0.6)])
        XCTAssertEqual(machine.mode, .shown)

        var resting = FullScreenBarMachine()
        _ = resting.handle(.menuTracking(true))
        _ = resting.handle(.pointerAtTopEdge)
        _ = resting.handle(.animationFinished)
        XCTAssertEqual(resting.handle(.menuTracking(false)), [], "the pointer is still at the edge")
    }

    func testExitFullScreenTakesTheBarWithEveryTimer() {
        var machine = FullScreenBarMachine()
        _ = run(&machine, [.pointerAtTopEdge, .delayElapsed, .animationFinished])
        XCTAssertEqual(machine.handle(.exitFullScreen), [.cancelTimer, .hide(animated: false)])
        XCTAssertEqual(machine.mode, .hidden)
        XCTAssertNil(machine.pending)
        XCTAssertEqual(machine.handle(.pointerAtTopEdge), [.cancelTimer, .scheduleReveal(0.35)])
    }

    func testAlwaysVisibleShowsAtOnceAndNeverHides() {
        var machine = FullScreenBarMachine(reveal: .alwaysVisible)
        XCTAssertEqual(machine.handle(.pointerAtTopEdge), [.cancelTimer, .reveal(animated: true)])
        XCTAssertEqual(machine.mode, .revealing)
        _ = machine.handle(.animationFinished)
        XCTAssertEqual(machine.handle(.pointerLeaves), [])
        XCTAssertEqual(machine.mode, .shown)
        XCTAssertEqual(machine.handle(.delayElapsed), [])
        XCTAssertEqual(machine.mode, .shown)
    }

    func testPickingATimedChoiceFromAlwaysVisibleHidesAShownBarWhenThePointerIsAway() {
        var machine = FullScreenBarMachine(reveal: .alwaysVisible)
        _ = machine.handle(.pointerAtTopEdge)
        _ = machine.handle(.animationFinished)
        _ = machine.handle(.pointerLeaves)
        XCTAssertEqual(machine.mode, .shown, "Always Visible ignores the leave")
        XCTAssertEqual(machine.handle(.configurationChanged(.short)), [.cancelTimer, .hide(animated: true)])
        XCTAssertEqual(machine.mode, .hiding)
    }

    func testPickingATimedChoiceWhileThePointerRestsKeepsTheBarAndHidesOnLeave() {
        var machine = FullScreenBarMachine(reveal: .alwaysVisible)
        _ = machine.handle(.pointerAtTopEdge)
        _ = machine.handle(.animationFinished)
        XCTAssertEqual(machine.handle(.configurationChanged(.short)), [.cancelTimer])
        XCTAssertEqual(machine.mode, .shown, "the pointer is still at the edge")
        XCTAssertEqual(machine.handle(.pointerLeaves), [.cancelTimer, .scheduleHide(0.6)])
        XCTAssertEqual(machine.handle(.configurationChanged(.long)), [],
                       "a hide grace is not re-timed by another delay")
    }

    func testRetimingARunningRestUsesTheNewDelay() {
        var machine = FullScreenBarMachine(reveal: .long)
        _ = machine.handle(.pointerAtTopEdge)
        XCTAssertEqual(machine.handle(.configurationChanged(.short)), [.cancelTimer, .scheduleReveal(0.35)])
        XCTAssertEqual(machine.mode, .hidden)
        XCTAssertEqual(machine.pending, .reveal)
    }

    func testPickingAlwaysVisibleRevealsAHiddenBar() {
        var machine = FullScreenBarMachine()
        XCTAssertEqual(machine.handle(.configurationChanged(.alwaysVisible)), [.cancelTimer, .reveal(animated: true)])
        XCTAssertEqual(machine.mode, .revealing)
    }

    func testIgnoredEventsChangeNothing() {
        var machine = FullScreenBarMachine()
        XCTAssertEqual(machine.handle(.delayElapsed), [])
        XCTAssertEqual(machine.handle(.animationFinished), [])
        XCTAssertEqual(machine.handle(.pointerLeaves), [])
        XCTAssertEqual(machine.handle(.menuTracking(false)), [])
        XCTAssertEqual(machine.mode, .hidden)
        XCTAssertNil(machine.pending)

        _ = machine.handle(.pointerAtTopEdge)
        _ = machine.handle(.delayElapsed)
        _ = machine.handle(.animationFinished)
        XCTAssertEqual(machine.handle(.delayElapsed), [], "shown has no pending timer")
        XCTAssertEqual(machine.handle(.enterFullScreen), [.cancelTimer, .hide(animated: false)])
        XCTAssertEqual(machine.mode, .hidden)
    }
}

final class ChromeBarTests: XCTestCase {
    /// The framed bar: 28 pt, the 14 pt lights equally inset 7 pt.
    /// BarGeometryTests covers the numbers and the real view geometry.
    func testTheBarIsTwentyEightPointsWithItsEqualInsets() {
        XCTAssertEqual(ChromeBar.height, 28)
        XCTAssertEqual(ChromeBar.trafficLightInset, 7)
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

    /// No full screen for the phone window: the green button zooms to the
    /// phone's aspect fit inside the visible frame, never to the whole display.
    func testThePhoneZoomIsTheAspectFitInsideTheVisibleFrame() {
        let visible = NSRect(x: 100, y: 50, width: 1440, height: 900)
        let bar = WindowStyle.immersive.insets(fullScreen: false).top
        let portrait = PhoneChrome.zoomFrame(phone: CGSize(width: 1080, height: 2340),
                                             style: .immersive, visible: visible)
        XCTAssertEqual(portrait.height, visible.height, accuracy: 1)
        XCTAssertEqual(portrait.width, (visible.height - bar) * 1080 / 2340, accuracy: 1)
        XCTAssertEqual(portrait.midX, visible.midX, accuracy: 1)
        XCTAssertEqual(portrait.midY, visible.midY, accuracy: 1)

        let landscape = PhoneChrome.zoomFrame(phone: CGSize(width: 2340, height: 1080),
                                              style: .immersive, visible: visible)
        XCTAssertEqual(landscape.width, visible.width, accuracy: 1)
        XCTAssertEqual(landscape.height, visible.width * 1080 / 2340 + bar, accuracy: 1)
        XCTAssertTrue(visible.contains(landscape), "the zoom stays inside the screen")
        XCTAssertTrue(visible.contains(portrait), "the zoom stays inside the screen")

        let immersive = PhoneChrome.zoomFrame(phone: CGSize(width: 1080, height: 2340),
                                              style: .immersive, visible: visible)
        XCTAssertEqual(immersive.height, visible.height, accuracy: 1, "no bar to subtract")
    }

    func testThePhoneFrameKeepsThePhonesAspectRatioInTheStream() {
        let phone = CGSize(width: 1080, height: 2400)
        let pad = WindowStyle.immersive.windowSize(stream: .zero)
        XCTAssertEqual(PhoneChrome.frame(proposed: CGSize(width: 540 + pad.width, height: 1100),
                                         phone: phone, style: .immersive),
                       CGSize(width: 540 + pad.width, height: 1200 + pad.height), "the width led")
        XCTAssertEqual(PhoneChrome.frame(proposed: CGSize(width: 450 + pad.width, height: 1200 + pad.height),
                                         phone: phone, style: .immersive),
                       CGSize(width: 540 + pad.width, height: 1200 + pad.height), "the height led")
    }

    /// The v104 bug: a monotonic drag must give a monotonic window. The old
    /// rule measured each proposal against the last snapped frame, so after a
    /// mostly-down move a mostly-across one snapped back smaller and the window
    /// fought the hand.
    func testAMonotonicDragGivesAMonotonicPhoneWindow() {
        let phone = CGSize(width: 1080, height: 2400)
        let ratio = phone.width / phone.height
        var last = CGSize.zero
        for step in 0..<10 {
            let proposed = CGSize(width: 500 + Double(step) * 30, height: 900 + Double(step) * 40)
            let size = PhoneChrome.frame(proposed: proposed, phone: phone, style: .immersive)
            let stream = WindowStyle.immersive.streamSize(window: size)
            XCTAssertEqual(stream.width / stream.height, ratio, accuracy: 0.005,
                           "step \(step) keeps the phone's aspect")
            if last != .zero {
                XCTAssertGreaterThanOrEqual(size.width, last.width - 0.5,
                                            "step \(step) must not snap the width back")
                XCTAssertGreaterThanOrEqual(size.height, last.height - 0.5,
                                            "step \(step) must not snap the height back")
            }
            last = size
        }
    }

    // MARK: Drag edges (ISS-64)

    private let phoneShape = CGSize(width: 1080, height: 2340)

    private func assertPhoneShaped(_ size: CGSize, _ message: String,
                                   file: StaticString = #filePath, line: UInt = #line) {
        let stream = WindowStyle.immersive.streamSize(window: size)
        XCTAssertEqual(stream.width / stream.height,
                       phoneShape.width / phoneShape.height, accuracy: 0.005,
                       message, file: file, line: line)
    }

    /// The person's own frame: the bottom edge dragged from 754 to 600 pt.
    func testTheBottomEdgeDragShrinksThePhoneWindowToTheHeight() {
        let size = PhoneChrome.frame(proposed: CGSize(width: 335, height: 600),
                                     phone: phoneShape, style: .immersive, edge: .bottom)
        XCTAssertEqual(size.height, 600, accuracy: 0.5, "the bottom edge sets the height")
        assertPhoneShaped(size, "the width follows the phone's aspect")
    }

    func testTheRightEdgeDragShrinksThePhoneWindowToTheWidth() {
        let size = PhoneChrome.frame(proposed: CGSize(width: 280, height: 754),
                                     phone: phoneShape, style: .immersive, edge: .right)
        XCTAssertEqual(size.width, 280, accuracy: 0.5, "the right edge sets the width")
        assertPhoneShaped(size, "the height follows the phone's aspect")
    }

    func testTheTopAndLeftEdgesLeadTheSameWay() {
        let top = PhoneChrome.frame(proposed: CGSize(width: 335, height: 600),
                                    phone: phoneShape, style: .immersive, edge: .top)
        XCTAssertEqual(top.height, 600, accuracy: 0.5, "the top edge sets the height")
        assertPhoneShaped(top, "the width follows the top edge's height")

        let left = PhoneChrome.frame(proposed: CGSize(width: 280, height: 754),
                                     phone: phoneShape, style: .immersive, edge: .left)
        XCTAssertEqual(left.width, 280, accuracy: 0.5, "the left edge sets the width")
        assertPhoneShaped(left, "the height follows the left edge's width")
    }

    /// A corner keeps the v104 larger-area rule: it may shrink both dimensions.
    func testACornerDragInwardShrinksBothDimensions() {
        let size = PhoneChrome.frame(proposed: CGSize(width: 280, height: 600),
                                     phone: phoneShape, style: .immersive, edge: .bottomRight)
        XCTAssertLessThan(size.width, 335)
        XCTAssertLessThan(size.height, 754)
        assertPhoneShaped(size, "the corner drag keeps the phone's aspect")
    }

    /// The edge version of the v104 test: a bottom-edge drag that asks for a
    /// smaller height each step gives a smaller window each step.
    func testAMonotonicBottomEdgeDragGivesAMonotonicPhoneWindow() {
        let phone = CGSize(width: 1080, height: 2400)
        var last: CGFloat = 0
        for step in 0..<10 {
            let proposed = CGSize(width: 500, height: 1200 - Double(step) * 40)
            let size = PhoneChrome.frame(proposed: proposed, phone: phone,
                                         style: .immersive, edge: .bottom)
            if last > 0 {
                XCTAssertLessThanOrEqual(size.height, last + 0.5,
                                         "step \(step) must follow the bottom edge in")
            }
            last = size.height
        }
        XCTAssertEqual(last, 1200 - 9 * 40, accuracy: 0.5,
                       "the window's height is the bottom edge's last proposal")
    }

    func testTheEdgeIsReadFromThePointerWithinSixPoints() {
        let frame = NSRect(x: 300, y: 200, width: 335, height: 754)
        XCTAssertEqual(PhoneWindowEdge.at(point: CGPoint(x: 467, y: 200), in: frame), .bottom)
        XCTAssertEqual(PhoneWindowEdge.at(point: CGPoint(x: 467, y: 205), in: frame), .bottom,
                       "5 pt inside the bottom edge is still its grab band")
        XCTAssertEqual(PhoneWindowEdge.at(point: CGPoint(x: 467, y: 212), in: frame), .none)
        XCTAssertEqual(PhoneWindowEdge.at(point: CGPoint(x: 300, y: 577), in: frame), .left)
        XCTAssertEqual(PhoneWindowEdge.at(point: CGPoint(x: 630, y: 577), in: frame), .right,
                       "5 pt inside the right edge is still its grab band")
        XCTAssertEqual(PhoneWindowEdge.at(point: CGPoint(x: 467, y: 951), in: frame), .top)
        XCTAssertEqual(PhoneWindowEdge.at(point: CGPoint(x: 300, y: 200), in: frame), .bottomLeft)
        XCTAssertEqual(PhoneWindowEdge.at(point: CGPoint(x: 635, y: 954), in: frame), .topRight)
        XCTAssertEqual(PhoneWindowEdge.at(point: CGPoint(x: 300, y: 954), in: frame), .topLeft)
        XCTAssertEqual(PhoneWindowEdge.at(point: CGPoint(x: 635, y: 200), in: frame), .bottomRight)
        XCTAssertEqual(PhoneWindowEdge.at(point: CGPoint(x: 700, y: 577), in: frame), .none,
                       "10 pt outside the frame is not a grab")
        XCTAssertEqual(PhoneWindowEdge.at(point: .zero, in: frame), .none)
    }

    // MARK: The restored shape and the first picture (ISS-63)

    private let visible = NSRect(x: 0, y: 0, width: 1440, height: 900)

    private func assertStreamAspect(_ frame: NSRect, _ message: String,
                                    file: StaticString = #filePath, line: UInt = #line) {
        let stream = WindowStyle.immersive.streamSize(window: frame.size)
        XCTAssertEqual(stream.width / stream.height,
                       phoneShape.width / phoneShape.height, accuracy: 0.005,
                       message, file: file, line: line)
    }

    /// The person's own case: a saved frame wider than the phone's shape.
    func testAWrongShapedSavedFrameOpensInThePhonesShape() {
        let saved = NSRect(x: 120, y: 300, width: 432, height: 870)
        let frame = PhoneChrome.restoredFrame(saved: saved, phone: phoneShape,
                                              style: .immersive, visible: visible)
        assertStreamAspect(frame, "the saved frame opens at the phone's aspect")
        XCTAssertEqual(frame.minX, saved.minX, accuracy: 0.5, "the left edge stays")
        XCTAssertEqual(frame.maxY, saved.maxY, accuracy: 0.5, "the top edge stays")
        XCTAssertEqual(frame.height, saved.height, accuracy: 0.5,
                       "the remembered height leads")
    }

    func testASavedLandscapeFrameForAPortraitPhoneOpensPortrait() {
        let saved = NSRect(x: 200, y: 100, width: 800, height: 400)
        let frame = PhoneChrome.restoredFrame(saved: saved, phone: phoneShape,
                                              style: .immersive, visible: visible)
        assertStreamAspect(frame, "a landscape frame opens in a portrait phone's shape")
        XCTAssertLessThan(frame.width, frame.height)
        XCTAssertEqual(frame.minX, saved.minX, accuracy: 0.5)
        XCTAssertEqual(frame.maxY, saved.maxY, accuracy: 0.5)
    }

    /// The screen's limit scales the stream as one; it never clamps the width
    /// and the height apart. `present()` has already clamped the height to the
    /// visible frame before the phone rule sees the frame.
    func testASavedFrameTallerThanTheScreenKeepsTheAspect() {
        let saved = NSRect(x: 100, y: 0, width: 335, height: 900)
        let frame = PhoneChrome.restoredFrame(saved: saved, phone: phoneShape,
                                              style: .immersive, visible: visible)
        assertStreamAspect(frame, "the screen's limit keeps the phone's aspect")
        XCTAssertLessThanOrEqual(frame.height, visible.height + 0.5)
        XCTAssertEqual(frame.maxY, visible.maxY, accuracy: 0.5)
        XCTAssertEqual(frame.minX, saved.minX, accuracy: 0.5)
    }

    /// The first picture of a stream whose shape disagrees with the window's
    /// video area refits the window, keeping the top-left and the height.
    func testTheFirstPictureOfADifferentShapeRefitsTheWindow() {
        let current = NSRect(x: 120, y: 300, width: 864, height: 1712)
        let picture = CGSize(width: 1080, height: 2340)
        let video = WindowStyle.immersive.streamSize(window: current.size)

        XCTAssertEqual(PhoneChrome.PictureFit.decide(video: video, picture: picture, isDragging: false),
                       .refitNow)
        let refit = PhoneChrome.refitFrame(current: current, picture: picture, style: .immersive)
        assertStreamAspect(refit, "the refit makes the video area the picture's shape")
        XCTAssertEqual(refit.minX, current.minX, accuracy: 0.5, "the left edge stays")
        XCTAssertEqual(refit.maxY, current.maxY, accuracy: 0.5, "the top edge stays")
        XCTAssertEqual(refit.height, current.height, accuracy: 0.5, "the height stays")
        XCTAssertEqual(PhoneChrome.PictureFit.decide(
            video: WindowStyle.immersive.streamSize(window: refit.size),
            picture: picture, isDragging: false), .none,
            "a picture that matches the window does not refit")
    }

    func testAPictureArrivingDuringADragRefitsAtTheDragsEnd() {
        let video = CGSize(width: 864, height: 1684)
        let picture = CGSize(width: 1080, height: 2340)
        XCTAssertEqual(PhoneChrome.PictureFit.decide(video: video, picture: picture, isDragging: true),
                       .refitAtDragEnd)
        XCTAssertEqual(PhoneChrome.PictureFit.decide(video: video, picture: picture, isDragging: false),
                       .refitNow)
        XCTAssertEqual(PhoneChrome.PictureFit.decide(video: picture, picture: picture, isDragging: false),
                       .none)
    }
    func testTheFramedPhoneWindowKeepsTheAspectInsideTheFrame() {
        let visible = NSRect(x: 100, y: 50, width: 1440, height: 900)
        let phone = CGSize(width: 1080, height: 2340)
        let frame = PhoneChrome.zoomFrame(phone: phone, style: .framed, visible: visible)
        let stream = WindowStyle.framed.streamSize(window: frame.size)
        XCTAssertEqual(stream.width / stream.height, phone.width / phone.height, accuracy: 0.005)
        XCTAssertEqual(frame.maxY, visible.maxY, accuracy: 1, "the frame fits the screen")
        let proposed = CGSize(width: 500, height: 1000)
        let snapped = PhoneChrome.frame(proposed: proposed, phone: phone, style: .framed)
        let snappedStream = WindowStyle.framed.streamSize(window: snapped)
        XCTAssertEqual(snappedStream.width / snappedStream.height, phone.width / phone.height, accuracy: 0.005)
        XCTAssertEqual(snapped.width - snappedStream.width, 10, accuracy: 0.5)
        XCTAssertEqual(snapped.height - snappedStream.height, 43, accuracy: 0.5)
    }

}
