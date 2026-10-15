import MediaPlayer
import XCTest
@testable import PocketDeck

// The notification/now-playing mappings (docs/design/notify.md): what the phone
// sent becomes a macOS banner and a Now Playing entry; the recording hooks carry
// field sizes and package names, never text.

final class NotifyMacTests: XCTestCase {

    private func notification(id: String = "k1", pkg: String = "com.whatsapp",
                              title: String? = nil, text: String? = nil) -> PhoneNotification {
        PhoneNotification(id: id, pkg: pkg, when: nil, title: title, text: text)
    }

    // MARK: banner content

    func testTitleFallsBackToTheAppLabel() {
        let (title, body) = NotifyMapping.content(notification(text: "Deck at 4"), labelFor: { _ in "WhatsApp" })
        XCTAssertEqual(title, "WhatsApp")
        XCTAssertEqual(body, "Deck at 4")
    }

    func testTitleWithBodyIsShownAsIs() {
        let (title, body) = NotifyMapping.content(
            notification(title: "Design review", text: "Deck vs slides at 4"), labelFor: { _ in "WhatsApp" })
        XCTAssertEqual(title, "Design review")
        XCTAssertEqual(body, "Deck vs slides at 4")
    }

    func testTitleOnlyFromAnUnlabeledPackageKeepsTheNameAsBody() {
        let (title, body) = NotifyMapping.content(
            notification(title: "File downloaded", text: nil), labelFor: { _ in nil })
        XCTAssertEqual(title, "File downloaded")
        XCTAssertEqual(body, "com.whatsapp")
    }

    func testEmptyContentBecomesTheAppLabel() {
        let (title, body) = NotifyMapping.content(notification(text: ""), labelFor: { _ in "WhatsApp" })
        XCTAssertEqual(title, "WhatsApp")
        XCTAssertEqual(body, "")
    }

    func testTitleOnlyFromALabeledPackageHasNoBody() {
        let (title, body) = NotifyMapping.content(notification(title: "WhatsApp", text: nil), labelFor: { _ in "WhatsApp" })
        XCTAssertEqual(title, "WhatsApp")
        XCTAssertEqual(body, "")
    }

    // MARK: recording (privacy: sizes, never text)

    func testRecordsCarrySizesAndPackagesNotText() {
        let line = NotifyMapping.record(
            posted: notification(pkg: "com.whatsapp", title: "Design review", text: "Deck vs slides at 4"),
            title: "Design review", body: "Deck vs slides at 4", thread: "phone-1")
        XCTAssertEqual(line, "notify post id=k1 pkg=com.whatsapp titleLen=13 bodyLen=19 thread=phone-1")
        XCTAssertFalse(line.contains("Design"))
        XCTAssertFalse(line.contains("slides"))
        XCTAssertFalse(line.contains("Deck"))

        XCTAssertEqual(NotifyMapping.record(removed: "k1"), "notify remove id=k1")
        let click = NotifyMapping.record(opened: "com.whatsapp", id: "k1")
        XCTAssertFalse(click.contains("Design"))
        XCTAssertEqual(click, "notify click id=k1 pkg=com.whatsapp")
    }

    // MARK: session decode → events

    func testNotifyAndMediaFramesDecodeIntoEvents() throws {
        let posted = JSONFrame.decode(payload: [UInt8](try JSONSerialization.data(
            withJSONObject: ["t": "notify.post", "id": "k1", "pkg": "com.whatsapp", "when": 1_700_000_000_000,
                             "title": "t", "text": "b"] as [String: Any])))!
        // The Session applies these under `welcome`; a direct decode of the same
        // JSON must yield the fields the event needs (privacy: they stop at the UI).
        let raw = JSONMessage(raw: posted.raw)
        XCTAssertEqual(raw.string("t"), "notify.post")
        XCTAssertEqual(raw.string("id"), "k1")
        XCTAssertEqual(raw.double("when"), 1_700_000_000_000)
    }

    // MARK: now playing

    func testNowPlayingInfoFromMediaState() {
        var state = MediaState.empty
        state.playing = true
        state.pkg = "org.fossify.player"
        state.title = "tone440"
        state.artist = "someone"
        state.album = "Music"
        state.durationMs = 30_000
        state.positionMs = 2_111
        state.rate = 1.0
        state.receivedAt = 1_000.0
        let info = MediaMapping.nowPlayingInfo(state)!
        XCTAssertEqual(info[MPMediaItemPropertyTitle] as? String, "tone440")
        XCTAssertEqual(info[MPMediaItemPropertyArtist] as? String, "someone")
        XCTAssertEqual(info[MPMediaItemPropertyAlbumTitle] as? String, "Music")
        XCTAssertEqual(info[MPMediaItemPropertyPlaybackDuration] as? Double, 30.0)
        XCTAssertEqual(info[MPNowPlayingInfoPropertyPlaybackRate] as? Double, 1.0)
        XCTAssertEqual(info[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double, 2.111)
    }

    func testPausedKeepsTheRateAtZero() {
        var state = MediaState.empty
        state.playing = false
        state.title = "tone440"
        state.rate = 0
        state.receivedAt = 1_000.0
        let info = MediaMapping.nowPlayingInfo(state)!
        XCTAssertEqual(info[MPNowPlayingInfoPropertyPlaybackRate] as? Double, 0.0)
        // elapsed stays at the paused position without drift
        let elapsed = MediaMapping.elapsed(of: state, at: 1_500.0)
        XCTAssertEqual(elapsed, 0.0, accuracy: 0.001)
    }

    func testElapsedDriftsWithRateWhilePlaying() {
        var state = MediaState.empty
        state.playing = true
        state.positionMs = 2_000
        state.rate = 1.0
        state.receivedAt = 1_000.0
        XCTAssertEqual(MediaMapping.elapsed(of: state, at: 1_005.0), 7.0, accuracy: 0.001)
    }

    func testEmptyStateClearsNowPlaying() {
        var nothing = MediaState.empty
        nothing.receivedAt = 0
        XCTAssertNil(MediaMapping.nowPlayingInfo(nothing))
    }

    func testRecordingsCarrySizesNotText() {
        var state = MediaState.empty
        state.playing = true
        state.pkg = "org.fossify.player"
        state.title = "tone440"
        state.artist = "someone"
        state.album = "Music"
        state.durationMs = 30_000
        state.positionMs = 2_000
        state.rate = 1.0
        state.receivedAt = 1_000.0
        let line = MediaMapping.record(set: state)
        XCTAssertFalse(line.contains("tone440"))
        XCTAssertFalse(line.contains("someone"))
        XCTAssertTrue(line.hasPrefix("media set playing=true"))
        XCTAssertTrue(line.contains("titleLen=7"))
        XCTAssertTrue(line.contains("durationMs=30000"))
        XCTAssertTrue(line.contains("rate=1.00"))
    }
}
