// Intents core: phone resolution, app search, battery wording, link and file
// validation, and the last-battery store.

import XCTest
@testable import PocketDeck

final class IntentsCoreTests: XCTestCase {

    private func phone(_ id: String, _ name: String) -> IntentPhone {
        IntentPhone(id: id, name: name, model: "SM-S936B")
    }

    private let pixel = IntentPhone(id: "pixel", name: "Pixel", model: "SM-S936B")
    private let galaxy = IntentPhone(id: "galaxy", name: "Galaxy S25", model: "SM-S936B")

    // MARK: Phone resolution

    func testResolverUsesTheConnectedPhoneByDefault() {
        XCTAssertEqual(IntentPhoneResolver.resolve(requested: nil, phones: [galaxy, pixel], connectedId: "pixel"),
                       .phone(pixel))
    }

    func testResolverUsesTheOnlyPairedPhone() {
        XCTAssertEqual(IntentPhoneResolver.resolve(requested: nil, phones: [galaxy], connectedId: nil),
                       .phone(galaxy))
    }

    func testResolverAsksWhenSeveralPhonesArePairedAndNoneIsConnected() {
        XCTAssertEqual(IntentPhoneResolver.resolve(requested: nil, phones: [galaxy, pixel], connectedId: nil),
                       .needPhone([galaxy, pixel]))
    }

    func testResolverWithoutPhones() {
        XCTAssertEqual(IntentPhoneResolver.resolve(requested: nil, phones: [], connectedId: nil), .missing)
        XCTAssertEqual(IntentPhoneResolver.resolve(requested: "Pixel", phones: [], connectedId: nil),
                       .unknown("Pixel"))
    }

    func testResolverByDeviceId() {
        XCTAssertEqual(IntentPhoneResolver.resolve(requested: "galaxy", phones: [pixel, galaxy], connectedId: "pixel"),
                       .phone(galaxy))
    }

    func testResolverByNameIgnoresCaseAndDiacritics() {
        let office = IntentPhone(id: "office", name: "Büro", model: "")
        XCTAssertEqual(IntentPhoneResolver.resolve(requested: "büro", phones: [office], connectedId: nil),
                       .phone(office))
        XCTAssertEqual(IntentPhoneResolver.resolve(requested: "BURO", phones: [office], connectedId: nil),
                       .phone(office))
    }

    func testResolverByUniqueNamePrefix() {
        XCTAssertEqual(IntentPhoneResolver.resolve(requested: "gal", phones: [pixel, galaxy], connectedId: nil),
                       .phone(galaxy))
    }

    func testResolverReportsAnAmbiguousName() {
        let other = IntentPhone(id: "pixel-2", name: "Pixel 2", model: "")
        XCTAssertEqual(IntentPhoneResolver.resolve(requested: "pix", phones: [pixel, other], connectedId: nil),
                       .ambiguous([pixel, other]))
    }

    func testResolverReportsAnUnknownName() {
        XCTAssertEqual(IntentPhoneResolver.resolve(requested: "iPhone", phones: [pixel], connectedId: nil),
                       .unknown("iPhone"))
    }

    // MARK: App search and lookup

    private func app(_ pkg: String, _ label: String) -> AppInfo {
        AppInfo(json: ["pkg": pkg, "label": label])!
    }

    private lazy var apps = [app("com.spotify.music", "Spotify"),
                        app("com.android.settings", "Settings"),
                        app("com.google.android.youtube", "YouTube"),
                        app("com.example.you", "You Need A Budget")]

    func testSearchListsEverythingByLabelWhenTheQueryIsBlank() {
        XCTAssertEqual(IntentAppCatalog.search("", in: apps).map(\.label),
                       ["Settings", "Spotify", "You Need A Budget", "YouTube"])
    }

    func testSearchMatchesLabelsAndPackagesWithLabelHitsFirst() {
        XCTAssertEqual(IntentAppCatalog.search("you", in: apps).map(\.pkg),
                       ["com.example.you", "com.google.android.youtube"])
        XCTAssertEqual(IntentAppCatalog.search("com.android", in: apps).map(\.label), ["Settings"])
    }

    func testSearchIsCaseInsensitiveAndLimited() {
        XCTAssertEqual(IntentAppCatalog.search("SPOT", in: apps).map(\.pkg), ["com.spotify.music"])
        XCTAssertEqual(IntentAppCatalog.search("", in: apps, limit: 2).count, 2)
    }

    func testSearchWithoutMatchesIsEmpty() {
        XCTAssertTrue(IntentAppCatalog.search("nothing", in: apps).isEmpty)
    }

    func testAppNamedExactlyByPackageOrLabel() {
        XCTAssertEqual(IntentAppCatalog.app(named: "com.spotify.music", in: apps), .app(apps[0]))
        XCTAssertEqual(IntentAppCatalog.app(named: "spotify", in: apps), .app(apps[0]))
        XCTAssertEqual(IntentAppCatalog.app(named: "YOUTUBE", in: apps), .app(apps[2]))
    }

    func testAppNamedByUniquePrefix() {
        XCTAssertEqual(IntentAppCatalog.app(named: "spot", in: apps), .app(apps[0]))
    }

