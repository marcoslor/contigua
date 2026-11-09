import XCTest
@testable import PocketDeck

/// The phone rows' pure half (docs/specs/settings.md): presence, the row a
/// sidebar entry draws, and the muted-apps list.
final class DevicesTabTests: XCTestCase {
    /// NOTIFY-4/17: a denied macOS permission is one line naming System
    /// Settings, and nothing while it is granted or not yet asked.
    func testTheDeniedNotificationPermissionHasOneLine() {
        XCTAssertEqual(DevicesTabModel.notificationsDeniedHint(denied: true),
                       "Notifications are turned off for PocketDeck in System Settings.")
        XCTAssertNil(DevicesTabModel.notificationsDeniedHint(denied: false))
    }


    // MARK: phone rows and presence

    func testPresenceWords() {
        XCTAssertEqual(DevicePresence.connected.text, "Connected")
        XCTAssertEqual(DevicePresence.connecting.text, "Connecting…")
        XCTAssertEqual(DevicePresence.reconnecting.text, "Reconnecting…")
        XCTAssertEqual(DevicePresence.offline(nil).text, "Offline")
        XCTAssertEqual(DevicePresence.pairAgain.text, "Pair again")
        // No state is carried by colour alone: every case has its words.
        XCTAssertTrue(DevicePresence.offline(nil).isLive == false)
        XCTAssertTrue(DevicePresence.connected.isLive)
        XCTAssertEqual(DevicePresence(Link.idle).text, "Offline")
        XCTAssertEqual(DevicePresence(Link.needsPairing(PhoneRef(id: "p", name: "P", model: "M"))).text,
                       "Pair again")
    }

    func testPhoneRowCarriesNameModelStateAndLastSeen() {
        let row = DevicesTabModel.phoneRow(
            id: "p1", name: "Galaxy S25+", model: "SM-S936B",
            presence: .offline(nil), lastSeen: "2 hours ago", inUse: true)
        XCTAssertEqual(row.name, "Galaxy S25+")
        XCTAssertEqual(row.model, "SM-S936B")
        XCTAssertEqual(row.presenceText, "Offline")
        XCTAssertEqual(row.lastSeenText, "2 hours ago")
        XCTAssertTrue(row.inUse)
        XCTAssertTrue(row.canUseThisPhone == false, "the in-use phone has no Use This Phone")
        XCTAssertFalse(row.pairAgain)
    }

    func testAPhoneWithoutItsKeyOffersPairAgainOnly() {
        let row = DevicesTabModel.phoneRow(
            id: "p2", name: "Pixel 8", model: "G9S9B", presence: .pairAgain,
            lastSeen: "3 days ago", inUse: false)
        XCTAssertTrue(row.pairAgain)
        XCTAssertFalse(row.canUseThisPhone, "nothing pretends a keyless phone can be reached")
    }

    func testTheTrustLostPageHeaderOffersPairAgainAsItsOneAction() {
        // SET-DEV-26: the trust-lost page's primary action is Pair Again…;
        // In Use marks the current phone but never hides the way out.
        XCTAssertEqual(PhonePageHeaderAction.of(presence: .pairAgain, inUse: false), .pairAgain)
        XCTAssertEqual(PhonePageHeaderAction.pairAgain.title, "Pair Again…")
        XCTAssertEqual(PhonePageHeaderAction.of(presence: .offline(nil), inUse: false), .useThisPhone)
        XCTAssertEqual(PhonePageHeaderAction.useThisPhone.title, "Use This Phone")
        XCTAssertEqual(PhonePageHeaderAction.of(presence: .pairAgain, inUse: true), .pairAgain)
        XCTAssertEqual(PhonePageHeaderAction.of(presence: .connected, inUse: true), .inUse)
        XCTAssertNil(PhonePageHeaderAction.inUse.title)
    }

    func testALivePhoneShowsNoLastSeen() {
        let row = DevicesTabModel.phoneRow(
            id: "p1", name: "Galaxy S25+", model: "SM-S936B",
            presence: .connected, lastSeen: "now", inUse: true)
        XCTAssertNil(row.lastSeenText)
    }

    // MARK: muted apps

    func testMutedCountText() {
        XCTAssertEqual(DevicesTabModel.mutedCountText(0), "None")
        XCTAssertEqual(DevicesTabModel.mutedCountText(2), "2")
    }

    func testUnknownAppFallsBackToItsPackageName() {
        let unknown = DevicesTabModel.appName(pkg: "com.example.mystery", label: nil)
        XCTAssertEqual(unknown.title, "com.example.mystery")
        XCTAssertNil(unknown.packageBelow)
        let named = DevicesTabModel.appName(pkg: "com.whatsapp", label: "WhatsApp")
        XCTAssertEqual(named.title, "WhatsApp")
        XCTAssertNil(named.packageBelow, "a known app shows its name only")
    }

