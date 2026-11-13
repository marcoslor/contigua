// The three window styles, their storage, the sizes and frames they ask for,
// the full-screen reveal machine, the Immersive dwell and the reveal delay. All
// pure logic — the views are exercised in the e2e check (C14).

import AppKit
import XCTest
@testable import Contigua

final class WindowStyleStorageTests: XCTestCase {
    private func makeDefaults() -> UserDefaults {
        let name = "app.contigua.tests.style.\(UUID().uuidString)"
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
        store.set(.compact, forKey: inbox)
        XCTAssertEqual(store.style(forKey: inbox), .compact)
        XCTAssertEqual(store.style(forKey: maps), .framed, "another app keeps its own choice")
        XCTAssertEqual(defaults.string(forKey: inbox), "bar")
        store.set(.immersive, forKey: inbox)
        XCTAssertEqual(store.style(forKey: inbox), .immersive)
        XCTAssertEqual(defaults.string(forKey: inbox), "pill")
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
        XCTAssertEqual(store.style(forKey: WindowStyleStore.key(forPackage: "com.example.app")), .framed)
    }

    /// No migration (issue #90): an unknown stored value — every value an
    /// older build wrote included — is ignored and the window opens the
    /// default, Framed. A stored "immersive" was the bar style on main and the
    /// pill style before it: it must never open the borderless Immersive.
    func testAnUnknownStoredValueOpensFramed() {
        for raw in ["sideways", "framed", "immersive", "minimal", "compact", "Compact", "Immersive", "glass", ""] {
            let defaults = makeDefaults()
            defaults.set(raw, forKey: WindowStyleStore.key(forPackage: "com.example.app"))
            XCTAssertEqual(WindowStyleStore(defaults: defaults)
                            .style(forKey: WindowStyleStore.key(forPackage: "com.example.app")),
                           .framed, raw)
        }
    }

    func testAWindowWithNothingToRememberStoresNothing() {
        let defaults = makeDefaults()
        let store = WindowStyleStore(defaults: defaults)
        store.set(.framed, forKey: nil)
        XCTAssertNil(defaults.string(forKey: WindowStyleStore.phoneKey))
        XCTAssertEqual(store.style(forKey: nil), .framed)
    }
}

final class ChromeConfigTests: XCTestCase {
    /// Framed and Immersive draw their own chrome under a hidden, clear title
    /// bar and place the lights. Compact's band is the mirrored stream under
    /// AppKit's transparent title bar: AppKit's own lights, our toned title
    /// over the band instead of the system's (WIN-7, WIN-69).
    func testWindowedFramedAndImmersiveOwnTheLightsAndCompactWearsAppKitsOverItsBand() {
        for style in [WindowStyle.framed, .immersive] {
            let config = ChromeConfig.forState(style: style, fullScreen: false)
            XCTAssertFalse(config.titleVisible, "\(style)")
            XCTAssertTrue(config.titlebarTransparent, "\(style)")
            XCTAssertFalse(config.lightsManagedByAppKit, "\(style)")
        }
        let compact = ChromeConfig.forState(style: .compact, fullScreen: false)
        XCTAssertFalse(compact.titleVisible, "the band's title is ours, in the band's tone")
        XCTAssertTrue(compact.titlebarTransparent, "the band shows through AppKit's title bar")
        XCTAssertTrue(compact.lightsManagedByAppKit, "AppKit's own lights, where AppKit puts them")
    }

    /// Full screen looks the same in every style: the window's own native
    /// title bar, which the system brings down with the menu bar (WIN-14).
    func testFullScreenIsTheSystemTitleBarInEveryStyle() {
        for style in WindowStyle.allCases {
            let config = ChromeConfig.forState(style: style, fullScreen: true)
            XCTAssertTrue(config.titleVisible, "\(style): the system's title")
            XCTAssertFalse(config.titlebarTransparent, "\(style): a solid title bar")
            XCTAssertTrue(config.lightsManagedByAppKit, "\(style): the standard lights where AppKit puts them")
        }
    }
}

