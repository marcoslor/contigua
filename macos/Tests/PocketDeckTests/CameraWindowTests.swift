// The "Phone Camera" window (docs/design/camera.md, C2): the state → message
// mapping, the `cam.cams` parsing, the stream-id allocation and the one window
// per session rule. The window itself is real AppKit here, as in the density
// tests; the phone is never involved (the session's channel is nil).

import AppKit
import XCTest
@testable import PocketDeck

final class CameraWindowCopyTests: XCTestCase {
    func testOffAsksForTheSettingWithTryAgain() {
        let copy = CameraWindowCopy.copy(for: .off, hasFrame: false)
        XCTAssertEqual(copy.message, "Camera sharing is off on your phone. Turn on \"Let Macs use the camera\" in PocketDeck on the phone.")
        XCTAssertTrue(copy.showsRetry)
        XCTAssertFalse(copy.showsSpinner)
    }

    func testBusyIsAStatementWithoutRetry() {
        let copy = CameraWindowCopy.copy(for: .busy, hasFrame: true)
        XCTAssertEqual(copy.message, "The phone's camera is in use by another Mac window.")
        XCTAssertFalse(copy.showsRetry)
    }

    func testEvictedNamesTheCameraAppAndOffersTryAgain() {
        let copy = CameraWindowCopy.copy(for: .evicted, hasFrame: true)
        XCTAssertEqual(copy.message, "Your phone's camera app is using the camera.")
        XCTAssertTrue(copy.showsRetry)
    }

    func testLockedAndDisabledShareOneMessage() {
        for status in [CameraStatus.locked, .disabled] {
            let copy = CameraWindowCopy.copy(for: status, hasFrame: true)
            XCTAssertEqual(copy.message, "The phone's camera is not available right now.")
            XCTAssertTrue(copy.showsRetry)
        }
    }

    func testAnOlderPhoneGetsTheUpdateMessageWithoutRetry() {
        for status in [CameraStatus.error, .unsupported] {
            let copy = CameraWindowCopy.copy(for: status, hasFrame: true)
            XCTAssertEqual(copy.message, "This phone can't share its camera. Update PocketDeck on the phone.")
            XCTAssertFalse(copy.showsRetry)
            XCTAssertFalse(copy.showsSpinner)
        }
    }

    func testStreamingShowsASpinnerUntilTheFirstFrame() {
        let before = CameraWindowCopy.copy(for: .streaming, hasFrame: false)
        XCTAssertNil(before.message)
        XCTAssertTrue(before.showsSpinner)
        let after = CameraWindowCopy.copy(for: .streaming, hasFrame: true)
        XCTAssertNil(after.message)
        XCTAssertFalse(after.showsSpinner)
        XCTAssertFalse(after.showsRetry)
    }

    func testOpeningShowsOnlyTheSpinner() {
        let copy = CameraWindowCopy.copy(for: .opening, hasFrame: false)
        XCTAssertNil(copy.message)
        XCTAssertTrue(copy.showsSpinner)
        XCTAssertFalse(copy.showsRetry)
    }

    func testSessionEndSaysDisconnectedAndNeverRetries() {
        let copy = CameraWindowCopy.copy(for: .disconnected, hasFrame: false)
        XCTAssertEqual(copy.message, "Phone disconnected")
        XCTAssertFalse(copy.showsRetry)
        XCTAssertFalse(copy.showsSpinner)
    }

    func testWireStatesAndUnknownNames() {
        XCTAssertEqual(CameraStatus.wire("streaming"), .streaming)
        XCTAssertEqual(CameraStatus.wire("off"), .off)
        XCTAssertEqual(CameraStatus.wire("evicted"), .evicted)
        XCTAssertEqual(CameraStatus.wire("locked"), .locked)
        XCTAssertEqual(CameraStatus.wire("disabled"), .disabled)
        XCTAssertEqual(CameraStatus.wire("busy"), .busy)
        XCTAssertEqual(CameraStatus.wire("error"), .error)
        XCTAssertEqual(CameraStatus.wire("something_new"), .error)
    }
}

final class PhoneCameraTests: XCTestCase {
    func testCamListsParseAndBadEntriesAreSkipped() {
        let json: [[String: Any]] = [
            ["id": "0", "facing": "back", "w": 1920, "h": 1080],
            ["id": "1", "facing": "front", "w": 1280, "h": 720],
            ["facing": "back"],
            ["id": "", "facing": "front"],
        ]
        let cams = json.compactMap(PhoneCamera.init(json:))
        XCTAssertEqual(cams, [
            PhoneCamera(json: ["id": "0", "facing": "back", "w": 1920, "h": 1080])!,
            PhoneCamera(json: ["id": "1", "facing": "front", "w": 1280, "h": 720])!,
        ])
    }
}

@MainActor
final class CameraWindowTests: XCTestCase {
    private func makeManager() -> WindowManager {
        let name = "dev.pocketdeck.tests.camera.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        let session = Session(endpoint: .hostPort(host: "127.0.0.1", port: 1), knownDeviceId: nil,
                              clientId: "test-client")
        return WindowManager(session: session, defaults: defaults)
    }

    func testOneCameraWindowPerSession() {
        let manager = makeManager()
        let first = manager.openCameraWindow()
        defer { first.window?.close() }
        XCTAssertEqual(manager.openStreams, [first.stream])

        let again = manager.openCameraWindow()
        XCTAssertTrue(again === first, "picking Phone Camera again brings the open window forward")
        XCTAssertEqual(manager.openStreams, [first.stream], "a second capture never starts")
        XCTAssertTrue(manager.cameraWindow === first)
    }

    func testAStreamSwitchMovesTheWindowToTheNewId() {
        let manager = makeManager()
        let camera = manager.openCameraWindow()
        defer { camera.window?.close() }
        let old = camera.stream
        let next = manager.newStreamID()
        XCTAssertGreaterThan(next, old)
        manager.rebind(camera, to: next)
        XCTAssertEqual(camera.stream, next)
        XCTAssertNil(manager.controller(for: old), "frames on the old stream go nowhere")
        XCTAssertTrue(manager.controller(for: next) === camera)
        XCTAssertEqual(manager.openStreams, [next], "the window is still the only one")
    }

    func testTheCameraWindowStartsInTheOpeningState() {
        let manager = makeManager()
        let camera = manager.openCameraWindow()
        defer { camera.window?.close() }
        XCTAssertEqual(camera.status, .opening)
        XCTAssertTrue(camera.cams.isEmpty)
        XCTAssertEqual(camera.frames, 0)
    }

    func testTheCameraWindowTakesNothingFromThePhoneScreen() {
        let manager = makeManager()
        let camera = manager.openCameraWindow()
        defer { camera.window?.close() }
        XCTAssertNil(camera.videoView.inputMapper, "the camera stream is not an Android surface")
    }
}
