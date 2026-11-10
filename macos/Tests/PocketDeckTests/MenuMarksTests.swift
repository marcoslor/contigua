// The marks SwiftUI cannot keep (MenuMarks.swift): the rules as values, and the
// one side effect that writes them onto the items SwiftUI already built.

import AppKit
import XCTest
@testable import PocketDeck

final class MenuMarksTests: XCTestCase {
    /// The View menu as the commands build it.
    private var viewItems: [MenuMarks.Item] {
        [
            MenuMarks.Item(title: "Find Apps"),
            MenuMarks.Item(title: "", isSeparator: true),
            MenuMarks.Item(title: "Framed"),
            MenuMarks.Item(title: "Immersive"),
            MenuMarks.Item(title: "Hide Controls", children: [
                MenuMarks.Item(title: "Instantly"),
                MenuMarks.Item(title: "Short"),
                MenuMarks.Item(title: "Long"),
                MenuMarks.Item(title: "", isSeparator: true),
                MenuMarks.Item(title: "Always Visible"),
            ]),
            MenuMarks.Item(title: "", isSeparator: true),
            MenuMarks.Item(title: "Show Touches"),
            MenuMarks.Item(title: "Live Text"),
            MenuMarks.Item(title: "", isSeparator: true),
            MenuMarks.Item(title: "Icon Size", children: [
                MenuMarks.Item(title: "75 %"),
                MenuMarks.Item(title: "100 %"),
                MenuMarks.Item(title: "125 %"),
                MenuMarks.Item(title: "150 %"),
            ]),
            MenuMarks.Item(title: "", isSeparator: true),
            MenuMarks.Item(title: "Density", children: [
                MenuMarks.Item(title: "Default (100%)"),
                MenuMarks.Item(title: "", isSeparator: true),
                MenuMarks.Item(title: "75%"),
                MenuMarks.Item(title: "125%"),
                MenuMarks.Item(title: "150%"),
                MenuMarks.Item(title: "", isSeparator: true),
                MenuMarks.Item(title: "Larger"),
                MenuMarks.Item(title: "Smaller"),
                MenuMarks.Item(title: "Actual Size"),
            ]),
        ]
    }

    private func state(style: WindowStyle = .framed,
                       reveal: RevealDelay = .short,
                       touches: Bool = false,
                       liveText: Bool = false,
                       frozen: Bool = false,
                       hasStream: Bool = true,
                       package: String? = "com.android.settings",
                       density: Double? = nil,
                       iconSize: CGFloat = 1) -> StreamMenuState {
        let state = StreamMenuState()
        state.style = style
        state.revealDelay = reveal
        state.showTouches = touches
        state.liveText = liveText
        state.frozen = frozen
        state.hasStream = hasStream
        state.densityPackage = package
        state.densityOverride = density
        state.deckZoom = iconSize
        return state
    }

    private var navigateItems: [MenuMarks.Item] {
        [MenuMarks.Item(title: "Back"), MenuMarks.Item(title: "Home"),
         MenuMarks.Item(title: "Recents")]
    }

    private func edits(_ state: StreamMenuState, menu: String = "View") -> [MenuMarks.Edit] {
        let items = switch menu {
        case "View": viewItems
        case "Navigate": navigateItems
        default: [MenuMarks.Item(title: "Minimize"),
                  MenuMarks.Item(title: "Zoom"),
                  MenuMarks.Item(title: "Enter Full Screen"),
                  MenuMarks.Item(title: "Bring All to Front")]
        }
        return MenuMarks.edits(menu: menu, items: items, state: state)
    }

    // MARK: The style pair

    func testThePairFollowsTheKeyWindowsStyle() {
        let immersive = edits(state(style: .immersive))
        XCTAssertTrue(immersive.contains(.mark(["Framed"], false)))
        XCTAssertTrue(immersive.contains(.mark(["Immersive"], true)))
        XCTAssertTrue(immersive.contains(.enable(["Hide Controls"], true)))

        let framed = edits(state(style: .framed))
        XCTAssertTrue(framed.contains(.mark(["Framed"], true)))
        XCTAssertTrue(framed.contains(.mark(["Immersive"], false)))
        XCTAssertTrue(framed.contains(.enable(["Hide Controls"], false)))
    }

