// Density: the per-app override store, the effective value a window uses, the
// View ▸ Density check mark and the window plumbing. Pure logic plus the
// manager's window walk; the menu and Settings are exercised in the e2e check.

import AppKit
import XCTest
@testable import Contigua

final class WindowDensityStorageTests: XCTestCase {
    private func makeDefaults() -> UserDefaults {
        let name = "app.contigua.tests.density.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        return defaults
    }

    func testAnAppWithNoOverrideFollowsTheSetting() {
        let store = WindowDensityStore(defaults: makeDefaults())
        XCTAssertNil(store.override(forKey: WindowDensityStore.key(forPackage: "com.example.app")))
    }

    func testTheOverrideIsRememberedPerPackage() {
        let defaults = makeDefaults()
        let store = WindowDensityStore(defaults: defaults)
        let inbox = WindowDensityStore.key(forPackage: "com.example.inbox")
        let maps = WindowDensityStore.key(forPackage: "com.example.maps")
        store.set(1.25, forKey: inbox)
        XCTAssertEqual(store.override(forKey: inbox), 1.25)
        XCTAssertNil(store.override(forKey: maps), "another app keeps following the setting")
        store.set(nil, forKey: inbox)
        XCTAssertNil(store.override(forKey: inbox), "Default clears it")
        XCTAssertNil(defaults.object(forKey: inbox!), "and leaves nothing behind")
    }

    func testTheKeysAreThePackagesAndThePhoneHasNone() {
        XCTAssertEqual(WindowDensityStore.key(forPackage: "com.android.settings"), "chrome.density.com.android.settings")
        XCTAssertNil(WindowDensityStore.key(forPackage: nil))
        XCTAssertNil(WindowDensityStore.key(forPackage: ""))
        XCTAssertEqual(WindowDensityStore.prefix, "chrome.density.")
    }

    func testAllListsEveryOverrideByPackage() {
        let store = WindowDensityStore(defaults: makeDefaults())
        store.set(1.5, forKey: WindowDensityStore.key(forPackage: "com.example.b"))
        store.set(0.75, forKey: WindowDensityStore.key(forPackage: "com.example.a"))
        XCTAssertEqual(store.all(), ["com.example.a": 0.75, "com.example.b": 1.5])
        store.clearAll()
        XCTAssertTrue(store.all().isEmpty)
    }

    func testAWindowWithNoPackageStoresNothing() {
        let defaults = makeDefaults()
        WindowDensityStore(defaults: defaults).set(1.25, forKey: nil)
        XCTAssertTrue(WindowDensityStore(defaults: defaults).all().isEmpty)
    }

    func testTheSettingIsOneHundredPercentWhenUnset() {
        let defaults = makeDefaults()
        XCTAssertEqual(WindowDensity.value(in: defaults), 1.0)
        defaults.set(1.25, forKey: WindowDensity.key)
        XCTAssertEqual(WindowDensity.value(in: defaults), 1.25)
    }
}

final class DensityRulesTests: XCTestCase {
    func testTheOverrideWinsAndTheSettingIsTheFallback() {
        XCTAssertEqual(DensityRules.effective(override: 1.25, settings: 1.0), 1.25)
        XCTAssertEqual(DensityRules.effective(override: nil, settings: 1.5), 1.5)
    }

    func testTheEffectiveValueStaysInRange() {
        XCTAssertEqual(DensityRules.effective(override: 3.0, settings: 1.0), 1.5)
        XCTAssertEqual(DensityRules.effective(override: 0.1, settings: 1.0), 0.75)
    }

    func testTheKeyboardStepsAndClamps() {
        XCTAssertEqual(DensityRules.stepped(from: 1.0, by: 0.25), 1.25)
        XCTAssertEqual(DensityRules.stepped(from: 1.0, by: -0.25), 0.75)
        XCTAssertEqual(DensityRules.stepped(from: 1.5, by: 0.25), 1.5, "no higher than 150%")
        XCTAssertEqual(DensityRules.stepped(from: 0.75, by: -0.25), 0.75, "no lower than 75%")
        XCTAssertEqual(DensityRules.stepped(from: 0.75, by: 0.25), 1.0, "exactly an option")
    }

    func testThePercentLabel() {
        XCTAssertEqual(DensityRules.percentLabel(0.75), "75%")
        XCTAssertEqual(DensityRules.percentLabel(1.0), "100%")
        XCTAssertEqual(DensityRules.percentLabel(1.25), "125%")
        XCTAssertEqual(DensityRules.percentLabel(1.1), "110%")
    }
}

final class DensityMenuCheckTests: XCTestCase {
    func testNoOverrideChecksDefault() {
        XCTAssertEqual(DensityCheck.forOverride(nil), .defaultItem)
    }