    func testSystemPackagesGetFriendlyLabels() {
        let systemUI = DevicesTabModel.appName(pkg: "com.android.systemui", label: nil)
        XCTAssertEqual(systemUI.title, "System UI")
        XCTAssertEqual(systemUI.packageBelow, "com.android.systemui",
                       "the package name sits underneath in secondary text")
        let android = DevicesTabModel.appName(pkg: "android", label: nil)
        XCTAssertEqual(android.title, "Android System")
        XCTAssertEqual(android.packageBelow, "android")
    }

    func testMutedRowsSortMutedFirstThenByName() {
        let apps = [app("com.alpha", "Alpha"), app("com.beta", "Beta"), app("com.zed", "Zed")]
        let rows = DevicesTabModel.mutedRows(apps: apps, seen: [], muted: ["com.zed"], query: "")
        XCTAssertEqual(rows.map(\.pkg), ["com.zed", "com.alpha", "com.beta"])
        XCTAssertEqual(rows.first?.muted, true)
        XCTAssertEqual(rows.dropFirst().map(\.muted), [false, false])
    }

    func testAppRowsSortByTheirShownName() {
        let apps = [app("com.10", "10 pin"), app("com.2", "2fa")]
        let rows = DevicesTabModel.mutedRows(apps: apps, seen: [], muted: [], query: "")
        XCTAssertEqual(rows.map(\.title), ["2fa", "10 pin"],
                       "localized order, not the package's byte order")
    }

    func testSearchMatchesNameAndPackage() {
        let apps = [app("com.whatsapp", "WhatsApp"), app("com.signal", "Signal"),
                    app("com.example.notes", "Notes")]
        XCTAssertEqual(DevicesTabModel.mutedRows(apps: apps, seen: [], muted: [], query: "whats")
            .map(\.pkg), ["com.whatsapp"])
        XCTAssertEqual(DevicesTabModel.mutedRows(apps: apps, seen: [], muted: [], query: "sig")
            .map(\.pkg), ["com.signal"])
        XCTAssertEqual(DevicesTabModel.mutedRows(apps: apps, seen: [], muted: [], query: "example")
            .map(\.pkg), ["com.example.notes"], "the package name is searchable too")
        XCTAssertTrue(DevicesTabModel.mutedRows(apps: apps, seen: [], muted: [], query: "nothing").isEmpty)
    }

    func testAnAlreadyMutedOrSeenPackageStaysListed() {
        let apps = [app("com.alpha", "Alpha")]
        let rows = DevicesTabModel.mutedRows(
            apps: apps, seen: ["com.seen"], muted: ["com.muted"], query: "")
        XCTAssertEqual(Set(rows.map(\.pkg)), ["com.alpha", "com.seen", "com.muted"])
        XCTAssertEqual(rows.first { $0.pkg == "com.seen" }?.seen, true)
        XCTAssertEqual(rows.first { $0.pkg == "com.muted" }?.muted, true)
    }

    func testSeenMarkFollowsTheSession() {
        let apps = [app("com.alpha", "Alpha"), app("com.beta", "Beta")]
        let rows = DevicesTabModel.mutedRows(apps: apps, seen: ["com.alpha"], muted: [], query: "")
        XCTAssertEqual(rows.first { $0.pkg == "com.alpha" }?.seen, true)
        XCTAssertEqual(rows.first { $0.pkg == "com.beta" }?.seen, false)
    }

    func testTheMutedColumnHasAHeaderAndEveryRowALabel() {
        XCTAssertEqual(DevicesTabModel.labels.mutedColumn, "Muted")
        XCTAssertEqual(DevicesTabModel.labels.searchField, "Search apps")
        XCTAssertEqual(DevicesTabModel.labels.mute("WhatsApp"), "Mute WhatsApp")
        XCTAssertEqual(DevicesTabModel.labels.details("Pixel 9"), "Settings for Pixel 9")
        XCTAssertEqual(DevicesTabModel.labels.inUse, "In use")
        XCTAssertEqual(DevicesTabModel.labels.addPhone, "Add Phone…")
    }

    func testTheNotificationAccessHint() {
        XCTAssertEqual(DevicesTabModel.accessHint(noAccess: true),
                       "Allow notification access on the phone.")
        XCTAssertNil(DevicesTabModel.accessHint(noAccess: false))
    }

    // MARK: helpers

    private func app(_ pkg: String, _ label: String) -> AppInfo {
        AppInfo(json: ["pkg": pkg, "label": label])!
    }
}
