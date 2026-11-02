// WIN-38: a stream the Mac has closed is quiet. The phone forgets the stream
// at the one `window.close` and answers any later message for it with
// `error no_stream`; the Mac's own late sends (the mapper's throttled hover
// flush and the closing window's occlusion pause are the two the person's
// report showed) must never leave the Session, and each is logged once by type
// and id.

import CryptoKit
import XCTest
@testable import PocketDeck

final class ClosedStreamTests: XCTestCase {
    func testTheCloseIsTheLastMessageForItsStream() {
        var closed = ClosedStreams()
        XCTAssertEqual(closed.decide(type: "window.close", stream: 1), .send)
        XCTAssertEqual(closed.ids, [1])

        // Every per-stream message kind a window can leave behind.
        for type in ["window.pause", "window.resume", "window.keyframe", "window.quality",
                     "window.resize", "nav", "text", "notify.open",
                     "touch", "scroll", "hover", "key"] {
            XCTAssertEqual(closed.decide(type: type, stream: 1), .drop, "\(type) for the closed stream")
            XCTAssertEqual(closed.decide(type: type, stream: 2), .send, "\(type) for another stream")
        }

        // A second close is late too: the phone has forgotten the stream.
        XCTAssertEqual(closed.decide(type: "window.close", stream: 1), .drop)

        // A new open on that id makes it live again.
        XCTAssertEqual(closed.decide(type: "window.open", stream: 1), .send)
        XCTAssertEqual(closed.decide(type: "window.pause", stream: 1), .send)
        XCTAssertEqual(closed.decide(type: "link.open", stream: 1), .send)
        XCTAssertEqual(closed.decide(type: "task.continue", stream: 1), .send)
    }

    /// RR-9: an open stream is the session's "activity" while the phone's
    /// screen is off; the close ends it. RRR-5: only an accepted open counts,
    /// and the phone's own close forgets it.
    func testAnOpenStreamCountsAsActivityUntilItCloses() {
        var streams = ClosedStreams()
        XCTAssertFalse(streams.hasOpenStream)
        XCTAssertEqual(streams.decide(type: "window.open", stream: 1), .send)
        streams.opened(1)
        XCTAssertTrue(streams.hasOpenStream)
        XCTAssertEqual(streams.decide(type: "window.open", stream: 2), .send)
        streams.opened(2)
        XCTAssertEqual(streams.decide(type: "window.close", stream: 1), .send)
        XCTAssertTrue(streams.hasOpenStream, "stream 2 is still open")
        XCTAssertEqual(streams.decide(type: "window.close", stream: 2), .send)
        XCTAssertFalse(streams.hasOpenStream)
    }

    /// RRR-5: the phone ended a stream (`window.closed`, or `error no_stream`
    /// for it). It stops counting as activity, but a late message for it is
    /// still dropped.
    func testAStreamThePhoneClosedStopsCountingAsActivity() {
        var streams = ClosedStreams()
        XCTAssertEqual(streams.decide(type: "window.open", stream: 7), .send)
        streams.opened(7)
        XCTAssertTrue(streams.hasOpenStream)
        streams.forget(7)
        XCTAssertFalse(streams.hasOpenStream)
        XCTAssertEqual(streams.decide(type: "hover", stream: 7), .drop)
        // An accepted open on that id makes it live again.
        XCTAssertEqual(streams.decide(type: "window.open", stream: 7), .send)
        streams.opened(7)
        XCTAssertTrue(streams.hasOpenStream)
    }

    /// RRR-5/E-2: a `window.open` dropped before founding is not an open
    /// stream, so it never keeps the fast ping alive for a window that does
    /// not exist.
    func testAnUnacceptedOpenIsNotAnOpenStream() {
        var streams = ClosedStreams()
        XCTAssertEqual(streams.decide(type: "window.open", stream: 3), .send)
        XCTAssertFalse(streams.hasOpenStream, "only the accepted send opens a stream")
    }

    func testEachOpenerRevivesTheStream() {
        for opener in ClosedStreams.opening {
            var closed = ClosedStreams()
            XCTAssertEqual(closed.decide(type: "window.close", stream: 9), .send)
            XCTAssertEqual(closed.decide(type: opener, stream: 9), .send, opener)
            XCTAssertEqual(closed.decide(type: "window.pause", stream: 9), .send, "\(opener) revived 9")
        }
    }

    func testALateMessageLogsItsTypeAndStreamOnly() {
        XCTAssertEqual(ClosedStreams.lateLog(type: "window.pause", stream: 4),
                       "late window.pause for closed stream 4")
        XCTAssertEqual(ClosedStreams.lateLog(type: "hover", stream: 12),
                       "late hover for closed stream 12")
    }
}