    /// Exactly one of the pair is on, whatever the state: no state leaves both
    /// checked or neither.
    func testExactlyOneOfThePairIsChecked() {
        for style in WindowStyle.allCases {
            let marks = edits(state(style: style)).filter {
                if case .mark(let path, _) = $0 { return path == ["Framed"] || path == ["Immersive"] }
                return false
            }
            XCTAssertEqual(marks.count, 2)
            let on = marks.filter { if case .mark(_, let on) = $0 { return on }; return false }
            XCTAssertEqual(on.count, 1, "\(style) checks exactly one")
        }
    }

    /// The pair acts on the key stream window. With the Deck (or nothing) key
    /// nothing is checked and both are disabled, whatever style was last used.
    func testThePairIsDisabledAndUncheckedWithNoStreamWindow() {
        for style in WindowStyle.allCases {
            let rules = edits(state(style: style, hasStream: false))
            XCTAssertTrue(rules.contains(.mark(["Framed"], false)), "\(style)")
            XCTAssertTrue(rules.contains(.mark(["Immersive"], false)), "\(style)")
            XCTAssertTrue(rules.contains(.enable(["Framed"], false)), "\(style)")
            XCTAssertTrue(rules.contains(.enable(["Immersive"], false)), "\(style)")
        }
        let withStream = edits(state(style: .framed))
        XCTAssertTrue(withStream.contains(.enable(["Framed"], true)))
        XCTAssertTrue(withStream.contains(.enable(["Immersive"], true)))
    }

    // MARK: The Deck (or any non-stream window) key — ISS-88

    /// ISS-88: the Deck key with one stream window open behind it. The stream
    /// window is still framed with Show Touches on, so the state handed to the
    /// rules carries those values; nothing stream-only may be checked or
    /// enabled, because the key window is not a stream window (MENU-4, MENU-9).
    /// The marks are a function of the key window: a value left from the window
    /// behind must not show.
    func testTheDeckKeyLeavesEveryStreamOnlyItemOffAndDisabled() {
        let deck = state(style: .framed, touches: true, liveText: true, hasStream: false,
                         package: "com.android.settings")
        let writes = edits(deck)
        XCTAssertTrue(writes.contains(.mark(["Framed"], false)))
        XCTAssertTrue(writes.contains(.mark(["Immersive"], false)))
        XCTAssertTrue(writes.contains(.enable(["Framed"], false)))
        XCTAssertTrue(writes.contains(.enable(["Immersive"], false)))
        XCTAssertTrue(writes.contains(.enable(["Hide Controls"], false)))
        XCTAssertTrue(writes.contains(.mark(["Show Touches"], false)),
                      "Show Touches is the key stream window's; there is none")
        XCTAssertTrue(writes.contains(.enable(["Show Touches"], false)),
                      "a disabled item eats its key: ⇧⌘T does nothing with the Deck key")
        XCTAssertTrue(writes.contains(.mark(["Live Text"], false)),
                      "Live Text is the key stream window's; there is none")
        XCTAssertTrue(writes.contains(.enable(["Live Text"], false)))
        XCTAssertTrue(writes.contains(.enable(["Density"], false)))
        // The Deck's own items are unchanged: Icon Size is the Deck's stored
        // choice and Find Apps acts on the Deck.
        XCTAssertTrue(writes.contains(.mark(["Icon Size", "100 %"], true)))
        XCTAssertFalse(writes.contains { edit in
            if case .enable(let path, let on) = edit, path == ["Icon Size"] { return !on }
            return false
        })
    }

    /// ISS-88 sweep, MENU-6: Back, Home and Recents act on the key stream
    /// window through its responder chain, so they are off and disabled when
    /// no stream window is key; a stream window keeps today's rule.
    func testNavigateIsDisabledWithoutAStreamWindow() {
        let deck = MenuMarks.edits(menu: "Navigate", items: navigateItems,
                                   state: state(hasStream: false))
        for title in ["Back", "Home", "Recents"] {
            XCTAssertTrue(deck.contains(.enable([title], false)), title)
        }
        let key = MenuMarks.edits(menu: "Navigate", items: navigateItems,
                                  state: state(hasStream: true))
        for title in ["Back", "Home", "Recents"] {
            XCTAssertTrue(key.contains(.enable([title], true)), title)
        }
        let frozen = MenuMarks.edits(menu: "Navigate", items: navigateItems,
                                     state: state(liveText: true, frozen: true))
        for title in ["Back", "Home", "Recents"] {
            XCTAssertTrue(frozen.contains(.enable([title], false)), title)
        }
    }

