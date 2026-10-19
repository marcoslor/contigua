import XCTest
@testable import PocketDeck

final class LaunchOptionsTests: XCTestCase {

    func testParsesEveryTestHook() {
        let options = LaunchOptions.parse([
            "PocketDeck",
            "--connect", "127.0.0.1:47000",
            "--open", "com.android.settings,com.whatsapp",
            "--open-phone",
            "--resize-stream", "1:800x600-pt",
            "--minimize-stream", "2:6",
            "--deminimize-stream", "2:11",
            "--close-stream", "2:33",
            "--quit-after", "20",
            "--qr-sheet",
            "--qr-payload-file", "/tmp/pd.qr",
        ])
        XCTAssertEqual(options.connect?.host, "127.0.0.1")
        XCTAssertEqual(options.connect?.port, 47000)
        XCTAssertEqual(options.openPackages, ["com.android.settings", "com.whatsapp"])
        XCTAssertTrue(options.openPhone)
        XCTAssertEqual(options.resizes.count, 1)
        XCTAssertEqual(options.resizes.first?.stream, 1)
        XCTAssertEqual(options.resizes.first?.size.width, 800)
        XCTAssertEqual(options.resizes.first?.size.height, 600)
        XCTAssertEqual(options.resizes.first?.after, 2)
        XCTAssertEqual(options.minimizes.first?.stream, 2)
        XCTAssertEqual(options.minimizes.first?.after, 6)
        XCTAssertEqual(options.deminimizes.first?.after, 11)
        XCTAssertEqual(options.closeStreams.first?.stream, 2)
        XCTAssertEqual(options.closeStreams.first?.after, 33)
        XCTAssertEqual(options.quitAfter, 20)
        XCTAssertFalse(options.resetPairing)
        XCTAssertTrue(options.qrSheet)
        XCTAssertEqual(options.qrPayloadFile, "/tmp/pd.qr")
    }

    func testResizeWithoutUnitSuffix() {
        let options = LaunchOptions.parse(["PocketDeck", "--resize-stream", "3:1024x768"])
        XCTAssertEqual(options.resizes.first?.stream, 3)
        XCTAssertEqual(options.resizes.first?.size.width, 1024)
        XCTAssertEqual(options.resizes.first?.size.height, 768)
    }

    func testDebugInputScriptPath() {
        let options = LaunchOptions.parse(["PocketDeck", "--debug-input-script", "/tmp/pd-input.txt"])
        XCTAssertEqual(options.debugInputScript, "/tmp/pd-input.txt")
        XCTAssertNil(LaunchOptions.parse(["PocketDeck"]).debugInputScript)
    }

    func testDebugControlDirectory() {
        let options = LaunchOptions.parse(["PocketDeck", "--debug-control", "/tmp/pd-control"])
        XCTAssertEqual(options.debugControl, "/tmp/pd-control")
        XCTAssertNil(LaunchOptions.parse(["PocketDeck"]).debugControl)
    }

    func testResetPairingFlag() {
        XCTAssertTrue(LaunchOptions.parse(["PocketDeck", "--reset-pairing"]).resetPairing)
    }

    func testProfileDefaultsToTheUsersOwn() {
        XCTAssertEqual(LaunchOptions.parse(["PocketDeck"]).profile, Profile.default)
    }

    func testParsesProfile() {
        XCTAssertEqual(LaunchOptions.parse(["PocketDeck", "--profile", "e2e-4242"]).profile?.name, "e2e-4242")
    }

    func testUnusableProfileIsNilNotTheDefault() {
        XCTAssertNil(LaunchOptions.parse(["PocketDeck", "--profile", "../default"]).profile)
        XCTAssertNil(LaunchOptions.parse(["PocketDeck", "--profile"]).profile)
    }

    func testEmptyArgumentsGiveDefaults() {
        let options = LaunchOptions.parse(["PocketDeck"])
        XCTAssertNil(options.connect)
        XCTAssertTrue(options.openPackages.isEmpty)
        XCTAssertFalse(options.openPhone)
        XCTAssertNil(options.quitAfter)
    }

    func testParsesPreviewAndAppearance() {
        let options = LaunchOptions.parse(["PocketDeck", "--preview", "offline", "--appearance", "light"])
        XCTAssertEqual(options.preview, "offline")
        XCTAssertEqual(options.appearance, "light")
        XCTAssertNil(LaunchOptions.parse(["PocketDeck"]).preview)
    }

    func testParsesBackground() {
        XCTAssertTrue(LaunchOptions.parse(["PocketDeck", "--profile", "e2e", "--background"]).background)
        XCTAssertFalse(LaunchOptions.parse(["PocketDeck", "--profile", "e2e"]).background)
    }

    func testBackgroundNeedsANamedProfileEvenInARelease() {
        let quiet = LaunchOptions.parse(["PocketDeck", "--background", "--profile", "e2e"])
        XCTAssertNil(quiet.launchRefusal(releaseBuild: false))
        XCTAssertNil(quiet.launchRefusal(releaseBuild: true))
        for args in [["PocketDeck", "--background"], ["PocketDeck", "--background", "--profile", "default"]] {
            let options = LaunchOptions.parse(args)
            XCTAssertNotNil(options.launchRefusal(releaseBuild: true), "\(args)")
            XCTAssertNotNil(options.launchRefusal(releaseBuild: false), "\(args)")
        }
    }

    func testDefaultProfileRefusedOnlyInDevBuilds() {
        let bare = LaunchOptions.parse(["PocketDeck"])
        XCTAssertNotNil(bare.launchRefusal(releaseBuild: false))
        XCTAssertNil(bare.launchRefusal(releaseBuild: true))
        XCTAssertNil(LaunchOptions.parse(["PocketDeck", "--preview", "offline"]).launchRefusal(releaseBuild: false))
        XCTAssertNotNil(LaunchOptions.parse(["PocketDeck", "--profile", "Bad Name"]).launchRefusal(releaseBuild: true))
    }
}