final class WindowStyleSizeTests: XCTestCase {
    private let stream = CGSize(width: 900, height: 600)
    private let screen = NSRect(x: 0, y: 25, width: 1440, height: 875)
    /// AppKit's frame for the 900×600 stream in a standard titled window, and
    /// its title bar: the system's height on this macOS, never a number of ours.
    private var compactHeight: CGFloat {
        NSWindow.frameRect(forContentRect: NSRect(origin: .zero, size: stream),
                           styleMask: [.titled, .closable, .miniaturizable, .resizable]).height
    }
    private var titleBar: CGFloat { compactHeight - stream.height }

    /// WIN-4, WIN-67: Compact's band above the stream is exactly AppKit's
    /// title-bar height, never a number of ours: the content view spans the
    /// window under the transparent title bar and the stream sits below it.
    func testCompactIsTheStreamUnderABandAsTallAsAppKitsTitleBar() {
        XCTAssertGreaterThan(titleBar, 0)
        XCTAssertEqual(WindowStyle.compact.windowSize(stream: stream), CGSize(width: 900, height: compactHeight))
        XCTAssertEqual(WindowStyle.compact.contentSize(stream: stream), CGSize(width: 900, height: compactHeight),
                       "the content view is the whole window: the band is ours to draw")
        let pad = WindowStyle.compact.insets(fullScreen: false)
        XCTAssertEqual([pad.top, pad.left, pad.bottom, pad.right], [titleBar, 0, 0, 0])
        for style in WindowStyle.allCases {
            XCTAssertTrue(style.styleMask.contains(.fullSizeContentView), "\(style)")
        }
    }

    func testFramedIsTheStreamInsideTheFrame() {
        XCTAssertEqual(WindowStyle.framed.windowSize(stream: stream), CGSize(width: 910, height: 643))
        let pad = WindowStyle.framed.insets(fullScreen: false)
        XCTAssertEqual([pad.top, pad.left, pad.bottom, pad.right], [38, 5, 5, 5])
        XCTAssertEqual(WindowStyle.framed.streamSize(window: CGSize(width: 910, height: 643)), stream)
        XCTAssertEqual(WindowStyle.framed.windowSize(stream: CGSize(width: 320, height: 240)),
                       CGSize(width: 330, height: 283), "the minimum stream plus the frame")
    }

    func testImmersiveIsTheStreamExactly() {
        XCTAssertEqual(WindowStyle.immersive.windowSize(stream: stream), stream)
        let pad = WindowStyle.immersive.insets(fullScreen: false)
        XCTAssertEqual([pad.top, pad.left, pad.bottom, pad.right], [0, 0, 0, 0])
    }

    func testThePickerOrderAndTheStoredTokens() {
        XCTAssertEqual(WindowStyle.allCases, [.framed, .compact, .immersive])
        XCTAssertEqual(WindowStyle.allCases.map(\.label), ["Framed", "Compact", "Immersive"])
        XCTAssertEqual(WindowStyle.allCases.map(\.rawValue), ["mat", "bar", "pill"])
        XCTAssertEqual(WindowStyle.allCases.map(\.debugName), ["framed", "compact", "immersive"])
        for style in WindowStyle.allCases {
            XCTAssertEqual(WindowStyle(debugName: style.debugName), style)
        }
        XCTAssertEqual(WindowStyle.standard, .framed)
    }

    func testFullScreenHasNoWindowedChromeInAnyStyle() {
        for style in WindowStyle.allCases {
            XCTAssertEqual(style.windowSize(stream: stream, fullScreen: true), stream, "\(style)")
            XCTAssertEqual(style.streamSize(window: stream, fullScreen: true), stream, "\(style)")
        }
    }