    func testAppLookupReportsAmbiguityAndMisses() {
        XCTAssertEqual(IntentAppCatalog.app(named: "y", in: apps),
                       .ambiguous([apps[3], apps[2]]))
        XCTAssertEqual(IntentAppCatalog.app(named: "Maps", in: apps), .none)
        XCTAssertEqual(IntentAppCatalog.app(named: "  ", in: apps), .none)
    }

    // MARK: Battery

    func testLiveBatteryIsTheConnectedPhonesState() {
        let answer = IntentBattery.answer(live: (72, true), last: nil, now: Date())
        XCTAssertEqual(answer, BatteryAnswer(level: 72, charging: true, live: true, text: "72 %, charging"))
        XCTAssertEqual(IntentBattery.answer(live: (72, false), last: nil, now: Date()).text, "72 %")
    }

    func testLiveBatteryWinsOverTheLastReading() {
        let last = BatteryReading(level: 20, charging: false, at: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(IntentBattery.answer(live: (72, true), last: last, now: Date()).text, "72 %, charging")
    }

    func testStaleBatteryShowsTheLastValueAndItsAge() {
        let now = Date(timeIntervalSince1970: 10_000)
        let last = BatteryReading(level: 61, charging: false, at: now.addingTimeInterval(-14 * 60))
        let answer = IntentBattery.answer(live: nil, last: last, now: now)
        XCTAssertEqual(answer, BatteryAnswer(level: 61, charging: false, live: false, text: "61 % 14 min ago"))
    }

    func testBatteryAgesReadNaturally() {
        XCTAssertEqual(IntentBattery.ageText(0), "just now")
        XCTAssertEqual(IntentBattery.ageText(59), "just now")
        XCTAssertEqual(IntentBattery.ageText(60), "1 min ago")
        XCTAssertEqual(IntentBattery.ageText(59 * 60), "59 min ago")
        XCTAssertEqual(IntentBattery.ageText(3600), "1 h ago")
        XCTAssertEqual(IntentBattery.ageText(23 * 3_600), "23 h ago")
        XCTAssertEqual(IntentBattery.ageText(86_400), "1 day ago")
        XCTAssertEqual(IntentBattery.ageText(3 * 86_400), "3 days ago")
    }

    func testBatteryNeverHeardOfIsNotAnError() {
        let answer = IntentBattery.answer(live: nil, last: nil, now: Date())
        XCTAssertEqual(answer, BatteryAnswer(level: nil, charging: false, live: false, text: "Battery unknown."))
    }

    func testBatteryMemoryRoundTripsAndIgnoresImpossibleLevels() throws {
        let suite = "dev.pocketdeck.test.intents-battery-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let memory = BatteryMemory(defaults: defaults)
        let at = Date(timeIntervalSince1970: 1_000)
        memory.record(deviceId: "pixel", level: 42, charging: true, at: at)
        XCTAssertEqual(memory.reading(deviceId: "pixel"), BatteryReading(level: 42, charging: true, at: at))
        memory.record(deviceId: "pixel", level: 101, charging: false, at: Date())
        XCTAssertEqual(memory.reading(deviceId: "pixel")?.level, 42, "an impossible level is dropped")
        memory.remove(deviceId: "pixel")
        XCTAssertNil(memory.reading(deviceId: "pixel"))
    }

    // MARK: Links and files

    func testLinksUseTheSharedPolicy() throws {
        XCTAssertEqual(try IntentLink.validate(" https://example.com/a "), "https://example.com/a")
        XCTAssertEqual(try IntentLink.validate("tel:+15551234"), "tel:+15551234")
        for bad in ["", "file:///etc/hosts", "intent:#Intent;action=x;end", "https://", "javascript:alert(1)"] {
            XCTAssertThrowsError(try IntentLink.validate(bad)) { error in
                XCTAssertEqual(error as? IntentFailure, .badLink)
            }
        }
    }

    func testFilesMustExistBeRegularAndFitTheCap() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pd-intents-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("note.txt")
        try Data("hello".utf8).write(to: file)
        XCTAssertEqual(try IntentFilePolicy.validate(file.path), file)

        let empty = directory.appendingPathComponent("empty.txt")
        try Data().write(to: empty)
        XCTAssertThrowsError(try IntentFilePolicy.validate(empty.path)) { error in
            XCTAssertEqual(error as? IntentFailure, .fileUnreadable("empty.txt"))
        }
        XCTAssertThrowsError(try IntentFilePolicy.validate(directory.path)) { error in
            XCTAssertEqual(error as? IntentFailure, .fileUnreadable(directory.lastPathComponent))
        }
        XCTAssertThrowsError(try IntentFilePolicy.validate(directory.appendingPathComponent("gone.txt").path)) { error in
            XCTAssertEqual(error as? IntentFailure, .fileMissing("gone.txt"))
        }
    }

    func testFailureMessagesAreHuman() {
        XCTAssertEqual(IntentFailure.phoneNotConnected.message, "Your phone isn't connected.")
        XCTAssertEqual(IntentFailure.appNotFound("Maps").message, "No phone app matches “Maps”.")
        XCTAssertEqual(IntentFailure.choosePhone(["Pixel", "Galaxy"]).message,
                       "Your phones: Pixel, Galaxy. Say which one.")
        XCTAssertEqual(IntentFailure.unknownPhone("Nope").message, "No paired phone is called “Nope”.")
    }
}
