// The marks SwiftUI cannot keep (MenuMarks.swift): the rules as values, and the
// one side effect that writes them onto the items SwiftUI already built.

import AppKit
import XCTest
@testable import Contigua

final class MenuMarksTests: XCTestCase {
    /// The View menu as the commands build it.
    private var viewItems: [MenuMarks.Item] {
        [
            MenuMarks.Item(title: "Find Apps"),
            MenuMarks.Item(title: "", isSeparator: true),
            MenuMarks.Item(title: "Framed"),
            MenuMarks.Item(title: "Immersive"),
            MenuMarks.Item(title: "Minimal"),
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
                       iconSize: CGFloat = 1,
                       phoneWindow: Bool = false,
                       phoneOffline: Bool = false) -> StreamMenuState {
        let state = StreamMenuState()
        if hasStream {
            state.handle(.streamBecameKey(StreamMenuValues(
                stream: 1, style: style, liveText: liveText, frozen: frozen,
                phoneOffline: phoneOffline, phoneWindow: phoneWindow,
                densityPackage: package, densityOverride: density)))
        }
        state.revealDelay = reveal
        state.showTouches = touches
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

    // MARK: The styles

    func testTheStylesFollowTheKeyWindowsStyle() {
        let immersive = edits(state(style: .immersive))
        XCTAssertTrue(immersive.contains(.mark(["Framed"], false)))
        XCTAssertTrue(immersive.contains(.mark(["Immersive"], true)))
        XCTAssertTrue(immersive.contains(.enable(["Hide Controls"], false)),
                      "Hide Controls is the Minimal pill's choice and is disabled on Immersive")

        let framed = edits(state(style: .framed))
        XCTAssertTrue(framed.contains(.mark(["Framed"], true)))
        XCTAssertTrue(framed.contains(.mark(["Immersive"], false)))
        XCTAssertTrue(framed.contains(.enable(["Hide Controls"], false)),
                      "Hide Controls is disabled on Framed")

        let minimal = edits(state(style: .minimal))
        XCTAssertTrue(minimal.contains(.mark(["Minimal"], true)))
        XCTAssertTrue(minimal.contains(.mark(["Framed"], false)))
        XCTAssertTrue(minimal.contains(.enable(["Hide Controls"], true)),
                      "Hide Controls is enabled on Minimal")
        XCTAssertTrue(minimal.contains(.enable(["Hide Controls", "Short"], true)))
        XCTAssertTrue(minimal.contains(.enable(["Hide Controls", "Always Visible"], true)))
    }

    /// Exactly one of the three is on, whatever the state: no state leaves two
    /// checked or none.
    func testExactlyOneOfTheStylesIsChecked() {
        for style in WindowStyle.allCases {
            let marks = edits(state(style: style)).filter {
                if case .mark(let path, _) = $0 { return MenuModel.styles.map(\.label).contains(path.first ?? "") }
                return false
            }
            XCTAssertEqual(marks.count, 3)
            let on = marks.filter { if case .mark(_, let on) = $0 { return on }; return false }
            XCTAssertEqual(on.count, 1, "\(style) checks exactly one")
        }
    }

    /// The styles act on the key stream window. With the Deck (or nothing) key
    /// nothing is checked and all are disabled, whatever style was last used.
    func testTheStylesAreDisabledAndUncheckedWithNoStreamWindow() {
        for style in WindowStyle.allCases {
            let rules = edits(state(style: style, hasStream: false))
            for label in MenuModel.styles.map(\.label) {
                XCTAssertTrue(rules.contains(.mark([label], false)), "\(style) \(label)")
                XCTAssertTrue(rules.contains(.enable([label], false)), "\(style) \(label)")
            }
        }
        let withStream = edits(state(style: .framed))
        for label in MenuModel.styles.map(\.label) {
            XCTAssertTrue(withStream.contains(.enable([label], true)), label)
        }
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
        for label in MenuModel.styles.map(\.label) {
            XCTAssertTrue(writes.contains(.mark([label], false)), label)
            XCTAssertTrue(writes.contains(.enable([label], false)), label)
        }
        XCTAssertTrue(writes.contains(.enable(["Hide Controls"], false)))
        XCTAssertFalse(writes.contains(.enable(["Hide Controls", "Short"], true)),
                       "the submenu's own items follow the parent")
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

    /// [DECK-6] A profile with no stored choice marks the default, 125 %, when
    /// the menu opens: the mark is read from the profile at that moment, not
    /// from a launch-time value.
    @MainActor
    func testAFreshProfilesIconSizeMarkIsTheDefault() {
        let defaults = Profile.active.defaults
        let saved = defaults.object(forKey: DeckZoom.key)
        defer {
            if let saved { defaults.set(saved, forKey: DeckZoom.key) }
            else { defaults.removeObject(forKey: DeckZoom.key) }
        }
        defaults.removeObject(forKey: DeckZoom.key)

        let main = NSMenu(title: "main")
        let view = NSMenu(title: "View")
        let icon = NSMenu(title: "Icon Size")
        for option in DeckZoom.options {
            icon.addItem(withTitle: MenuModel.iconSizeTitle(option), action: nil, keyEquivalent: "")
        }
        let iconItem = NSMenuItem(title: "Icon Size", action: nil, keyEquivalent: "")
        iconItem.submenu = icon
        view.addItem(iconItem)
        let viewItem = NSMenuItem(title: "View", action: nil, keyEquivalent: "")
        viewItem.submenu = view
        main.addItem(viewItem)

        MenuMarks.apply(to: main)

        let checked = icon.items.filter { $0.state == .on }.map(\.title)
        XCTAssertEqual(checked, [MenuModel.iconSizeTitle(DeckZoom.defaultValue)],
                       "a fresh profile checks the default, 125 %")
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
        let savedMachine = shared.machine
        let saved = (shared.revealDelay, shared.showTouches, shared.deckZoom)
        let defaults = Profile.active.defaults
        let savedZoom = defaults.object(forKey: DeckZoom.key)
        defer {
            shared.handle(.reset)
            if let values = savedMachine.values { shared.handle(.streamBecameKey(values)) }
            shared.revealDelay = saved.0; shared.showTouches = saved.1; shared.deckZoom = saved.2
            if let savedZoom { defaults.set(savedZoom, forKey: DeckZoom.key) }
            else { defaults.removeObject(forKey: DeckZoom.key) }
        }
        defaults.set(1.25, forKey: DeckZoom.key)
        shared.handle(.streamBecameKey(StreamMenuValues(
            stream: 1, style: .immersive, densityPackage: "com.android.settings")))
        shared.revealDelay = .alwaysVisible

        let main = NSMenu(title: "main")
        let view = NSMenu(title: "View")
        view.addItem(withTitle: "Framed", action: nil, keyEquivalent: "")
        view.addItem(withTitle: "Immersive", action: nil, keyEquivalent: "")
        view.addItem(withTitle: "Minimal", action: nil, keyEquivalent: "")
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
        XCTAssertEqual(view.items.first { $0.title == "Minimal" }?.state, .off)
        XCTAssertEqual(hideItem.isEnabled, false, "Hide Controls is disabled on Immersive")
        XCTAssertEqual(hide.items.first { $0.title == "Always Visible" }?.state, .on,
                       "the stored choice's mark still shows, greyed")
        XCTAssertEqual(hide.items.first { $0.title == "Short" }?.state, .off)
        XCTAssertEqual(hide.items.first { $0.title == "Always Visible" }?.isEnabled, false)
        XCTAssertEqual(hide.items.first { $0.title == "Short" }?.isEnabled, false)
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
        XCTAssertEqual(MenuMarks.phoneEdits(items: items, phone: phone, stream: StreamMenuState()),
                       [.enable(["Phone Mirror"], true),
                        .handoff(title: "Open Current App on Mac", enabled: true, help: nil)])
        phone.connection = .idle
        XCTAssertEqual(MenuMarks.phoneEdits(items: items, phone: phone, stream: StreamMenuState()),
                       [.enable(["Phone Mirror"], false),
                        .handoff(title: "Open Current App on Mac", enabled: false,
                                 help: "Connect your phone to use these.")])
        phone.connection = .reconnecting
        XCTAssertEqual(MenuMarks.phoneEdits(items: items, phone: phone, stream: StreamMenuState()),
                       [.enable(["Phone Mirror"], false),
                        .handoff(title: "Open Current App on Mac", enabled: false,
                                 help: "Connect your phone to use these.")])
    }

    /// Turn Off Phone Screen acts on the key phone window, so with the Deck (or
    /// any non-stream window) key it is disabled; the phone's own items keep
    /// their rule (MENU-5, ISS-88).
    @MainActor
    func testTurnOffPhoneScreenIsForTheKeyPhoneWindowOnly() {
        let items = [MenuMarks.Item(title: "Turn Off Phone Screen")]
        let phone = PhoneControlsState()
        let deck = MenuMarks.phoneEdits(items: items, phone: phone,
                                        stream: state(hasStream: false))
        XCTAssertTrue(deck.contains(.enable(["Turn Off Phone Screen"], false)))
        let key = MenuMarks.phoneEdits(items: items, phone: phone,
                                       stream: state(phoneWindow: true))
        XCTAssertTrue(key.contains(.enable(["Turn Off Phone Screen"], true)))
        let offline = MenuMarks.phoneEdits(items: items, phone: phone,
                                           stream: state(phoneWindow: true, phoneOffline: true))
        XCTAssertTrue(offline.contains(.enable(["Turn Off Phone Screen"], false)))
    }

    /// The handoff item names the app a fresh reply reports, falls back when
    /// there is none, and says why when a fresh reply says there is nothing to
    /// open (PANEL-28).
    @MainActor
    func testTheHandoffItemFollowsThePhonesSubject() {
        var phone = PhoneControlsState()
        phone.connection = .online
        let fallback = MenuMarks.Edit.handoff(title: "Open Current App on Mac", enabled: true, help: nil)
        XCTAssertEqual(MenuMarks.phoneEdits(items: [], phone: phone, stream: StreamMenuState()).last, fallback)

        phone.handoff = FrontAppRow(pkg: "p.maps", label: "Maps", icon: nil)
        phone.frontFresh = true
        XCTAssertEqual(MenuMarks.phoneEdits(items: [], phone: phone, stream: StreamMenuState()).last,
                       .handoff(title: "Open Maps on Mac", enabled: true, help: nil))

        phone.handoff = nil
        phone.frontNone = true
        XCTAssertEqual(MenuMarks.phoneEdits(items: [], phone: phone, stream: StreamMenuState()).last,
                       .handoff(title: "Open Current App on Mac", enabled: false,
                                help: FrontAppRow.nothingToOpen))
    }

    // MARK: A pass that must finish (ISS-93)

    /// A main menu with a View menu, no Navigate: the pass must still correct
    /// View and go on. The shared state is reset to the Deck key so the
    /// expected values do not depend on another test.
    @MainActor
    private func makeBar(view items: [NSMenuItem]) -> NSMenu {
        let main = NSMenu(title: "main")
        let viewMenu = NSMenu(title: "View")
        for item in items { viewMenu.addItem(item) }
        let viewItem = NSMenuItem(title: "View", action: nil, keyEquivalent: "")
        viewItem.submenu = viewMenu
        main.addItem(viewItem)
        StreamMenuState.shared.handle(.reset)
        StreamMenuState.shared.showTouches = false
        StreamMenuState.shared.deckZoom = 1
        return main
    }

    private func item(_ title: String, _ menu: NSMenu) -> NSMenuItem? {
        menu.items.first { $0.title == title }
    }

    /// ISS-93: a pass whose item lookup fails must not stop the rest. The item
    /// that is missing is reported once, named by its menu, and every later
    /// edit still lands.
    @MainActor
    func testAMissingItemIsReportedOnceAndThePassGoesOn() {
        let immersive = NSMenuItem(title: "Immersive", action: nil, keyEquivalent: "")
        immersive.state = .on
        immersive.isEnabled = true
        let touches = NSMenuItem(title: "Show Touches", action: nil, keyEquivalent: "")
        touches.state = .on
        touches.isEnabled = true
        let live = NSMenuItem(title: "Live Text", action: nil, keyEquivalent: "")
        live.state = .on
        live.isEnabled = true
        let main = makeBar(view: [immersive, touches, live])
        let view = main.items.first { $0.title == "View" }!.submenu!

        // A pass over the bar still corrects every item it has, even while one
        // menu of the bar is absent (no Navigate here).
        XCTAssertEqual(MenuMarks.apply(to: main), [])
        XCTAssertEqual(item("Immersive", view)?.state, .off)
        XCTAssertEqual(item("Immersive", view)?.isEnabled, false)
        XCTAssertEqual(item("Show Touches", view)?.state, .off)
        XCTAssertEqual(item("Show Touches", view)?.isEnabled, false)
        XCTAssertEqual(item("Live Text", view)?.state, .off)
        XCTAssertEqual(item("Live Text", view)?.isEnabled, false)

        // A missing item is one skipped write, never the end of the pass: it is
        // named "View ▸ Framed", and the next edit on the same menu still lands.
        XCTAssertEqual(MenuMarks.apply(.mark(["Framed"], true), in: view, named: "View"),
                       "View ▸ Framed")
        XCTAssertNil(MenuMarks.apply(.enable(["Show Touches"], true), in: view, named: "View"))
        XCTAssertTrue(item("Show Touches", view)!.isEnabled)
    }

    /// ISS-93: AppKit posts didBeginTracking before SwiftUI installs the command
    /// items it rebuilt since the last open. The correction is deferred to the
    /// end of that turn, so the install that follows cannot replace it: the
    /// items an open menu shows are the key window's values, not the launch's.
    @MainActor
    func testTheCorrectionLandsAfterTheOpenInstallsTheItems() {
        let framed = NSMenuItem(title: "Framed", action: nil, keyEquivalent: "")
        let immersive = NSMenuItem(title: "Immersive", action: nil, keyEquivalent: "")
        let touches = NSMenuItem(title: "Show Touches", action: nil, keyEquivalent: "")
        let main = makeBar(view: [framed, immersive, touches])
        let view = main.items.first { $0.title == "View" }?.submenu
        // The launch's values: the style pair checked and enabled, touches on.
        framed.state = .on
        framed.isEnabled = true
        immersive.isEnabled = true
        touches.state = .on
        touches.isEnabled = true
        NSApplication.shared.mainMenu = main
        defer { NSApplication.shared.mainMenu = nil }

        MenuMarks.correctAfterTheOpen()
        // The install a real open runs after the notification, in the same turn.
        framed.state = .on
        framed.isEnabled = true
        immersive.isEnabled = true
        touches.state = .on
        touches.isEnabled = true
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))

        XCTAssertEqual(item("Framed", view!)?.state, .off)
        XCTAssertEqual(item("Framed", view!)?.isEnabled, false)
        XCTAssertEqual(item("Immersive", view!)?.isEnabled, false)
        XCTAssertEqual(item("Show Touches", view!)?.state, .off)
        XCTAssertEqual(item("Show Touches", view!)?.isEnabled, false)
    }
}