    func testTheStreamSizeIsTheWindowSizeWithoutTheChrome() {
        XCTAssertEqual(WindowStyle.compact.streamSize(window: CGSize(width: 900, height: compactHeight)), stream)
        XCTAssertEqual(WindowStyle.framed.streamSize(window: CGSize(width: 900, height: 600)),
                       CGSize(width: 890, height: 557))
        XCTAssertEqual(WindowStyle.compact.streamSize(window: CGSize(width: 900, height: 20)),
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
        let current = NSRect(x: 200, y: 100, width: 900, height: compactHeight)
        let framed = WindowStyle.compact.frame(switchedTo: .framed, current: current, visible: screen)
        XCTAssertEqual(framed, NSRect(x: 195, y: 95, width: 910, height: 643),
                       "the stream keeps its place: 5 pt on the left and bottom, 38 above")
    }

    func testSwitchingBackToCompactShrinksTheWindowAroundTheStream() {
        let current = NSRect(x: 195, y: 95, width: 910, height: 643)
        let compact = WindowStyle.framed.frame(switchedTo: .compact, current: current, visible: screen)
        XCTAssertEqual(compact, NSRect(x: 200, y: 100, width: 900, height: compactHeight),
                       "the stream keeps its place: its top edge is under AppKit's title bar")
    }

    func testSwitchingToImmersiveShedsTheBarsAndTheFrame() {
        let current = NSRect(x: 195, y: 95, width: 910, height: 643)
        let immersive = WindowStyle.framed.frame(switchedTo: .immersive, current: current, visible: screen)
        XCTAssertEqual(immersive, NSRect(x: 200, y: 100, width: 900, height: 600),
                       "the stream keeps its place; only the chrome goes")
    }

    func testSwitchingNearTheTopMovesTheWindowDownJustEnough() throws {
        // The window's top edge is at the screen's top: what the frame's 38 pt
        // bar adds over AppKit's title bar has nowhere to go.
        let overflow = FramedChrome.topInset - titleBar
        try XCTSkipIf(overflow <= 0, "this title bar (\(titleBar) pt) is as tall as the frame's bar")
        let current = NSRect(x: 200, y: screen.maxY - compactHeight, width: 900, height: compactHeight)
        let framed = WindowStyle.compact.frame(switchedTo: .framed, current: current, visible: screen)
        XCTAssertEqual(framed.maxY, screen.maxY, "the frame fits under the screen's top edge")
        XCTAssertEqual(framed.origin.y, screen.maxY - 643, "moved down by exactly what overflowed")
        XCTAssertEqual(framed.size, CGSize(width: 910, height: 643))
    }

    func testSwitchingNearTheTopMovesItDownOnlyByWhatItOverflows() throws {
        // The window starts 1 pt under the top: one point less to move down.
        let overflow = FramedChrome.topInset - titleBar - 1
        try XCTSkipIf(overflow <= 0, "this title bar (\(titleBar) pt) leaves nothing to overflow")
        let current = NSRect(x: 200, y: screen.maxY - compactHeight - 1, width: 900, height: compactHeight)
        let framed = WindowStyle.compact.frame(switchedTo: .framed, current: current, visible: screen)
        XCTAssertEqual(framed.maxY, screen.maxY)
        XCTAssertEqual(framed.height, 643)
        XCTAssertEqual(framed.origin.y - (current.origin.y - FramedChrome.sideInset), -overflow,
                       "just the overflow, never more")
    }

    func testShrinkingKeepsTheStreamAndNeverMovesDown() {
        let current = NSRect(x: 200, y: screen.maxY - 643, width: 910, height: 643)
        let compact = WindowStyle.framed.frame(switchedTo: .compact, current: current, visible: screen)
        XCTAssertEqual(compact.origin.y, current.origin.y + FramedChrome.sideInset,
                       "the stream stays where it is: the window sheds the frame's bottom")
        XCTAssertEqual(compact.height, compactHeight)
        XCTAssertLessThan(compact.maxY, screen.maxY, "shrinking never moves the window down")
    }

    func testSwitchingInFullScreenChangesNothing() {
        let current = NSRect(x: 0, y: 0, width: 1440, height: 900)
        for (from, to) in [(WindowStyle.framed, WindowStyle.compact), (.compact, .framed)] {
            XCTAssertEqual(from.frame(switchedTo: to, current: current, visible: screen, fullScreen: true), current)
        }
    }
}

final class RevealDelayTests: XCTestCase {
    private func makeDefaults() -> UserDefaults {
        let name = "app.contigua.tests.reveal.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        return defaults
    }

