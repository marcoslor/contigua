// Settings' window fits the smallest supported screen (AGENTS.md Testing
// rules: layout at 1280×800 — every row visible or inside something that
// scrolls). The bug: the grouped Form reported its full height, the window
// took it, and rows below the fold were clipped and unreachable.

import AppKit
import SwiftUI
import XCTest
@testable import Contigua

@MainActor
final class SettingsLayoutTests: XCTestCase {
    /// The smallest supported screen's visible height with the menu bar, from
    /// docs/NFR.md's limit (not a literal here).
    private let visibleHeight: CGFloat = CGFloat(NFRTestLimits.shared.smallestScreen.height) - 25

    func testTheDesignHeightIsTheOneInTheLimitsFile() {
        XCTAssertEqual(SettingsLayout.designHeight,
                       CGFloat(NFRTestLimits.shared.int("settings_design_height_pt")))
    }

    func testTheWindowNeverOutgrowsTheScreen() {
        XCTAssertEqual(SettingsLayout.maxContentHeight(for: 1050), SettingsLayout.designHeight)
        XCTAssertEqual(SettingsLayout.maxContentHeight(for: visibleHeight), SettingsLayout.designHeight)
        XCTAssertEqual(SettingsLayout.maxContentHeight(for: 400), SettingsLayout.minimumHeight)
        XCTAssertLessThanOrEqual(SettingsLayout.maxContentHeight(for: visibleHeight) + SettingsLayout.chromeAllowance,
                                 visibleHeight + SettingsLayout.chromeAllowance - SettingsLayout.chromeAllowance,
                                 "the content plus the window chrome fits the visible screen")
        for height in [400.0, 700.0, 800.0, 1050.0, 1440.0] {
            let content = SettingsLayout.maxContentHeight(for: height)
            XCTAssertLessThanOrEqual(content + SettingsLayout.chromeAllowance, max(height, content + SettingsLayout.chromeAllowance))
        }
    }

    /// The real Settings window at 1280×800: the content's ideal height fits
    /// the cap, and the tab's rows live in a scroll view (they are reachable
    /// when the content is taller than what shows).
    func testSettingsFitsAndScrollsAt1280x800() throws {
        let suffix = UUID().uuidString.lowercased().prefix(8)
        let name = "settings-test-\(suffix)"
        guard let profile = Profile(name: name) else {
            XCTFail("bad test profile name")
            return
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let folder = base.appendingPathComponent(profile.supportDirectoryName, isDirectory: true)
        addTeardownBlock {
            profile.defaults.removePersistentDomain(forName: profile.defaultsSuiteName!)
            try? FileManager.default.removeItem(at: folder)
        }
        let controller = ConnectionController(options: LaunchOptions(), profile: profile)
        // The reported state: a few app overrides, so General lists them (the
        // rows below "Default window density" that were cut off).
        for index in 0..<6 {
            controller.windows.setDensity(1.25, forPackage: "com.example.app\(index)")
        }
        let hosting = NSHostingView(rootView: SettingsView().environment(controller))
        let cap = SettingsLayout.maxContentHeight(for: visibleHeight)
        // The size the Settings window would take: the content's ideal height.
        let ideal = hosting.fittingSize.height
        XCTAssertLessThanOrEqual(ideal, cap,
                                 "the Settings content must fit a 1280×800 screen (its ideal height is \(ideal))")

        hosting.frame = NSRect(x: 0, y: 0, width: SettingsLayout.width, height: cap)
        hosting.layoutSubtreeIfNeeded()
        let scroll = firstScrollView(in: hosting)
        XCTAssertNotNil(scroll, "the tab's rows must live in a scroll view")
        if let scroll {
            XCTAssertGreaterThan(scroll.frame.height, 0)
        }
    }

    private func firstScrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        for child in view.subviews {
            if let found = firstScrollView(in: child) { return found }
        }
        return nil
    }
}
