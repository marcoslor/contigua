// The Mac's codec side (WIN-59/WIN-60): the hello's hardware list and the
// refusal of a stream whose config names a codec this Mac cannot decode. The
// refusal reuses the window's existing states — the opening cover's refusal
// while it opens, and the closed window once live — never the stall overlay.

import AppKit
import XCTest
@testable import PocketDeck

final class VideoCodecTests: XCTestCase {

    func testAVCMustDecodeAndHEVCNamesItsMissingHardware() {
        XCTAssertEqual(VideoCodecPolicy.decision(for: VideoConfig.codecH264,
                                                 hevcHardware: false), .decode(.avc))
        XCTAssertEqual(VideoCodecPolicy.decision(for: VideoConfig.codecHEVC,
                                                 hevcHardware: true), .decode(.hevc))
        XCTAssertEqual(VideoCodecPolicy.decision(for: VideoConfig.codecHEVC,
                                                 hevcHardware: false),
                       .refuse(token: "hevc"))
        XCTAssertEqual(VideoCodecPolicy.decision(for: 9, hevcHardware: true),
                       .refuse(token: "unknown"))
    }

    @MainActor
    func testTheViewRefusesAnUnknownConfigBeforeAnyDecoder() {
        let view = VideoLayerView(frame: .zero)
        let refused = expectation(description: "refused")
        var token: String?
        view.onCodecRefused = { accepted in
            token = accepted
            refused.fulfill()
        }
        view.configure(VideoConfig(codec: 9, width: 320, height: 240,
                                   parameterSets: [0, 0, 0, 1, 0x40]),
                       picture: .full(width: 320, height: 240))
        wait(for: [refused], timeout: 1)
        XCTAssertEqual(token, "unknown")
    }

    @MainActor
    func testAnUnsupportedCodecRefusesTheOpeningCover() throws {
        let manager = makeManager()
        let window = AppWindowController(stream: 1, pkg: "com.example.app", activity: nil,
                                         label: "Example", manager: manager)
        defer { window.window?.close() }
        XCTAssertTrue(window.isOpening)
        window.codecRefused("hevc")
        XCTAssertEqual(window.opening.state, .failed(reason: nil),
                       "the existing opening-cover refusal, unknown-code form")
        XCTAssertFalse(window.isStalled, "a codec refusal is not the phone being stuck")
    }

    @MainActor
    func testAnUnsupportedCodecClosesALiveWindowAsRefused() throws {
        let manager = makeManager()
        let window = AppWindowController(stream: 1, pkg: "com.example.app", activity: nil,
                                         label: "Example", manager: manager)
        let size = try XCTUnwrap(window.window).frame.size
        window.noteFirstFrame()
        XCTAssertFalse(window.isOpening)
        window.codecRefused("unknown")
        // The window's close is asynchronous through AppKit; the manager's
        // open set is the observable answer.
        XCTAssertTrue(spin { manager.openStreams.isEmpty },
                      "a live window with an undecodable codec must close")
        XCTAssertGreaterThan(size.width, 0)
    }

    @MainActor
    private func makeManager() -> WindowManager {
        let name = "dev.pocketdeck.tests.codec.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        let session = Session(endpoint: .hostPort(host: "127.0.0.1", port: 1), knownDeviceId: nil,
                              clientId: "test-client")
        return WindowManager(session: session, defaults: defaults)
    }

    @MainActor
    private func spin(_ condition: () -> Bool) -> Bool {
        for _ in 0..<200 {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        return condition()
    }
}

final class SessionHelloTests: XCTestCase {
    /// WIN-59: the wire list is the hardware test's own answer.
    func testTheHelloListsAVCAlwaysAndHEVCOnlyWithHardware() {
        XCTAssertEqual(Session.helloCodecs(hevcHardware: false), ["avc"])
        XCTAssertEqual(Session.helloCodecs(hevcHardware: true), ["avc", "hevc"])
    }
}