    // MARK: Hide Controls and its reveal choice

    func testTheRevealChoiceInsideHideControlsFollowsTheStore() {
        let always = edits(state(reveal: .alwaysVisible))
        XCTAssertTrue(always.contains(.mark(["Hide Controls", "Always Visible"], true)))
        for other in ["Instantly", "Short", "Long"] {
            XCTAssertTrue(always.contains(.mark(["Hide Controls", other], false)), other)
        }

        let short = edits(state(reveal: .short))
        XCTAssertTrue(short.contains(.mark(["Hide Controls", "Short"], true)))
        XCTAssertTrue(short.contains(.mark(["Hide Controls", "Always Visible"], false)))
    }

    // MARK: The rest of the View menu

    func testTheViewTogglesAndDensityFollowTheKeyWindow() {
        let key = state(touches: true, liveText: true, density: 1.25)
        let writes = edits(key)
        XCTAssertTrue(writes.contains(.mark(["Show Touches"], true)))
        XCTAssertTrue(writes.contains(.mark(["Live Text"], true)))
        XCTAssertTrue(writes.contains(.mark(["Density", "125%"], true)))
        XCTAssertTrue(writes.contains(.mark(["Density", "Default (100%)"], false)))
        XCTAssertTrue(writes.contains(.mark(["Density", "75%"], false)))
        XCTAssertTrue(writes.contains(.enable(["Density"], true)))

        let noWindow = edits(state(hasStream: false, package: nil))
        XCTAssertTrue(noWindow.contains(.enable(["Density"], false)))
    }

    /// View ▸ Icon Size checks exactly the stored choice, whatever the window
    /// key is: the Deck's size is not a function of the key window (DECK-6).
    func testTheIconSizeCheckmarkFollowsTheStoredChoice() {
        for option in DeckZoom.options {
            let writes = edits(state(iconSize: option))
            for other in DeckZoom.options {
                XCTAssertTrue(writes.contains(.mark(["Icon Size", MenuModel.iconSizeTitle(other)],
                                                    abs(other - option) < 0.0005)),
                              "icon size \(option): \(other) is marked wrong")
            }
        }
        // The checkmark does not depend on a stream window: it is the Deck's.
        let noWindow = edits(state(hasStream: false, package: nil, iconSize: 1.5))
        XCTAssertTrue(noWindow.contains(.mark(["Icon Size", "150 %"], true)))
        XCTAssertTrue(noWindow.contains(.mark(["Icon Size", "100 %"], false)))
    }

    func testTheDefaultDensityItemNamesTheSettingsDefault() {
        let key = state()
        key.settingsDensity = 1.5
        let writes = edits(key)
        XCTAssertTrue(writes.contains(.retitle(["Density", "Default (100%)"], "Default (150%)")))
        XCTAssertTrue(writes.contains(.mark(["Density", "Default (100%)"], true)))
    }

    // MARK: The system's full-screen items

    /// AppKit's own Enter Full Screen (View, last) and its Window tiling
    /// submenu follow the key window themselves. The app writes nothing on
    /// them — a retitle or disable here would fight the system (MENU-4,
    /// MENU-7, MENU-11).
    func testTheSystemFullScreenItemsGetNoEdits() {
        let view = [MenuMarks.Item(title: "Find Apps"),
                    MenuMarks.Item(title: "", isSeparator: true),
                    MenuMarks.Item(title: "Enter Full Screen", keyEquivalent: "f",
                                   modifiers: [.function])]
        XCTAssertEqual(MenuMarks.edits(menu: "View", items: view, state: state()), [])

        let window = [MenuMarks.Item(title: "Minimize"),
                      MenuMarks.Item(title: "Zoom"),
                      MenuMarks.Item(title: "Full Screen Tile", children: [
                          MenuMarks.Item(title: "Left of Screen"),
                          MenuMarks.Item(title: "Right of Screen"),
                      ]),
                      // macOS 26 has shown the same group as an
                      // "Enter Full Screen" parent with children.
                      MenuMarks.Item(title: "Enter Full Screen", children: [
                          MenuMarks.Item(title: "Left of Screen"),
                          MenuMarks.Item(title: "Right of Screen"),
                      ]),
                      MenuMarks.Item(title: "Bring All to Front")]
        XCTAssertEqual(MenuMarks.edits(menu: "Window", items: window, state: state()), [])
    }