/// The frames the fake phone received, in order, by protocol name.
private final class FrameSpy: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []

    var messages: [String] {
        lock.lock(); defer { lock.unlock() }
        return values
    }

    func append(_ frame: Frame) {
        var name = String(describing: frame.messageType ?? .json)
        if frame.messageType == .json, let message = JSONFrame.decode(payload: frame.payload) {
            name = message.t
        }
        lock.lock(); values.append(name); lock.unlock()
    }

    func reset() { lock.lock(); values.removeAll(); lock.unlock() }
}

final class ClosedStreamSendTests: XCTestCase {
    private var macIdentity: (identity: DeviceIdentityV2, privateKey: P256.Signing.PrivateKey)!
    private var phoneIdentity: DeviceIdentityV2!
    private var brain: FakeV2PhoneBrain!
    private var server: FakeServer!
    private let spy = FrameSpy()

    override func setUp() {
        macIdentity = IdentityGeneratorV2.make(deviceId: "mac-\(UUID().uuidString.prefix(8))")
        phoneIdentity = IdentityGeneratorV2.make(deviceId: "phone-\(UUID().uuidString.prefix(8))",
                                                 cn: "PocketDeck Phone").identity
    }

    override func tearDown() {
        server?.stop()
    }

    private func waitFor(_ condition: () -> Bool, _ message: @autoclosure () -> String = "condition never held",
                         timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02))
        }
        return condition()
    }

    private func spin(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date(timeIntervalSinceNow: seconds))
    }

    /// The real Session send path against a fake phone: after `window.close`,
    /// none of the messages the closed window can leave behind reach it.
    func testNothingReachesThePhoneForAClosedStream() throws {
        server = try FakeServer(phoneIdentity: phoneIdentity, trustingClientPem: macIdentity.identity.certPem)
        brain = FakeV2PhoneBrain(identity: phoneIdentity, deviceId: "phone-1")
        brain.autoAllow = true
        server.brain = brain
        server.onFrame = { [spy] _, frame in spy.append(frame) }
        let session = Session(endpoint: .hostPort(host: "127.0.0.1", port: server.port),
                              knownDeviceId: nil, clientId: "test-client", identity: macIdentity.identity)
        session.pairingPolicy = .allowed
        session.start()
        XCTAssertTrue(waitFor { session.state == .ready }, "not ready: \(session.state)")
        defer { session.close() }

        server.brain = nil
        spy.reset()
        session.closeWindow(stream: 1)
        XCTAssertTrue(waitFor { self.spy.messages == ["window.close"] },
                      "the close itself never reached the phone: \(spy.messages)")

        // The messages the person's close left behind (e2e repro: a hover
        // flushed 16 ms late and the closing window's occlusion pause), plus
        // every other per-stream kind, and a second close.
        session.pauseWindow(stream: 1)
        session.resumeWindow(stream: 1)
        session.requestKeyframe(stream: 1)
        session.resizeWindow(stream: 1, width: 900, height: 600, dpi: 160)
        session.nav(stream: 1, action: "back")
        session.text(stream: 1, text: "x")
        session.touch(TouchEvent(action: .down, nx: 0.5, ny: 0.5), stream: 1)
        session.scroll(ScrollEvent(nx: 0.5, ny: 0.5, hscroll: 0, vscroll: 1), stream: 1)
        session.hover(HoverEvent(action: .move, nx: 0.5, ny: 0.5), stream: 1)
        session.key(KeyEvent(action: 0, keycode: 4), stream: 1)
        session.closeWindow(stream: 1)
        spin(0.4)
        XCTAssertEqual(spy.messages, ["window.close"], "a late message reached the phone")

        // Another stream is untouched.
        session.closeWindow(stream: 2)
        XCTAssertTrue(waitFor { self.spy.messages == ["window.close", "window.close"] },
                      "another stream's close was dropped: \(spy.messages)")

        // An open on the same id makes it live again (a reused stream id).
        session.openApp(stream: 1, pkg: "com.example.app", activity: nil, width: 900, height: 600, dpi: 160)
        XCTAssertTrue(waitFor { self.spy.messages.last == "window.open" },
                      "the open never reached the phone: \(spy.messages)")
        session.pauseWindow(stream: 1)
        XCTAssertTrue(waitFor { self.spy.messages.suffix(2) == ["window.open", "window.pause"] },
                      "the revived stream's pause was dropped: \(spy.messages)")
    }
}
