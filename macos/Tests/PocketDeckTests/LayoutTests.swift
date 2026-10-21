// Every Settings tab and the Deck on the smallest supported screen
// (docs/NFR.md `layout_min_screen`), in light and dark: each control is inside
// the window or inside something that scrolls. The 10-20 SettingsLayoutTests
// pinned the height; this walks what the person can actually reach.

import AppKit
import SwiftUI
import XCTest
@testable import PocketDeck

@MainActor
final class LayoutTests: XCTestCase {
    private var profile: Profile!
    private var support: URL!
    private var controller: ConnectionController!

    override func setUp() async throws {
        let suffix = UUID().uuidString.lowercased().prefix(8)
        guard let profile = Profile(name: "layout-test-\(suffix)") else {
            XCTFail("bad test profile name")
            return
        }
        self.profile = profile
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        support = base.appendingPathComponent(profile.supportDirectoryName, isDirectory: true)
        controller = ConnectionController(options: LaunchOptions(), profile: profile)
    }

    override func tearDown() async throws {
        profile?.defaults.removePersistentDomain(forName: profile.defaultsSuiteName!)
        if let support { try? FileManager.default.removeItem(at: support) }
    }

    private var smallestScreen: CGSize {
        let screen = NFRTestLimits.shared.smallestScreen
        return CGSize(width: screen.width, height: screen.height)
    }

    /// The menu bar's 25 pt, the same allowance SettingsLayout uses.
    private var visibleHeight: CGFloat { smallestScreen.height - 25 }

    private func firstScrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        for child in view.subviews {
            if let found = firstScrollView(in: child) { return found }
        }
        return nil
    }

    /// The tabs by their settings views: the TabView draws one at a time, so
    /// each is hosted on its own.
    private func tabs() -> [(name: String, view: AnyView)] {
        [("General", AnyView(GeneralSettings())),
         ("Input", AnyView(InputSettings())),
         ("Devices", AnyView(DevicesSettings())),
         ("Automation", AnyView(AutomationSettings()))]
    }

    func testEverySettingsTabFitsAndScrollsAtTheSmallestScreen() throws {
        let size = CGSize(width: SettingsLayout.width,
                          height: SettingsLayout.maxContentHeight(for: visibleHeight))
        for (name, view) in tabs() {
            for dark in [false, true] {
                let hosting = NSHostingView(rootView: AnyView(view.environment(controller)))
                hosting.frame = NSRect(origin: .zero, size: size)
                hosting.layoutSubtreeIfNeeded()
                XCTAssertLessThanOrEqual(hosting.fittingSize.height, size.height,
                                         "Settings \(name) must fit the smallest screen")
                let rep = NFROffscreen.render(hosting, size: size,
                                              appearance: dark ? .darkAqua : .aqua)
                XCTAssertGreaterThan(rep.pixelsWide, 0)
                XCTAssertNotNil(firstScrollView(in: hosting),
                                "Settings \(name) (\(dark ? "dark" : "light")) must scroll its rows")
                let unreachable = NFRReachability.unreachableControls(in: hosting)
                XCTAssertTrue(unreachable.isEmpty,
                              "Settings \(name) (\(dark ? "dark" : "light")): controls outside the window: "
                              + NFRReachability.describe(unreachable, in: hosting))
            }
        }
    }

    func testTheDeckFitsAtTheSmallestScreen() throws {
        XCTAssertTrue(controller.rememberedPhones.isEmpty, "a fresh profile remembers no phone")
        for dark in [false, true] {
            let hosting = NSHostingView(rootView: DeckRoot().environment(controller))
            hosting.frame = NSRect(origin: .zero, size: smallestScreen)
            hosting.layoutSubtreeIfNeeded()
            let rep = NFROffscreen.render(hosting, size: smallestScreen,
                                          appearance: dark ? .darkAqua : .aqua)
            XCTAssertGreaterThan(rep.pixelsWide, Int(smallestScreen.width) - 1)
            let unreachable = NFRReachability.unreachableControls(in: hosting)
            XCTAssertTrue(unreachable.isEmpty,
                          "Deck (\(dark ? "dark" : "light")): controls outside the window: "
                          + NFRReachability.describe(unreachable, in: hosting))
        }
    }
}