    func testAMenuThatIsNotOursGetsNoEdits() {
        XCTAssertEqual(MenuMarks.edits(menu: "File", items: viewItems, state: state()), [])
        XCTAssertEqual(MenuMarks.edits(menu: "Phone", items: viewItems, state: state()), [])
    }

    // MARK: A rebuild cannot make the rules stale

    /// A rebuild can reset a mark to the value the commands were built with.
    /// The rules read the state, never the items' current marks, so the next
    /// call writes the same values again.
    func testTheEditsDoNotDependOnWhatTheItemsShowNow() {
        let key = state(style: .immersive, reveal: .long)
        let launch = edits(key)
        XCTAssertEqual(edits(key), launch)
        XCTAssertEqual(Set(launch.map { String(describing: $0) }).count, launch.count,
                       "no item is written twice")
    }

    /// AppKit's View item carries only fn-F here; the app's ⌃⌘F lives on its
    /// own View item, hidden but allowed to take the key (MENU-8).
    func testTheFullScreenAlternateIsHiddenWithItsKey() {
        let items = [MenuMarks.Item(title: "Enter Full Screen", keyEquivalent: "f",
                                    modifiers: [.control, .command])]
        XCTAssertEqual(MenuMarks.edits(menu: "View", items: items, state: state()),
                       [.hide])
    }

    // MARK: Applying

    @MainActor
    func testApplyingWritesTheValuesOntoSwiftUIsOwnItems() {
        let shared = StreamMenuState.shared
        let saved = (shared.style, shared.revealDelay, shared.showTouches, shared.liveText,
                     shared.hasStream, shared.densityPackage, shared.densityOverride,
                     shared.deckZoom)
        let defaults = Profile.active.defaults
        let savedZoom = defaults.object(forKey: DeckZoom.key)
        defer {
            shared.style = saved.0; shared.revealDelay = saved.1; shared.showTouches = saved.2
            shared.liveText = saved.3; shared.hasStream = saved.4; shared.densityPackage = saved.5
            shared.densityOverride = saved.6; shared.deckZoom = saved.7
            if let savedZoom { defaults.set(savedZoom, forKey: DeckZoom.key) }
            else { defaults.removeObject(forKey: DeckZoom.key) }
        }
        defaults.set(1.25, forKey: DeckZoom.key)
        shared.style = .immersive
        shared.revealDelay = .alwaysVisible
        shared.hasStream = true
        shared.densityPackage = "com.android.settings"
        shared.densityOverride = nil

        let main = NSMenu(title: "main")
        let view = NSMenu(title: "View")
        view.addItem(withTitle: "Framed", action: nil, keyEquivalent: "")
        view.addItem(withTitle: "Immersive", action: nil, keyEquivalent: "")
        let hide = NSMenu(title: "Hide Controls")
        for title in ["Instantly", "Short", "Long", "Always Visible"] {
            hide.addItem(withTitle: title, action: nil, keyEquivalent: "")
        }
        let hideItem = NSMenuItem(title: "Hide Controls", action: nil, keyEquivalent: "")
        hideItem.submenu = hide
        view.addItem(hideItem)
        let iconSize = NSMenu(title: "Icon Size")
        for title in ["75 %", "100 %", "125 %", "150 %"] {
            iconSize.addItem(withTitle: title, action: nil, keyEquivalent: "")
        }
        let iconSizeItem = NSMenuItem(title: "Icon Size", action: nil, keyEquivalent: "")
        iconSizeItem.submenu = iconSize
        view.addItem(iconSizeItem)
        let density = NSMenu(title: "Density")
        for title in ["Default (100%)", "75%", "125%", "150%"] {
            density.addItem(withTitle: title, action: nil, keyEquivalent: "")
        }
        let densityItem = NSMenuItem(title: "Density", action: nil, keyEquivalent: "")
        densityItem.submenu = density
        view.addItem(densityItem)
        let alternate = NSMenuItem(title: "Enter Full Screen", action: nil, keyEquivalent: "f")
        alternate.keyEquivalentModifierMask = [.control, .command]
        view.addItem(alternate)
        let viewItem = NSMenuItem(title: "View", action: nil, keyEquivalent: "")
        viewItem.submenu = view
        main.addItem(viewItem)

        let window = NSMenu(title: "Window")
        let systemFullScreen = NSMenuItem(title: "Enter Full Screen", action: nil, keyEquivalent: "")
        systemFullScreen.isEnabled = false
        window.addItem(systemFullScreen)
        let windowItem = NSMenuItem(title: "Window", action: nil, keyEquivalent: "")
        windowItem.submenu = window
        main.addItem(windowItem)

        let before = (view.items.count, hide.items.count, iconSize.items.count,
                      density.items.count, window.items.count)
        MenuMarks.apply(to: main)

        // Nothing was added or removed: only values changed.
        XCTAssertEqual(view.items.count, before.0)
        XCTAssertEqual(hide.items.count, before.1)
        XCTAssertEqual(iconSize.items.count, before.2)
        XCTAssertEqual(density.items.count, before.3)
        XCTAssertEqual(window.items.count, before.4)

        XCTAssertEqual(view.items.first { $0.title == "Framed" }?.state, .off)
        XCTAssertEqual(view.items.first { $0.title == "Immersive" }?.state, .on)
        XCTAssertEqual(hideItem.isEnabled, true)
        XCTAssertEqual(hide.items.first { $0.title == "Always Visible" }?.state, .on)
        XCTAssertEqual(hide.items.first { $0.title == "Short" }?.state, .off)
        XCTAssertEqual(density.items.first { $0.title.hasPrefix("Default (") }?.state, .on)
        XCTAssertEqual(iconSize.items.first { $0.title == "125 %" }?.state, .on)
        XCTAssertEqual(iconSize.items.first { $0.title == "100 %" }?.state, .off)
        XCTAssertTrue(alternate.isHidden)
        XCTAssertTrue(alternate.allowsKeyEquivalentWhenHidden)
        XCTAssertEqual(alternate.keyEquivalent, "f")
        XCTAssertEqual(alternate.keyEquivalentModifierMask, [.control, .command])
        // The system's item keeps its own title and enablement (MENU-4).
        XCTAssertEqual(systemFullScreen.title, "Enter Full Screen")
        XCTAssertFalse(systemFullScreen.isEnabled)
    }

