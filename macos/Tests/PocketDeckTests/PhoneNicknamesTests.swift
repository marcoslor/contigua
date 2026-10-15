// The one phone name: nickname resolution (set/empty/whitespace/too long) and
// the reactions a rename triggers — the Dock shim rebuild decision and the
// renamed failure banner. Window titles are covered by the WindowManager tests.

import Network
import XCTest
@testable import PocketDeck

final class PhoneNicknamesTests: XCTestCase {
    private let suite = "dev.pocketdeck.tests.nicknames"
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    private var store: RememberedPhones { RememberedPhones(defaults: defaults) }

    private let phone = PhoneRef(id: "aaa", name: "Pixel 9", model: "Pixel 9")

    // MARK: Resolution

    func testTheNicknameWins() {
        store.remember(phone)
        PhoneNicknames.write("Nicky", for: "aaa", to: defaults)
        XCTAssertEqual(store.displayName(for: phone), "Nicky")
    }

    func testAnEmptyOrWhitespaceNicknameUsesThePhonesOwnName() {
        store.remember(phone)
        for raw in ["", "   ", "\n\t "] {
            PhoneNicknames.write(raw, for: "aaa", to: defaults)
            XCTAssertNil((defaults.dictionary(forKey: PhoneNicknames.key) as? [String: String])?["aaa"], raw)
            XCTAssertEqual(store.displayName(for: phone), "Pixel 9", raw)
        }
        // Anything left after trimming counts as a nickname ("pea").
        PhoneNicknames.write("\n\t pea ", for: "aaa", to: defaults)
        XCTAssertEqual(PhoneNicknames.read(from: defaults, deviceId: "aaa"), "pea")
        // No record: the reported name is the name.
        XCTAssertEqual(store.displayName(for: PhoneRef(id: "bbb", name: "Galaxy", model: "")), "Galaxy")
    }

    func testLongerThanFortyIsTrimmedAndClamped() {
        PhoneNicknames.write("   \(String(repeating: "x", count: 45))   ", for: "aaa", to: defaults)
        let stored = PhoneNicknames.read(from: defaults, deviceId: "aaa")
        XCTAssertEqual(stored.count, 40)
        XCTAssertEqual(stored, String(repeating: "x", count: 40))
        XCTAssertEqual(store.displayName(for: phone), stored)
    }

    func testWhitespaceRunsCollapseToOneSpace() {
        PhoneNicknames.write("  My   long\tnick  ", for: "aaa", to: defaults)
        XCTAssertEqual(store.displayName(for: phone), "My long nick")
    }

    func testUnrememberedPhonesStillHaveTheirOwnNameOrAFallback() {
        XCTAssertEqual(store.displayName(for: PhoneRef(id: "bbb", name: "Galaxy", model: "")), "Galaxy")
        XCTAssertEqual(store.displayName(for: PhoneRef(id: "", name: "", model: ""), fallback: "your phone"),
                       "your phone", "a manual connection has no name to show")
        PhoneNicknames.write("Nicky", for: "zzz", to: defaults)
        XCTAssertEqual(store.displayName(for: PhoneRef(id: "zzz", name: "", model: "")), "Nicky",
                       "a nickname stands for its device even without a record")
    }

    func testAForgottenPhoneLeavesNoNicknameBehind() {
        store.remember(phone)
        PhoneNicknames.write("Nicky", for: "aaa", to: defaults)
        store.forget(id: "aaa")
        XCTAssertTrue(store.all.isEmpty)
        XCTAssertEqual(PhoneNicknames.read(from: defaults, deviceId: "aaa"), "")
        XCTAssertNil(defaults.object(forKey: PhoneNicknames.key), "the map itself goes when the last entry goes")
    }

    // MARK: The rename reactions

    func testRenamingDecidesToRebuildEveryShimOfThatPhone() {
        // Shims were built when the phone answered as "FakePhone"; the display
        // name after a rename decides a rebuild for its shims, its alone.
        let records = [
            DockShimRecord(url: URL(fileURLWithPath: "/x/a.app"), deviceId: "aaa", pkg: "a",
                           profile: "e2e", name: "A (FakePhone)"),
            DockShimRecord(url: URL(fileURLWithPath: "/x/b.app"), deviceId: "aaa", pkg: "b",
                           profile: "e2e", name: "B (FakePhone)"),
            DockShimRecord(url: URL(fileURLWithPath: "/x/c.app"), deviceId: "other", pkg: "c",
                           profile: "e2e", name: "C (FakePhone)"),
        ]
        let apps = [AppInfo(json: ["pkg": "a", "label": "A"])!, AppInfo(json: ["pkg": "b", "label": "B"])!]
        XCTAssertEqual(DockCleanup.plan(records: records, deviceId: "aaa", apps: apps, phoneName: "FakePhone"), [])
        PhoneNicknames.write("Nicky", for: "aaa", to: defaults)
        XCTAssertEqual(DockCleanup.plan(records: records, deviceId: "aaa", apps: apps, phoneName: "Nicky"),
                       [.rebuild(records[0], label: "A"), .rebuild(records[1], label: "B")],
                       "the other device's shims keep their name")
    }

    func testARenamedPhoneNamesTheFailureBanner() {
        store.remember(phone)
        PhoneNicknames.write("Nicky", for: "aaa", to: defaults)
        let naming: (PhoneRef) -> String = { [store] phone in store.displayName(for: phone) }
        XCTAssertEqual(Link.offline(phone, .unreachable).banner(naming: naming)?.text,
                       "Can't reach Nicky. Check that it's on the same Wi-Fi.")
        XCTAssertEqual(Link.offline(phone, .busy).banner(naming: naming)?.text,
                       "Another Mac is connected to Nicky.")
        XCTAssertEqual(Link.needsPairing(phone).banner(naming: naming)?.text,
                       "Nicky no longer trusts this Mac.")
    }
}

final class WindowManagerPhoneTitleTests: XCTestCase {
    /// "WhatsApp (Nicky)": titles append the display name; a change retitles.
    func testTitlesCarryThePhoneName() {
        let keys = PairKeyStore(defaults: UserDefaults(suiteName: "wm-tests-\(UUID().uuidString)")!, keys: .scratch())
        let manager = WindowManager(session: Session(endpoint: .hostPort(host: "127.0.0.1", port: 1),
                                                     knownDeviceId: nil, clientId: "", keyStore: keys))
        XCTAssertEqual(manager.titled("WhatsApp"), "WhatsApp", "no name: the bare subject")
        manager.setPhoneName("Nicky")
        XCTAssertEqual(manager.titled("WhatsApp"), "WhatsApp (Nicky)")
        manager.setPhoneName("")
        XCTAssertEqual(manager.titled("WhatsApp"), "WhatsApp", "an empty name means no suffix")
    }
}
