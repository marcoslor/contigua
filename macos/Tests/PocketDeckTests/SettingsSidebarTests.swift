// The Settings window's navigation and sidebar model (docs/specs/settings.md):
// the selection state machine — one closed set of states, every event — the
// stored preference, the row words, the plain section headings and the window's
// size rules. The window itself is proved by the e2e check `settings`.

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
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    /// Three fixture phones, with the strings the sidebar builds for them
    /// (never a person's phones).
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

    // MARK: opening (SET-WIN-03)

    func testOpeningWithNothingStoredPicksThePhoneInUse() {
        let step = SettingsSelectionMachine.step(
            from: .general,
            event: .open(stored: nil, phones: ["a", "b"], inUse: "b"))
        XCTAssertEqual(step.selection, .phone("b"))
        XCTAssertEqual(step.actions, [.store])
    }

    func testOpeningWithNoPhonesStartsOnGeneral() {
        let step = SettingsSelectionMachine.step(
            from: .phone("a"),
            event: .open(stored: nil, phones: [], inUse: nil))
        XCTAssertEqual(step.selection, .general)
    }

    func testAStoredSectionReopens() {
        for stored in ["general", "input", "automation"] {
            let step = SettingsSelectionMachine.step(
                from: .general,
                event: .open(stored: stored, phones: ["a"], inUse: "a"))
            XCTAssertEqual(step.selection.storeValue, stored)
        }
    }

    func testAStoredPhoneReopens() {
        let step = SettingsSelectionMachine.step(
            from: .general,
            event: .open(stored: "phone:b", phones: ["a", "b"], inUse: "a"))
        XCTAssertEqual(step.selection, .phone("b"))
    }

    func testAStoredPhoneThatIsGoneFallsBackToThePhoneInUse() {
        let step = SettingsSelectionMachine.step(
            from: .general,
            event: .open(stored: "phone:gone", phones: ["a", "b"], inUse: "b"))
        XCTAssertEqual(step.selection, .phone("b"))

        let empty = SettingsSelectionMachine.step(
            from: .phone("gone"),
            event: .open(stored: "phone:gone", phones: [], inUse: nil))
        XCTAssertEqual(empty.selection, .general)
    }

    func testAnUnreadableStoredValueIsIgnored() {
        let step = SettingsSelectionMachine.step(
            from: .general,
            event: .open(stored: "nonsense", phones: ["a"], inUse: nil))
        XCTAssertEqual(step.selection, .phone("a"))
    }

    // MARK: choosing (SET-WIN-03)

    func testChoosingAPhoneThatIsNotRememberedIsIgnored() {
        let step = SettingsSelectionMachine.step(
            from: .phone("a"),
            event: .choose(.phone("gone"), phones: ["a"]))
        XCTAssertEqual(step.selection, .phone("a"))
        XCTAssertEqual(step.actions, [])
    }

    func testChoosingARowMovesThePageAndStoresIt() {
        let step = SettingsSelectionMachine.step(
            from: .phone("a"),
            event: .choose(.automation, phones: ["a"]))
        XCTAssertEqual(step.selection, .automation)
        XCTAssertEqual(step.actions, [.store])

        let again = SettingsSelectionMachine.step(
            from: .automation,
            event: .choose(.automation, phones: ["a"]))
        XCTAssertEqual(again.actions, [], "the same row is not stored twice")
    }

    func testAddPhoneOpensTheSheetWithoutMovingTheSelection() {
        let step = SettingsSelectionMachine.step(
            from: .phone("a"),
            event: .addPhone)
        XCTAssertEqual(step.selection, .phone("a"))
        XCTAssertEqual(step.actions, [.addPhoneSheet])

        let general = SettingsSelectionMachine.step(from: .general, event: .addPhone)
        XCTAssertEqual(general.selection, .general)
        XCTAssertEqual(general.actions, [.addPhoneSheet])
    }

    // MARK: forgetting and the list changing (SET-WIN-05)

    func testForgettingTheOpenPhoneSelectsTheNextPhone() {
        let step = SettingsSelectionMachine.step(
            from: .phone("a"),
            event: .forgot(deviceId: "a", phones: ["b", "c"], inUse: "c"))
        XCTAssertEqual(step.selection, .phone("c"))
        XCTAssertEqual(step.actions, [.store])
    }

    func testForgettingTheOpenPhoneWithNoneLeftGoesToGeneral() {
        let step = SettingsSelectionMachine.step(
            from: .phone("a"),
            event: .forgot(deviceId: "a", phones: [], inUse: nil))
        XCTAssertEqual(step.selection, .general)
        XCTAssertEqual(step.actions, [.store])
    }

    func testForgettingAnotherPhoneKeepsThePage() {
        let step = SettingsSelectionMachine.step(
            from: .phone("a"),
            event: .forgot(deviceId: "b", phones: ["a"], inUse: "a"))
        XCTAssertEqual(step.selection, .phone("a"))
        XCTAssertEqual(step.actions, [])
    }

    func testTheListChangingKeepsAValidPage() {
        let kept = SettingsSelectionMachine.step(
            from: .phone("a"),
            event: .phonesChanged(phones: ["a", "b"], inUse: "b"))
        XCTAssertEqual(kept.selection, .phone("a"), "another phone pairing does not move the page")
        XCTAssertEqual(kept.actions, [])

        let moved = SettingsSelectionMachine.step(
            from: .phone("gone"),
            event: .phonesChanged(phones: ["a"], inUse: nil))
        XCTAssertEqual(moved.selection, .phone("a"))
        XCTAssertEqual(moved.actions, [.store])

        let general = SettingsSelectionMachine.step(
            from: .general,
            event: .phonesChanged(phones: [], inUse: nil))
        XCTAssertEqual(general.selection, .general)
        XCTAssertEqual(general.actions, [])
    }

    // MARK: the stored preference (SET-WIN-04)

    func testTheSelectionRoundTripsThroughTheProfileDefaults() {
        for selection in [SettingsSelection.general, .input, .automation, .phone("a")] {
            SettingsSelectionStore.write(selection, to: defaults)
            XCTAssertEqual(SettingsSelectionStore.read(from: defaults), selection.storeValue)
        }
        XCTAssertEqual(SettingsSelection(storeValue: "phone:a"), .phone("a"))
        XCTAssertNil(SettingsSelection(storeValue: "phone:"))
        XCTAssertNil(SettingsSelection(storeValue: "devices"))
    }

    func testAnotherProfileHasItsOwnSelection() {
        SettingsSelectionStore.write(.phone("a"), to: defaults)
        let other = UserDefaults(suiteName: "settings-sidebar-test-other-\(UUID().uuidString)")!
        XCTAssertNil(SettingsSelectionStore.read(from: other))
    }

    // MARK: the sidebar and its rows

    func testPhonesComeFirstAndTheMacSectionsBelow() {
        let groups = SettingsSidebarModel.groups(phones: phoneRows())
        XCTAssertEqual(groups.map(\.title), ["Phones", "This Mac"])
        XCTAssertEqual(groups[0].items.map(\.selection), [.phone("a"), .phone("b"), .phone("c")])
        XCTAssertTrue(groups[0].showsAddPhone)
        XCTAssertEqual(groups[1].items.map(\.selection), [.general, .input, .automation])
        XCTAssertFalse(groups[1].showsAddPhone)
        XCTAssertEqual(SettingsSidebarModel.emptyPhonesText, "No phones yet.")
    }

    func testAPhoneRowSaysItsStateInWordsAndMarksTheOneInUse() {
        let items = SettingsSidebarModel.groups(phones: phoneRows())[0].items
        XCTAssertEqual(items[0].presence, .connected)
        XCTAssertNil(items[0].subtitle, "a connected phone has no last-seen line")
        XCTAssertTrue(items[0].inUse)
        XCTAssertEqual(items[1].presence, DevicePresence.offline(nil))
        XCTAssertEqual(items[1].subtitle, "2 hours ago")
        XCTAssertEqual(items[2].presence, .pairAgain)
        XCTAssertEqual(items[2].subtitle, "3 days ago")
    }

    func testVoiceOverLabelsCarryNameStateLastSeenAndTheInUseMark() {
        let items = SettingsSidebarModel.groups(phones: phoneRows())[0].items
        XCTAssertEqual(items[0].accessibilityLabel, "Galaxy S25+, Connected, In use")
        XCTAssertEqual(items[1].accessibilityLabel, "Pixel 9, Offline, last seen 2 hours ago")
        XCTAssertEqual(items[2].accessibilityLabel, "Pixel 8, Pair again, last seen 3 days ago")
        XCTAssertEqual(SettingsSidebarModel.addPhoneItem().accessibilityLabel, "Add Phone…")
        XCTAssertFalse(items[0].help.isEmpty, "a row explains itself")
    }

    func testFivePhonesAllStayInTheSidebar() {
        let rows = (0..<5).map { index in
            DevicesTabModel.phoneRow(id: "p\(index)", name: "Phone \(index + 1)", model: "Model",
                                     presence: .offline(nil), lastSeen: "yesterday", inUse: index == 0)
        }
        let groups = SettingsSidebarModel.groups(phones: rows)
        XCTAssertEqual(groups[0].items.count, 5)
        XCTAssertTrue(groups[0].showsAddPhone)
    }

    // MARK: the title and the plain headings (SET-WIN-06)

    func testTheWindowTitleIsTheOpenPagesName() {
        let rows = phoneRows()
        XCTAssertEqual(SettingsSidebarModel.title(for: .general, rows: rows), "General")
        XCTAssertEqual(SettingsSidebarModel.title(for: .input, rows: rows), "Input")
        XCTAssertEqual(SettingsSidebarModel.title(for: .automation, rows: rows), "Automation")
        XCTAssertEqual(SettingsSidebarModel.title(for: .phone("b"), rows: rows), "Pixel 9")
        XCTAssertEqual(SettingsSidebarModel.title(for: .phone("gone"), rows: rows), "Phones")
    }

    func testSectionHeadingsArePlainAndNeverCarryThePhoneName() {
        let names = phoneRows().map(\.name) + ["Galaxy S25+", "Pixel 9", "Pixel 8"]
        XCTAssertEqual(PhonePageSection.allCases.map(\.rawValue),
                       ["Phone", "Notifications", "Screen", "Forget"])
        for section in PhonePageSection.allCases {
            for name in names {
                XCTAssertFalse(section.rawValue.contains(name),
                               "the heading '\(section.rawValue)' must not carry the phone's name")
            }
            XCTAssertFalse(section.rawValue.contains(" — "),
                           "no phone prefix in a section heading")
        }
    }

    // MARK: the window (SET-WIN-07)

    func testTheWindowIs720WideAndFitsTheSmallestScreen() {
        XCTAssertEqual(SettingsLayout.width, 720)
        XCTAssertEqual(SettingsLayout.sidebarWidth, 240)
        XCTAssertEqual(SettingsLayout.detailWidth, 480)
        XCTAssertLessThanOrEqual(SettingsLayout.width, 1280)
        let cap = SettingsLayout.maxContentHeight(for: 800 - 25)
        XCTAssertEqual(cap, 560)
        XCTAssertLessThanOrEqual(cap, 800 - SettingsLayout.chromeAllowance)
        XCTAssertEqual(SettingsLayout.maxContentHeight(for: 400), SettingsLayout.minimumHeight,
                       "a short screen never goes below the floor")
    }
}