    /// Phone ▸ Phone Mirror (⌘P) is enabled exactly while the phone is online,
    /// whatever SwiftUI last wrote on the item.
    @MainActor
    func testPhoneMirrorIsEnabledOnlyWhileThePhoneIsOnline() {
        let items = [MenuMarks.Item(title: "Phone Mirror"),
                     MenuMarks.Item(title: "Open Current App on Mac")]
        var phone = PhoneControlsState()
        phone.connection = .online
        XCTAssertEqual(MenuMarks.phoneEdits(items: items, phone: phone),
                       [.enable(["Phone Mirror"], true),
                        .handoff(title: "Open Current App on Mac", enabled: true, help: nil)])
        phone.connection = .idle
        XCTAssertEqual(MenuMarks.phoneEdits(items: items, phone: phone),
                       [.enable(["Phone Mirror"], false),
                        .handoff(title: "Open Current App on Mac", enabled: false,
                                 help: "Connect your phone to use these.")])
        phone.connection = .reconnecting
        XCTAssertEqual(MenuMarks.phoneEdits(items: items, phone: phone),
                       [.enable(["Phone Mirror"], false),
                        .handoff(title: "Open Current App on Mac", enabled: false,
                                 help: "Connect your phone to use these.")])
    }

    /// The handoff item names the app a fresh reply reports, falls back when
    /// there is none, and says why when a fresh reply says there is nothing to
    /// open (PANEL-28).
    @MainActor
    func testTheHandoffItemFollowsThePhonesSubject() {
        var phone = PhoneControlsState()
        phone.connection = .online
        let fallback = MenuMarks.Edit.handoff(title: "Open Current App on Mac", enabled: true, help: nil)
        XCTAssertEqual(MenuMarks.phoneEdits(items: [], phone: phone).last, fallback)

        phone.handoff = FrontAppRow(pkg: "p.maps", label: "Maps", icon: nil)
        phone.frontFresh = true
        XCTAssertEqual(MenuMarks.phoneEdits(items: [], phone: phone).last,
                       .handoff(title: "Open Maps on Mac", enabled: true, help: nil))

        phone.handoff = nil
        phone.frontNone = true
        XCTAssertEqual(MenuMarks.phoneEdits(items: [], phone: phone).last,
                       .handoff(title: "Open Current App on Mac", enabled: false,
                                help: FrontAppRow.nothingToOpen))
    }
}
