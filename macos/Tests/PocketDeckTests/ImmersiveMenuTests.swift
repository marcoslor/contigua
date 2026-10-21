// View ▸ Immersive's model and the Always Visible chrome rule
// (docs/design/mac-redesign.md §3.8), plus the force click's decision
// (docs/design/livetext.md "Force click").

import AppKit
import XCTest
@testable import PocketDeck

final class ImmersiveMenuTests: XCTestCase {
    func testTheSubmenuIsTheDelaysThenAlwaysVisible() {
        XCTAssertEqual(ImmersiveMenuModel.items.map(\.title),
                       ["Instantly", "Short", "Long", "", "Always Visible"])
        XCTAssertEqual(ImmersiveMenuModel.items[3], .separator)
    }

    func testTheCheckFollowsTheStoredChoice() {
        for delay in [RevealDelay.instantly, .short, .long, .alwaysVisible] {
            let checked = ImmersiveMenuModel.items.filter { ImmersiveMenuModel.isChecked($0, reveal: delay) }
            XCTAssertEqual(checked.count, 1, "exactly one item is checked for \(delay)")
            if delay == .alwaysVisible {
                XCTAssertEqual(checked.first, .alwaysVisible)
            } else {
                XCTAssertEqual(checked.first, .delay(delay))
            }
        }
        XCTAssertFalse(ImmersiveMenuModel.isChecked(.separator, reveal: .short))
    }

    func testAPickStoresTheChoiceAndSwitchesToImmersive() {
        for item in ImmersiveMenuModel.items where item != .separator {
            guard let pick = ImmersiveMenuModel.pick(item) else {
                XCTFail("no pick for \(item)")
                continue
            }
            XCTAssertEqual(pick.style, .immersive)
        }
        XCTAssertEqual(ImmersiveMenuModel.pick(.delay(.long))?.reveal, .long)
        XCTAssertEqual(ImmersiveMenuModel.pick(.alwaysVisible)?.reveal, .alwaysVisible)
        XCTAssertNil(ImmersiveMenuModel.pick(.separator))
    }

    func testTheParentIsCheckedOnlyWhenImmersive() {
        XCTAssertTrue(ImmersiveMenuModel.parentChecked(style: .immersive))
        XCTAssertFalse(ImmersiveMenuModel.parentChecked(style: .framed))
    }

    func testAlwaysVisibleMeansNoDwellAndTheChromeStaysUp() {
        XCTAssertTrue(ImmersiveChrome.alwaysVisible(.alwaysVisible))
        XCTAssertFalse(ImmersiveChrome.usesDwell(alwaysVisible: true))
        XCTAssertTrue(ImmersiveChrome.showsPill(alwaysVisible: true, dwellShown: false))
        for delay in [RevealDelay.instantly, .short, .long] {
            XCTAssertFalse(ImmersiveChrome.alwaysVisible(delay))
            XCTAssertTrue(ImmersiveChrome.usesDwell(alwaysVisible: false))
            XCTAssertEqual(ImmersiveChrome.showsPill(alwaysVisible: false, dwellShown: false), false)
            XCTAssertEqual(ImmersiveChrome.showsPill(alwaysVisible: false, dwellShown: true), true)
        }
    }

    func testTheStoredValueRoundTripsIncludingAlwaysVisible() {
        let name = "dev.pocketdeck.tests.reveal.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        XCTAssertEqual(RevealDelay.stored(in: defaults), .short)
        defaults.set(RevealDelay.alwaysVisible.rawValue, forKey: RevealDelay.key)
        XCTAssertEqual(RevealDelay.stored(in: defaults), .alwaysVisible)
        XCTAssertEqual(RevealDelay.alwaysVisible.seconds, 0)
        XCTAssertTrue(RevealDelay.alwaysVisible.keepsChromeVisible)
        XCTAssertFalse(RevealDelay.short.keepsChromeVisible)
    }
    /// The View menu is SwiftUI's, and the style pair and Hide Controls are
    /// AppKit's. A SwiftUI rebuild replaces every item and dropped Immersive in
    /// v104; they are put back, in the design's order, and never lose their
    /// state.
    @MainActor
    func testTheItemsComeBackAfterTheViewMenuRebuilds() throws {
        _ = NSApplication.shared
        let main = NSMenu()
        let view = NSMenu(title: "View")
        let root = NSMenuItem(title: "View", action: nil, keyEquivalent: "")
        root.submenu = view
        main.addItem(root)
        view.addItem(NSMenuItem(title: "Live Text", action: nil, keyEquivalent: ""))
        view.addItem(.separator())
        view.addItem(NSMenuItem(title: "Density", action: nil, keyEquivalent: ""))
        let saved = NSApp.mainMenu
        NSApp.mainMenu = main
        defer { NSApp.mainMenu = saved }

        func titles() -> [String] {
            view.items.map { $0.isSeparatorItem ? "—" : $0.title }
        }
        ImmersiveMenuInstaller.shared.ensureInstalled()
        XCTAssertEqual(titles(), ["Live Text", "—", "Framed", "Immersive", "Hide Controls", "Density"])

        // SwiftUI rebuilds the View menu from its own items: the AppKit items
        // are gone and every SwiftUI item is a new instance.
        for item in view.items where ImmersiveMenuInstaller.titles.contains(item.title) {
            view.removeItem(item)
        }
        XCTAssertEqual(titles(), ["Live Text", "—", "Density"])

        ImmersiveMenuInstaller.shared.ensureInstalled()
        XCTAssertEqual(titles(), ["Live Text", "—", "Framed", "Immersive", "Hide Controls", "Density"])
        let framed = try XCTUnwrap(view.items.first { $0.title == "Framed" })
        let immersive = try XCTUnwrap(view.items.first { $0.title == "Immersive" })
        XCTAssertNil(framed.submenu, "a radio item is not a submenu parent")
        XCTAssertNil(immersive.submenu, "Immersive is a radio item, not a submenu parent")
        let hide = try XCTUnwrap(view.items.first { $0.title == "Hide Controls" })
        let sub = hide.submenu?.items.map { $0.isSeparatorItem ? "—" : $0.title } ?? []
        XCTAssertEqual(sub, ["Instantly", "Short", "Long", "—", "Always Visible"])
    }

}