    func testShortIsTheDefault() {
        XCTAssertEqual(RevealDelay.stored(in: makeDefaults()), .short, "nothing stored opens Short")
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

    func testEachRevealDelayShowsThePillAtItsOwnTime() {
        let cases: [(RevealDelay, TimeInterval, TimeInterval)] = [
            (.instantly, 0, 0),
            (.short, 0.34, 0.35),
            (.long, 0.69, 0.7),
        ]
        for (delay, early, due) in cases {
            var pill = DwellPill(zone: CGRect(x: 0, y: 0, width: 72, height: 32),
                                 pill: CGRect(x: 0, y: 0, width: 100, height: 28),
                                 dwell: delay.seconds)
            pill.pointerMoved(to: CGPoint(x: 20, y: 10), now: 0)
            pill.update(now: early)
            XCTAssertEqual(pill.shown, early >= delay.seconds, "\(delay) at \(early) s")
            pill.update(now: due)
            XCTAssertTrue(pill.shown, "\(delay) at \(due) s")
        }
    }

    func testChangingTheDelayRetimesARestAlreadyRunning() {
        var pill = DwellPill(zone: CGRect(x: 0, y: 0, width: 72, height: 32),
                             pill: CGRect(x: 0, y: 0, width: 100, height: 28),
                             dwell: RevealDelay.long.seconds)
        pill.pointerMoved(to: CGPoint(x: 20, y: 10), now: 0)
        pill.update(now: 0.4)
        XCTAssertFalse(pill.shown, "Long is not up at 400 ms")
        pill.setDwell(RevealDelay.short.seconds)
        pill.update(now: 0.4)
        XCTAssertTrue(pill.shown, "Short's 350 ms had already passed when it was picked")
    }

    func testTheHotZoneAndPillAreTheOnesTheDesignAsksFor() {
        XCTAssertEqual(DwellChrome.hotZone, CGSize(width: 72, height: 32))
        XCTAssertEqual(DwellChrome.pillHeight, 28)
        XCTAssertEqual(DwellChrome.pillCornerRadius, 8)
        XCTAssertEqual(DwellChrome.dwell, 0.35)
        XCTAssertEqual(DwellChrome.hideDelay, 0.6)
        XCTAssertEqual(DwellChrome.pillFade, 0.15)
        XCTAssertEqual(DwellChrome.tolerance, 3)
    }

    func testAlwaysVisibleMeansNoDwellAndTheChromeStaysUp() {
        XCTAssertTrue(ImmersiveChrome.alwaysVisible(.alwaysVisible))
        XCTAssertFalse(ImmersiveChrome.usesDwell(alwaysVisible: true))
        XCTAssertTrue(ImmersiveChrome.showsPill(alwaysVisible: true, dwellShown: false))
        for delay in [RevealDelay.instantly, .short, .long] {
            XCTAssertFalse(ImmersiveChrome.alwaysVisible(delay))
            XCTAssertTrue(ImmersiveChrome.usesDwell(alwaysVisible: false))
            XCTAssertFalse(ImmersiveChrome.showsPill(alwaysVisible: false, dwellShown: false))
            XCTAssertTrue(ImmersiveChrome.showsPill(alwaysVisible: false, dwellShown: true))
        }
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

final class ChromeBarTests: XCTestCase {
    /// The 28 pt row (the Immersive pill, the covers' top row): the 14 pt
    /// lights equally inset 7 pt. BarGeometryTests covers the numbers.
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
        let bar = WindowStyle.compact.insets(fullScreen: false).top
        let portrait = PhoneChrome.zoomFrame(phone: CGSize(width: 1080, height: 2340),
                                             style: .compact, visible: visible)
        XCTAssertEqual(portrait.height, visible.height, accuracy: 1)
        XCTAssertEqual(portrait.width, (visible.height - bar) * 1080 / 2340, accuracy: 1)
        XCTAssertEqual(portrait.midX, visible.midX, accuracy: 1)
        XCTAssertEqual(portrait.midY, visible.midY, accuracy: 1)

        let landscape = PhoneChrome.zoomFrame(phone: CGSize(width: 2340, height: 1080),
                                              style: .compact, visible: visible)
        XCTAssertEqual(landscape.width, visible.width, accuracy: 1)
        XCTAssertEqual(landscape.height, visible.width * 1080 / 2340 + bar, accuracy: 1)
        XCTAssertTrue(visible.contains(landscape), "the zoom stays inside the screen")
        XCTAssertTrue(visible.contains(portrait), "the zoom stays inside the screen")

        let compact = PhoneChrome.zoomFrame(phone: CGSize(width: 1080, height: 2340),
                                              style: .compact, visible: visible)
        XCTAssertEqual(compact.height, visible.height, accuracy: 1, "no bar to subtract")
    }

    func testThePhoneFrameKeepsThePhonesAspectRatioInTheStream() {
        let phone = CGSize(width: 1080, height: 2400)
        let pad = WindowStyle.compact.windowSize(stream: .zero)
        XCTAssertEqual(PhoneChrome.frame(proposed: CGSize(width: 540 + pad.width, height: 1100),
                                         phone: phone, style: .compact),
                       CGSize(width: 540 + pad.width, height: 1200 + pad.height), "the width led")
        XCTAssertEqual(PhoneChrome.frame(proposed: CGSize(width: 450 + pad.width, height: 1200 + pad.height),
                                         phone: phone, style: .compact),
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
            let size = PhoneChrome.frame(proposed: proposed, phone: phone, style: .compact)
            let stream = WindowStyle.compact.streamSize(window: size)
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
        let stream = WindowStyle.compact.streamSize(window: size)
        XCTAssertEqual(stream.width / stream.height,
                       phoneShape.width / phoneShape.height, accuracy: 0.005,
                       message, file: file, line: line)
    }

    /// The person's own frame: the bottom edge dragged from 754 to 600 pt.
    func testTheBottomEdgeDragShrinksThePhoneWindowToTheHeight() {
        let size = PhoneChrome.frame(proposed: CGSize(width: 335, height: 600),
                                     phone: phoneShape, style: .compact, edge: .bottom)
        XCTAssertEqual(size.height, 600, accuracy: 0.5, "the bottom edge sets the height")
        assertPhoneShaped(size, "the width follows the phone's aspect")
    }

    func testTheRightEdgeDragShrinksThePhoneWindowToTheWidth() {
        let size = PhoneChrome.frame(proposed: CGSize(width: 280, height: 754),
                                     phone: phoneShape, style: .compact, edge: .right)
        XCTAssertEqual(size.width, 280, accuracy: 0.5, "the right edge sets the width")
        assertPhoneShaped(size, "the height follows the phone's aspect")
    }

    func testTheTopAndLeftEdgesLeadTheSameWay() {
        let top = PhoneChrome.frame(proposed: CGSize(width: 335, height: 600),
                                    phone: phoneShape, style: .compact, edge: .top)
        XCTAssertEqual(top.height, 600, accuracy: 0.5, "the top edge sets the height")
        assertPhoneShaped(top, "the width follows the top edge's height")

        let left = PhoneChrome.frame(proposed: CGSize(width: 280, height: 754),
                                     phone: phoneShape, style: .compact, edge: .left)
        XCTAssertEqual(left.width, 280, accuracy: 0.5, "the left edge sets the width")
        assertPhoneShaped(left, "the height follows the left edge's width")
    }

    /// A corner keeps the v104 larger-area rule: it may shrink both dimensions.
    func testACornerDragInwardShrinksBothDimensions() {
        let size = PhoneChrome.frame(proposed: CGSize(width: 280, height: 600),
                                     phone: phoneShape, style: .compact, edge: .bottomRight)
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
                                         style: .compact, edge: .bottom)
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
        let stream = WindowStyle.compact.streamSize(window: frame.size)
        XCTAssertEqual(stream.width / stream.height,
                       phoneShape.width / phoneShape.height, accuracy: 0.005,
                       message, file: file, line: line)
    }

    /// The person's own case: a saved frame wider than the phone's shape.
    func testAWrongShapedSavedFrameOpensInThePhonesShape() {
        let saved = NSRect(x: 120, y: 300, width: 432, height: 870)
        let frame = PhoneChrome.restoredFrame(saved: saved, phone: phoneShape,
                                              style: .compact, visible: visible)
        assertStreamAspect(frame, "the saved frame opens at the phone's aspect")
        XCTAssertEqual(frame.minX, saved.minX, accuracy: 0.5, "the left edge stays")
        XCTAssertEqual(frame.maxY, saved.maxY, accuracy: 0.5, "the top edge stays")
        XCTAssertEqual(frame.height, saved.height, accuracy: 0.5,
                       "the remembered height leads")
    }

    func testASavedLandscapeFrameForAPortraitPhoneOpensPortrait() {
        let saved = NSRect(x: 200, y: 100, width: 800, height: 400)
        let frame = PhoneChrome.restoredFrame(saved: saved, phone: phoneShape,
                                              style: .compact, visible: visible)
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
                                              style: .compact, visible: visible)
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
        let video = WindowStyle.compact.streamSize(window: current.size)

        XCTAssertEqual(PhoneChrome.PictureFit.decide(video: video, picture: picture, isDragging: false),
                       .refitNow)
        let refit = PhoneChrome.refitFrame(current: current, picture: picture, style: .compact)
        assertStreamAspect(refit, "the refit makes the video area the picture's shape")
        XCTAssertEqual(refit.minX, current.minX, accuracy: 0.5, "the left edge stays")
        XCTAssertEqual(refit.maxY, current.maxY, accuracy: 0.5, "the top edge stays")
        XCTAssertEqual(refit.height, current.height, accuracy: 0.5, "the height stays")
        XCTAssertEqual(PhoneChrome.PictureFit.decide(
            video: WindowStyle.compact.streamSize(window: refit.size),
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

/// The View menu's style group (MENU-4): ⌥⌘F is the group's key and always
/// means "the next style", whichever item holds it when the press arrives —
/// before, a press from Compact picked the item that carried the key
/// (Framed) or nothing, and the cycle never reached Immersive (issue #45).
final class StyleMenuPickTests: XCTestCase {
    func testTheGroupsKeyAlwaysCyclesAndAClickPicks() {
        for current in WindowStyle.allCases {
            for picked in WindowStyle.allCases {
                XCTAssertEqual(WindowStyle.menuPick(picked, current: current, fromStyleKey: true), .next,
                               "⌥⌘F from \(current) on the \(picked) item")
            }
        }
        XCTAssertEqual(WindowStyle.menuPick(.compact, current: .compact, fromStyleKey: false), .next,
                       "re-picking the checked item is the group's key")
        XCTAssertEqual(WindowStyle.menuPick(.immersive, current: .compact, fromStyleKey: false),
                       .set(.immersive), "a click on another item picks it")
    }

    func testTheCycleVisitsEveryStyleInMenuOrder() {
        XCTAssertEqual(WindowStyle.framed.next, .compact)
        XCTAssertEqual(WindowStyle.compact.next, .immersive)
        XCTAssertEqual(WindowStyle.immersive.next, .framed)
    }

    @MainActor func testOnlyOptionCommandFIsTheGroupsKey() throws {
        func key(_ chars: String, _ flags: NSEvent.ModifierFlags) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                                           timestamp: 0, windowNumber: 0, context: nil,
                                           characters: chars, charactersIgnoringModifiers: chars,
                                           isARepeat: false, keyCode: 3))
        }
        XCTAssertTrue(WindowStyle.isGroupKey(try key("f", [.command, .option])))
        XCTAssertFalse(WindowStyle.isGroupKey(try key("f", [.command])), "⌘F is the phone's")
        XCTAssertFalse(WindowStyle.isGroupKey(try key("f", [.command, .control])), "⌃⌘F is full screen")
        XCTAssertFalse(WindowStyle.isGroupKey(nil), "a menu click has no key")
    }
}
