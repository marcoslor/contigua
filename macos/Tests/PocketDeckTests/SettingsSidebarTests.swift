// The Settings sidebar's pure half (branch proto/settings-sidebar): the order
// of the groups, what a phone's row says, and which row the stored preference
// or a route opens. The layouts themselves are proved by the screenshots and
// the shipped tab's e2e; a release build never selects a prototype.

import AppKit
import XCTest
@testable import PocketDeck

@MainActor
final class SettingsSidebarTests: XCTestCase {
    private var suite = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suite = "settings-sidebar-test-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        ProtoSettings.variant = .production
        ProtoSettings.windowWidth = nil
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        ProtoSettings.variant = .production
        ProtoSettings.windowWidth = nil
        super.tearDown()
    }

    /// The three fixture phones the shots stage, with the strings the Devices
    /// tab builds for them (never a person's phones).
    private func phoneRows() -> [DevicePhoneRow] {
        [
            DevicesTabModel.phoneRow(id: "a", name: "Galaxy S25+", model: "SM-S936B",
                                     presence: .connected, lastSeen: "now", inUse: true),
            DevicesTabModel.phoneRow(id: "b", name: "Pixel 9", model: "Pixel 9",
                                     presence: .offline(Date(timeIntervalSinceNow: -7200)),
                                     lastSeen: "2 hours ago", inUse: false),
            DevicesTabModel.phoneRow(id: "c", name: "Pixel 8", model: "Pixel 8",
                                     presence: .pairAgain, lastSeen: "3 days ago", inUse: false),
        ]
    }

    // MARK: order

    func testS1PutsThePhonesFirst() {
        let groups = SettingsSidebarModel.groups(variant: .s1, phones: phoneRows())
        XCTAssertEqual(groups.map(\.title), ["Phones", "This Mac"])
        XCTAssertEqual(groups[0].items.map(\.selection), [.phone("a"), .phone("b"), .phone("c")])
        XCTAssertTrue(groups[0].showsAddPhone)
        XCTAssertEqual(groups[1].items.map(\.title), ["General", "Input", "Automation"])
        XCTAssertFalse(groups[1].showsAddPhone)
    }

    func testS2PutsTheMacSectionsFirst() {
        let groups = SettingsSidebarModel.groups(variant: .s2, phones: phoneRows())
        XCTAssertEqual(groups.map(\.title), ["This Mac", "Phones"])
        XCTAssertEqual(groups[0].items.map(\.title), ["General", "Input", "Automation"])
        XCTAssertEqual(groups[1].items.count, 3)
        XCTAssertTrue(groups[1].showsAddPhone)
    }

    func testS3KeepsOnePhonesEntryBetweenInputAndAutomation() {
        let groups = SettingsSidebarModel.groups(variant: .s3, phones: phoneRows())
        XCTAssertEqual(groups.count, 1)
        XCTAssertNil(groups[0].title)
        XCTAssertEqual(groups[0].items.map(\.title), ["General", "Input", "Phones", "Automation"])
        XCTAssertEqual(groups[0].items[2].selection, .devices)
        XCTAssertFalse(groups[0].showsAddPhone)
    }

    func testProductionDrawsNoSidebar() {
        XCTAssertTrue(SettingsSidebarModel.groups(variant: .production, phones: phoneRows()).isEmpty)
    }

    func testFivePhonesAllStayInTheSidebar() {
        let rows = (0..<5).map { index in
            DevicesTabModel.phoneRow(id: "p\(index)", name: "Phone \(index + 1)", model: "Model",
                                     presence: .offline(nil), lastSeen: "yesterday", inUse: index == 0)
        }
        for variant in [ProtoSettingsVariant.s1, .s2] {
            let groups = SettingsSidebarModel.groups(variant: variant, phones: rows)
            let phones = groups.first { $0.id == "phones" }
            XCTAssertEqual(phones?.items.count, 5, "\(variant) keeps every phone")
            XCTAssertEqual(phones?.showsAddPhone, true, "\(variant) keeps Add Phone…")
        }
    }

    // MARK: row words

    func testAPhoneRowSaysItsStateInWordsAndMarksTheOneInUse() {
        let rows = phoneRows()
        let items = SettingsSidebarModel.groups(variant: .s1, phones: rows)[0].items

        XCTAssertEqual(items[0].subtitle, "Connected")
        XCTAssertTrue(items[0].inUse)
        XCTAssertNil(rows[0].lastSeenText, "a connected phone needs no last-seen time")

        XCTAssertEqual(items[1].subtitle, "Offline · 2 hours ago")
        XCTAssertFalse(items[1].inUse)

        XCTAssertEqual(items[2].subtitle, "Pair again · 3 days ago")
    }

    func testVoiceOverLabelsCarryNameStateLastSeenAndTheInUseMark() {
        let items = SettingsSidebarModel.groups(variant: .s1, phones: phoneRows())[0].items
        XCTAssertEqual(items[0].accessibilityLabel, "Galaxy S25+, Connected, In use")
        XCTAssertEqual(items[1].accessibilityLabel, "Pixel 9, Offline, last seen 2 hours ago")
        XCTAssertEqual(items[2].accessibilityLabel, "Pixel 8, Pair again, last seen 3 days ago")
        XCTAssertEqual(SettingsSidebarModel.addPhoneItem().accessibilityLabel, "Add Phone…")
        XCTAssertFalse(items[0].help.isEmpty, "a row explains itself")
    }

    func testThePhonesEntryCountsThePhones() {
        XCTAssertEqual(SettingsSidebarModel.phoneCountText(0), "None")
        XCTAssertEqual(SettingsSidebarModel.phoneCountText(1), "1 phone")
        XCTAssertEqual(SettingsSidebarModel.phoneCountText(3), "3 phones")
        let entry = SettingsSidebarModel.groups(variant: .s3, phones: phoneRows())[0].items[2]
        XCTAssertEqual(entry.subtitle, "3 phones")
        XCTAssertEqual(entry.accessibilityLabel, "Phones, 3 phones")
    }

    // MARK: selection

    func testTheSelectionRoundTripsThroughTheProfileDefaults() {
        for selection in [SettingsSidebarSelection.general, .input, .automation, .devices, .phone("a")] {
            SettingsSidebarStore.write(selection, to: defaults)
            XCTAssertEqual(SettingsSidebarStore.read(from: defaults), selection)
        }
        SettingsSidebarStore.write(nil, to: defaults)
        XCTAssertNil(SettingsSidebarStore.read(from: defaults))
    }

    func testAnotherProfileStartsWithNoSelection() {
        SettingsSidebarStore.write(.phone("a"), to: defaults)
        let other = UserDefaults(suiteName: "settings-sidebar-test-other-\(UUID().uuidString)")!
        XCTAssertNil(SettingsSidebarStore.read(from: other))
    }

    func testTheStoredSelectionReopens() {
        let stored = SettingsSidebarSelection.phone("b")
        XCTAssertEqual(SettingsSidebarModel.resolve(stored: stored, variant: .s1,
                                                    phones: phoneRows(), inUseId: "a"), .phone("b"))
    }

    func testAForgottenPhoneFallsBackToTheOneInUse() {
        XCTAssertEqual(SettingsSidebarModel.resolve(stored: .phone("gone"), variant: .s1,
                                                    phones: phoneRows(), inUseId: "a"), .phone("a"))
        XCTAssertEqual(SettingsSidebarModel.resolve(stored: nil, variant: .s2,
                                                    phones: phoneRows(), inUseId: "a"), .phone("a"))
    }

    func testZeroPhonesShowsTheEmptyStateUnlessS3KeepsItsPhonesEntry() {
        XCTAssertNil(SettingsSidebarModel.resolve(stored: nil, variant: .s1, phones: [], inUseId: nil))
        XCTAssertNil(SettingsSidebarModel.resolve(stored: nil, variant: .s2, phones: [], inUseId: nil))
        XCTAssertEqual(SettingsSidebarModel.resolve(stored: nil, variant: .s3, phones: [], inUseId: nil), .general)
        XCTAssertNil(SettingsSidebarModel.selection(for: .devices, variant: .s1, phones: [], inUseId: nil),
                     "S1's Phones route with no phones is the empty state")
    }

    func testAValueFromAnotherOptionNeverSelectsAMissingRow() {
        XCTAssertEqual(SettingsSidebarModel.resolve(stored: .devices, variant: .s1,
                                                    phones: phoneRows(), inUseId: "a"), .general)
        XCTAssertEqual(SettingsSidebarModel.resolve(stored: .devices, variant: .s3,
                                                    phones: [], inUseId: nil), .devices)
    }

    func testTheDevicesRouteOpensThePhoneInUseOrTheWholeTab() {
        XCTAssertEqual(SettingsSidebarModel.selection(for: .devices, variant: .s1,
                                                      phones: phoneRows(), inUseId: "a"), .phone("a"))
        XCTAssertEqual(SettingsSidebarModel.selection(for: .devices, variant: .s3,
                                                      phones: phoneRows(), inUseId: "a"), .devices)
        XCTAssertEqual(SettingsSidebarModel.selection(for: .general, variant: .s2,
                                                      phones: phoneRows(), inUseId: "a"), .general)
        XCTAssertEqual(SettingsSidebarModel.selection(for: .automation, variant: .s2,
                                                      phones: phoneRows(), inUseId: "a"), .automation)
    }

    // MARK: the flag and the window

    func testTheFlagSelectsAnOptionAndWidensTheWindow() {
        ProtoSettings.select("settings=S2")
        XCTAssertEqual(ProtoSettings.variant, .s2)
        XCTAssertEqual(SettingsLayout.currentWidth, 700)
        XCTAssertEqual(ProtoSettings.sidebarWidth, 200)
    }

    func testAnUnknownOrForeignValueKeepsTheProductionTabs() {
        ProtoSettings.select("devices=D1")
        XCTAssertEqual(ProtoSettings.variant, .production)
        XCTAssertEqual(SettingsLayout.currentWidth, SettingsLayout.width)

        ProtoSettings.select("settings=S9")
        XCTAssertEqual(ProtoSettings.variant, .production)
        XCTAssertNil(ProtoSettings.windowWidth)
        XCTAssertEqual(SettingsLayout.currentWidth, 480)
    }

    func testTheWindowFitsTheSmallestScreen() {
        ProtoSettings.select("settings=S1")
        let window = SettingsLayout.currentWidth
        XCTAssertLessThanOrEqual(window, 720)
        XCTAssertGreaterThanOrEqual(window, 680)
        let content = SettingsLayout.maxContentHeight(for: 800 - 25)
        XCTAssertTrue(window <= 1280 - 40, "the sidebar window fits 1280 pt")
        XCTAssertTrue(content <= 800 - 120, "the content fits the shortest screen's height")
    }
}