    func testAnOptionChecksItself() {
        XCTAssertEqual(DensityCheck.forOverride(1.25), .value(1.25))
        XCTAssertEqual(DensityCheck.forOverride(0.75), .value(0.75))
    }

    func testAnInBetweenValueChecksNothing() {
        XCTAssertEqual(DensityCheck.forOverride(1.1), .none)
    }
}

final class DensityWindowTests: XCTestCase {
    private func makeManager(_ defaults: UserDefaults) -> WindowManager {
        let session = Session(endpoint: .hostPort(host: "127.0.0.1", port: 1), knownDeviceId: nil,
                              clientId: "test-client")
        return WindowManager(session: session, defaults: defaults)
    }

    private func makeDefaults() -> UserDefaults {
        let name = "app.contigua.tests.density.windows.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        return defaults
    }

    func testAWindowShowsTheOverrideElseTheSetting() {
        let defaults = makeDefaults()
        let manager = makeManager(defaults)
        let controller = manager.openOrRaise(pkg: "com.example.app")
        defer { controller.window?.close() }
        XCTAssertEqual(controller.density, 1.0)

        manager.setDensity(1.25, forPackage: "com.example.app")
        XCTAssertEqual(controller.density, 1.25)
        XCTAssertEqual(manager.densityStore.override(forKey: WindowDensityStore.key(forPackage: "com.example.app")),
                       1.25)

        manager.setDensity(nil, forPackage: "com.example.app")
        XCTAssertEqual(controller.density, 1.0)
    }

    func testAnOverrideAppliesToEveryWindowOfThatAppAndNoOther() {
        let manager = makeManager(makeDefaults())
        let first = manager.openOrRaise(pkg: "com.example.app")
        let second = manager.openOrRaise(pkg: "com.example.app")
        let other = manager.openOrRaise(pkg: "com.example.other")
        defer {
            first.window?.close()
            second.window?.close()
            other.window?.close()
        }
        manager.setDensity(1.5, forPackage: "com.example.app")
        XCTAssertEqual(first.density, 1.5)
        XCTAssertEqual(second.density, 1.5)
        XCTAssertEqual(other.density, 1.0, "another app keeps its own value")
    }

    func testTheSettingReachesAppsWithoutAnOverride() {
        let defaults = makeDefaults()
        let manager = makeManager(defaults)
        let plain = manager.openOrRaise(pkg: "com.example.plain")
        let pinned = manager.openOrRaise(pkg: "com.example.pinned")
        defer {
            plain.window?.close()
            pinned.window?.close()
        }
        manager.setDensity(1.25, forPackage: "com.example.pinned")
        defaults.set(1.5, forKey: WindowDensity.key)
        manager.defaultDensityChanged()
        XCTAssertEqual(plain.density, 1.5, "no override: follows the setting")
        XCTAssertEqual(pinned.density, 1.25, "an override keeps its value")
        XCTAssertEqual(StreamMenuState.shared.settingsDensity, 1.5, "the menu's Default label follows")
    }

    func testTheMenuStateFollowsTheKeyWindow() {
        let manager = makeManager(makeDefaults())
        addTeardownBlock {
            StreamMenuState.shared.handle(.reset)
        }
        let controller = manager.openOrRaise(pkg: "com.example.app")
        defer { controller.window?.close() }
        manager.setDensity(1.25, forPackage: "com.example.app")
        controller.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification))
        let state = StreamMenuState.shared
        XCTAssertTrue(state.hasStream)
        XCTAssertEqual(state.densityPackage, "com.example.app")
        XCTAssertEqual(state.densityOverride, 1.25)
        XCTAssertEqual(DensityCheck.forOverride(state.densityOverride), .value(1.25))
        controller.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification))
        XCTAssertFalse(state.hasStream)
        XCTAssertNil(state.densityPackage)
    }

    func testThePhoneWindowHasNoOverride() {
        let manager = makeManager(makeDefaults())
        let phone = manager.openPhoneWindow()
        defer { phone.window?.close() }
        XCTAssertNil(phone.densityPackage)
        XCTAssertFalse(phone.usesDensity, "the phone window's dpi keeps the phone's dp width")
    }

    func testForgettingTheProfileClearsOverrides() {
        let defaults = makeDefaults()
        let manager = makeManager(defaults)
        manager.setDensity(1.5, forPackage: "com.example.app")
        XCTAssertFalse(manager.densityOverrides.isEmpty)
        manager.resetForNextCheck(forgetPrefs: true)
        XCTAssertTrue(manager.densityOverrides.isEmpty)
        XCTAssertTrue(WindowDensityStore(defaults: defaults).all().isEmpty)
    }
}
