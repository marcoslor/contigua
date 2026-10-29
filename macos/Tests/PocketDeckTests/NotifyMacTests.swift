import MediaPlayer
import UserNotifications
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

    func testTitleBuilderSuffixesThePhoneName() {
        XCTAssertEqual(NotifyMapping.title("Design review", phoneName: "Nicky"), "Design review (Nicky)")
        XCTAssertEqual(NotifyMapping.title("Design review", phoneName: ""), "Design review",
                       "a nameless phone adds no suffix")
        XCTAssertEqual(NotifyMapping.title(nil, phoneName: "Nicky"), "Nicky",
                       "an empty title is just the phone name")
        XCTAssertEqual(NotifyMapping.title("", phoneName: "Nicky"), "Nicky")
        XCTAssertEqual(NotifyMapping.title("   ", phoneName: "Nicky"), "Nicky")
    }

    func testTitleFallsBackToTheAppLabel() {
        let (title, body) = NotifyMapping.content(notification(text: "Deck at 4"),
                                                  phoneName: "Nicky", labelFor: { _ in "WhatsApp" })
        XCTAssertEqual(title, "WhatsApp (Nicky)")
        XCTAssertEqual(body, "Deck at 4")
    }

    func testTitleWithBodyIsShownAsIs() {
        let (title, body) = NotifyMapping.content(
            notification(title: "Design review", text: "Deck vs slides at 4"),
            phoneName: "Nicky", labelFor: { _ in "WhatsApp" })
        XCTAssertEqual(title, "Design review (Nicky)")
        XCTAssertEqual(body, "Deck vs slides at 4")
    }

    func testTitleOnlyFromAnUnlabeledPackageKeepsTheNameAsBody() {
        let (title, body) = NotifyMapping.content(
            notification(title: "File downloaded", text: nil),
            phoneName: "Nicky", labelFor: { _ in nil })
        XCTAssertEqual(title, "File downloaded (Nicky)")
        XCTAssertEqual(body, "com.whatsapp")
    }

    func testATitlelessUnlabeledNotificationIsJustThePhoneName() {
        let (title, body) = NotifyMapping.content(notification(text: "ping"),
                                                  phoneName: "Nicky", labelFor: { _ in nil })
        XCTAssertEqual(title, "Nicky")
        XCTAssertEqual(body, "ping")
    }

    func testEmptyContentBecomesTheAppLabelWithThePhoneName() {
        let (title, body) = NotifyMapping.content(notification(text: ""),
                                                  phoneName: "Nicky", labelFor: { _ in "WhatsApp" })
        XCTAssertEqual(title, "WhatsApp (Nicky)")
        XCTAssertEqual(body, "")
    }

    func testTitleOnlyFromALabeledPackageHasNoBody() {
        let (title, body) = NotifyMapping.content(notification(title: "WhatsApp", text: nil),
                                                  phoneName: "Nicky", labelFor: { _ in "WhatsApp" })
        XCTAssertEqual(title, "WhatsApp (Nicky)")
        XCTAssertEqual(body, "")
    }

    // MARK: recording (privacy: sizes, never text)

    func testRecordsCarrySizesAndPackagesNotText() {
        let line = NotifyMapping.record(
            posted: notification(pkg: "com.whatsapp", title: "Design review", text: "Deck vs slides at 4"),
            title: "Design review", body: "Deck vs slides at 4", thread: "phone-1",
            code: false, category: "pd.n.0123456789abcdef",
            facts: NotifyBannerFacts(alert: true, banners: 1, presented: 1, quiet: 0))
        XCTAssertEqual(line, "notify post id=k1 pkg=com.whatsapp titleLen=13 bodyLen=19 thread=phone-1"
            + " actions=0 reply=0 code=0 ongoing=0 category=pd.n.0123456789abcdef"
            + " alert=1 banners=1 presented=1 quiet=0")
        XCTAssertFalse(line.contains("Design"))
        XCTAssertFalse(line.contains("slides"))
        XCTAssertFalse(line.contains("Deck"))

        XCTAssertEqual(NotifyMapping.record(removed: "k1"), "notify remove id=k1")
        let click = NotifyMapping.record(opened: "com.whatsapp", id: "k1")
        XCTAssertFalse(click.contains("Design"))
        XCTAssertEqual(click, "notify click id=k1 pkg=com.whatsapp")

        // Part 2 lines: ids, indexes and lengths, never the reply or the code.
        XCTAssertEqual(NotifyMapping.record(action: "k1", index: 1, textLen: 9),
                       "notify action id=k1 i=1 textLen=9")
        XCTAssertEqual(NotifyMapping.record(dismissed: "k1"), "notify dismiss id=k1")
        XCTAssertEqual(NotifyMapping.record(dismissRefused: "k1"), "notify dismiss id=k1 refused=ongoing")
        XCTAssertEqual(NotifyMapping.record(copied: "k1", len: 4), "notify copy id=k1 len=4")
        XCTAssertEqual(NotifyMapping.record(muted: "com.x", phone: "phone-1"),
                       "notify muted pkg=com.x phone=phone-1")
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

    // MARK: NOTIFY-19: a quiet update replaces the banner without presenting it

    func testThePostPlanIsTheAndroidAlertRule() {
        XCTAssertEqual(NotifyPostPolicy.plan(alert: true, delivered: false), .banner)
        XCTAssertEqual(NotifyPostPolicy.plan(alert: false, delivered: false), .banner,
                       "a quiet post the Mac never showed is still shown once")
        XCTAssertEqual(NotifyPostPolicy.plan(alert: true, delivered: true), .replace)
        XCTAssertEqual(NotifyPostPolicy.plan(alert: false, delivered: true), .quietReplace)
    }

    func testAPostInsideTheHoldInheritsTheWaitingOne() {
        XCTAssertTrue(NotifyPostMerge.alert(new: true, superseded: false))
        XCTAssertTrue(NotifyPostMerge.alert(new: false, superseded: true))
        XCTAssertFalse(NotifyPostMerge.alert(new: false, superseded: false))
        XCTAssertFalse(NotifyPostMerge.alert(new: false, superseded: nil))
        XCTAssertFalse(NotifyPostMerge.delivered(supersededReplacesDelivered: false, requestIdExists: true),
                       "a post still in its hold was never handed to the system")
        XCTAssertTrue(NotifyPostMerge.delivered(supersededReplacesDelivered: true, requestIdExists: true))
        XCTAssertTrue(NotifyPostMerge.delivered(supersededReplacesDelivered: nil, requestIdExists: true))
        XCTAssertFalse(NotifyPostMerge.delivered(supersededReplacesDelivered: nil, requestIdExists: false))
    }

    func testTheRecordCarriesTheAlertAndTheBannerCounts() {        let quiet = NotifyBannerFacts(alert: false, banners: 1, presented: 1, quiet: 9)
        XCTAssertEqual(quiet.record, "alert=0 banners=1 presented=1 quiet=9")
        let first = NotifyBannerFacts(alert: true, banners: 1, presented: 1, quiet: 0)
        XCTAssertEqual(first.record, "alert=1 banners=1 presented=1 quiet=0")
    }

    func testAThreadedPostUsesThePhoneAndTheGroup() {
        XCTAssertEqual(NotifyMapping.thread(phoneId: "phone-1", group: nil), "phone-1")
        XCTAssertEqual(NotifyMapping.thread(phoneId: "phone-1", group: ""), "phone-1")
        XCTAssertEqual(NotifyMapping.thread(phoneId: "phone-1", group: "0123456789abcdef"),
                       "phone-1.0123456789abcdef")
        // Only the wire's own hash shape is a group: a raw key would leak a
        // chat or folder name into a thread identifier.
        XCTAssertEqual(NotifyMapping.thread(phoneId: "phone-1", group: "Family chat"), "phone-1")
        XCTAssertEqual(NotifyMapping.thread(phoneId: "phone-1", group: "0123456789ABCDEF"), "phone-1")
        XCTAssertEqual(NotifyMapping.thread(phoneId: "phone-1", group: "0123"), "phone-1")
    }

    @MainActor
    func testAGroupedPostIsThreadedUnderItsGroup() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("notify-group-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: url) }
        let center = NotifyCenter()
        center.log = url
        center.hold = 0
        center.post(PhoneNotification(id: "g1", pkg: "com.whatsapp", when: nil,
                                      title: "Chat", text: "One",
                                      group: "0123456789abcdef"),
                    phoneId: "phone-1", phoneName: "Nicky", labelFor: { _ in nil })
        center.post(PhoneNotification(id: "g2", pkg: "com.whatsapp", when: nil,
                                      title: "Chat", text: "Two", group: "Family chat"),
                    phoneId: "phone-1", phoneName: "Nicky", labelFor: { _ in nil })
        let lines = try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].contains(" thread=phone-1.0123456789abcdef "),
                      "a confirmed group hash threads under the phone and the group")
        XCTAssertTrue(lines[1].contains(" thread=phone-1 "),
                      "anything else joins the phone's own thread")
        XCTAssertFalse(lines.joined().contains("Family chat"), "a raw group key never reaches the record")
    }

    @MainActor
    func testAnUpdateInsideTheHoldStillPresentsTheFirstBanner() throws {
        // NOTIFY-19: an app often re-posts right away (an action, an icon). A
        // second post inside the 300 ms hold supersedes the first, which never
        // reached Notification Center: the delivered one must still present.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("notify-hold-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: url) }
        let center = NotifyCenter()
        center.log = url
        center.hold = 0.25
        center.post(PhoneNotification(id: "h1", pkg: "com.whatsapp", when: nil,
                                      title: "Chat", text: "One", alert: true),
                    phoneId: "phone-1", phoneName: "Nicky", labelFor: { _ in nil })
        center.post(PhoneNotification(id: "h1", pkg: "com.whatsapp", when: nil,
                                      title: "Chat", text: "One", alert: false),
                    phoneId: "phone-1", phoneName: "Nicky", labelFor: { _ in nil })
        let settled = expectation(description: "the hold elapsed")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { settled.fulfill() }
        wait(for: [settled], timeout: 3)
        let posts = try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n").map(String.init)
            .filter { $0.hasPrefix("notify post id=h1 ") }
        XCTAssertEqual(posts.count, 1, "the hold delivers one banner")
        XCTAssertTrue(posts.first?.hasSuffix("alert=1 banners=1 presented=1 quiet=0") == true,
                      "the first banner presented: \(posts.first ?? "none")")
    }

    @MainActor
    func testTenPostsOfOneKeyPresentOnceAndReplaceQuietly() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("notify-quiet-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: url) }
        let center = NotifyCenter()
        center.log = url
        center.hold = 0
        for step in 0..<10 {
            center.post(PhoneNotification(id: "q1", pkg: "com.whatsapp", when: nil,
                                          title: "Progress", text: "step \(step)",
                                          alert: step == 0),
                        phoneId: "phone-1", phoneName: "Nicky", labelFor: { _ in nil })
        }
        let lines = try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n").map(String.init)
        let posts = lines.filter { $0.hasPrefix("notify post id=q1 ") }
        XCTAssertEqual(posts.count, 10)
        XCTAssertEqual(posts.filter { $0.contains(" alert=1 ") }.count, 1)
        XCTAssertEqual(posts.filter { $0.contains(" alert=0 ") }.count, 9)
        XCTAssertEqual(posts.last?.hasSuffix("alert=0 banners=1 presented=1 quiet=9"), true,
                       "one delivered banner at the end; the last update was quiet")
        XCTAssertFalse(lines.joined().contains("step 4"), "no text reaches the record")
    }

    // MARK: click setting (ROADMAP D2)

    func testClickSettingDefaultsToOpenOnMacAndIsStoredPerPhone() {
        let suite = "notify-click-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(NotifyClickTarget.stored(deviceId: "phone-1", defaults: defaults), .mac,
                       "no stored value opens on the Mac")
        defaults.set(NotifyClickTarget.phone.rawValue, forKey: NotifyClickTarget.key(deviceId: "phone-1"))
        defaults.set(NotifyClickTarget.none.rawValue, forKey: NotifyClickTarget.key(deviceId: "phone-2"))
        XCTAssertEqual(NotifyClickTarget.stored(deviceId: "phone-1", defaults: defaults), .phone)
        XCTAssertEqual(NotifyClickTarget.stored(deviceId: "phone-2", defaults: defaults), .none)
        XCTAssertEqual(NotifyClickTarget.stored(deviceId: "phone-3", defaults: defaults), .mac,
                       "another phone keeps its own choice")
        defaults.set("bogus", forKey: NotifyClickTarget.key(deviceId: "phone-1"))
        XCTAssertEqual(NotifyClickTarget.stored(deviceId: "phone-1", defaults: defaults), .mac,
                       "an unknown stored value falls back to the default")
    }

    func testClickSettingMapsToItsAction() {
        XCTAssertEqual(NotifyClickTarget.mac.action, .openOnMac)
        XCTAssertEqual(NotifyClickTarget.phone.action, .openOnPhone)
        XCTAssertEqual(NotifyClickTarget.none.action, .dismiss)
    }

    func testDoNothingOpensNothingAndSendsNothing() {
        XCTAssertEqual(NotifyClickPlan.steps(for: .none), [])
    }

    func testOpenOnMacOpensTheWindowBeforeSendingSoAnOldPhoneStillOpensIt() {
        XCTAssertEqual(NotifyClickPlan.steps(for: .mac), [.openWindow, .send(.window)],
                       "window.open precedes notify.open: an older phone ignores the message")
        XCTAssertEqual(NotifyClickPlan.steps(for: .phone), [.send(.phone)],
                       "Open on phone opens no Mac window")
    }

    func testNotifyOpenMessageCarriesOnlyTheIdTargetAndWindowStream() {
        let window = NotifyOpenMessage.make(id: "k1", target: .window, stream: 7)
        XCTAssertEqual(window["t"] as? String, "notify.open")
        XCTAssertEqual(window["id"] as? String, "k1")
        XCTAssertEqual(window["target"] as? String, "window")
        XCTAssertEqual(window["stream"] as? Int, 7)

        let phone = NotifyOpenMessage.make(id: "k1", target: .phone)
        XCTAssertEqual(phone["target"] as? String, "phone")
        XCTAssertNil(phone["stream"], "the phone's own display needs no stream")
        XCTAssertNil(phone["pkg"], "the Mac never names a package or an intent")
        XCTAssertNil(phone["intent"])
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

    // MARK: media part 2

    func testNowPlayingInfoCarriesTheArtwork() {
        var state = MediaState.empty
        state.title = "tone440"
        state.receivedAt = 1_000.0
        // A 1x1 JPEG: the smallest picture the wire could carry.
        let jpeg = Data(base64Encoded: "/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAgGBgcGBQgHBwcJCQgKDBQNDAsLDBkSEw8UHRofHh0aHBwgJC4nICIsIxwcKDcpLDAxNDQ0Hyc5PTgyPC4zNDL/wAALCAABAAEBAREA/8QAFAABAAAAAAAAAAAAAAAAAAAACf/EABQQAQAAAAAAAAAAAAAAAAAAAAD/2gAIAQEAAD8AKp//2Q==")!
        let art = MediaArtwork.accepted(mime: "image/jpeg", width: 1, height: 1, data: jpeg).0
        XCTAssertNotNil(art)
        let info = MediaMapping.nowPlayingInfo(state, artwork: art)!
        XCTAssertNotNil(info[MPMediaItemPropertyArtwork])
        XCTAssertNil(MediaMapping.nowPlayingInfo(state)![MPMediaItemPropertyArtwork],
                     "without artwork the info carries none")
    }

    func testArtworkCapsAreTheWireCaps() {
        let jpeg = Data(base64Encoded: "/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAgGBgcGBQgHBwcJCQgKDBQNDAsLDBkSEw8UHRofHh0aHBwgJC4nICIsIxwcKDcpLDAxNDQ0Hyc5PTgyPC4zNDL/wAALCAABAAEBAREA/8QAFAABAAAAAAAAAAAAAAAAAAAACf/EABQQAQAAAAAAAAAAAAAAAAAAAAD/2gAIAQEAAD8AKp//2Q==")!
        XCTAssertNil(MediaArtwork.accepted(mime: "image/png", width: 1, height: 1, data: jpeg).0)
        XCTAssertNil(MediaArtwork.accepted(mime: "image/jpeg", width: 513, height: 1, data: jpeg).0)
        XCTAssertNil(MediaArtwork.accepted(mime: "image/jpeg", width: 0, height: 1, data: jpeg).0)
        XCTAssertNil(MediaArtwork.accepted(mime: "image/jpeg", width: 1, height: 1,
                                           data: Data(repeating: 0, count: MediaArtwork.maxBytes + 1)).0)
        XCTAssertNil(MediaArtwork.accepted(mime: "image/jpeg", width: 1, height: 1, data: Data()).0)
        XCTAssertNil(MediaArtwork.accepted(mime: "image/jpeg", width: 1, height: 1,
                                           data: Data(repeating: 0x41, count: 100)).0,
                     "bytes that do not decode are refused")
        // The log only ever sees a short hash, never the picture.
        let art = MediaArtwork.accepted(mime: "image/jpeg", width: 1, height: 1, data: jpeg).0!
        XCTAssertEqual(art.hashPrefix.count, 8)
        XCTAssertFalse(art.hashPrefix.contains("jpeg"))
    }

    func testMediaCommandWireShapes() {
        XCTAssertEqual(MediaMessage.command(.transport("play")) as NSDictionary,
                       ["t": "media.command", "action": "play"] as NSDictionary)
        let seek = MediaMessage.command(.seek(45_000), key: "s2")
        XCTAssertEqual(seek["t"] as? String, "media.command")
        XCTAssertEqual(seek["action"] as? String, "seek")
        XCTAssertEqual(seek["positionMs"] as? Int, 45_000)
        XCTAssertEqual(seek["key"] as? String, "s2")
        let volume = MediaMessage.command(.volume(9))
        XCTAssertEqual(volume["action"] as? String, "volume")
        XCTAssertEqual(volume["level"] as? Int, 9)
        XCTAssertNil(volume["key"], "no key acts on the chosen session, as an older Mac's command")
        XCTAssertEqual(MediaMessage.choose(key: "s2") as NSDictionary,
                       ["t": "media.choose", "key": "s2"] as NSDictionary)
        // Recording lines carry numbers only.
        XCTAssertEqual(MediaCommand.seek(1_500).record, "media command seek positionMs=1500")
        XCTAssertEqual(MediaCommand.volume(9).record, "media command volume level=9")
        XCTAssertEqual(MediaCommand.transport("next").record, "media command next")
    }

    /// A session's volume/volumeMax arrive together ("Media part 2"); a phone
    /// that sends neither is not told a level. The old fallback sent one
    /// unclamped, a guess no session could honour.
    func testAVolumeCommandNeedsTheSessionsMaximum() {
        let player = NowPlayingController()
        var commands: [MediaCommand] = []
        player.onCommand = { commands.append($0) }
        var noMaximum = MediaState()
        noMaximum.key = "s1"
        noMaximum.playing = true
        player.apply(noMaximum)
        player.perform(.volume(9))
        XCTAssertTrue(commands.isEmpty, "no maximum, no volume: \(commands)")

        var bounded = noMaximum
        bounded.volume = 8
        bounded.volumeMax = 15
        player.apply(bounded)
        player.perform(.volume(99))
        player.perform(.volume(-4))
        XCTAssertEqual(commands, [.volume(15), .volume(0)])
    }

    func testTheSessionPickerAppearsOnlyWithTwoSessions() {
        let one = [MediaSessionRow(key: "s1", pkg: "com.one", app: "One", playing: true)]
        let two = one + [MediaSessionRow(key: "s2", pkg: "com.two", app: "Two", playing: false)]
        XCTAssertFalse(MediaMenu.showsSessionPicker(one))
        XCTAssertTrue(MediaMenu.showsSessionPicker(two))
        XCTAssertEqual(MediaMenu.pickerTitle(two, chosen: "s2"), "Playing on phone: Two")
        XCTAssertEqual(MediaMenu.pickerTitle(two, chosen: "gone"), "Playing on phone: One",
                       "an unknown pick falls back to the system's first")
        XCTAssertEqual(MediaMenu.chosenApp(two, chosen: nil), "One")
    }

    func testSeekAndSkipStayInsideTheTrack() {
        var state = MediaState.empty
        state.playing = true
        state.positionMs = 20_000
        state.durationMs = 30_000
        state.rate = 1
        state.receivedAt = 1_000.0
        XCTAssertEqual(MediaMapping.seekTarget(seconds: 45, durationMs: 30_000), 30_000)
        XCTAssertEqual(MediaMapping.seekTarget(seconds: -5, durationMs: 30_000), 0)
        XCTAssertEqual(MediaMapping.skipTarget(of: state, seconds: 15, at: 1_000.0), 30_000)
        XCTAssertEqual(MediaMapping.skipTarget(of: state, seconds: -30, at: 1_000.0), 0)
        // A session without a duration: no upper clamp to invent.
        XCTAssertEqual(MediaMapping.seekTarget(seconds: 45, durationMs: nil), 45_000)
    }

    func testMediaStateCarriesThePartTwoFieldsWithoutText() {
        var state = MediaState.empty
        state.title = "tone440"
        state.artist = "someone"
        state.key = "s2"
        state.canSeek = true
        state.volume = 9
        state.volumeMax = 15
        state.receivedAt = 1_000.0
        XCTAssertEqual(state.volumeFraction ?? 0, 0.6, accuracy: 0.001)
        let line = MediaMapping.record(set: state)
        XCTAssertTrue(line.contains("canSeek=1"))
        XCTAssertTrue(line.contains("volume=9 volumeMax=15"))
        XCTAssertFalse(line.contains("tone440"))
        XCTAssertEqual(MediaMenu.trackLine(state), "tone440 — someone")
    }

    // MARK: banner actions (part 2)

    private func replyNotification() -> PhoneNotification {
        PhoneNotification(
            id: "pd-a1", pkg: "com.chat", when: nil, title: "Design review", text: "Deck at 4",
            ongoing: false,
            actions: [NotifyActionInfo(i: 0, title: "Mark as read"),
                      NotifyActionInfo(i: 1, title: "Reply", reply: true)],
        )
    }

    func testBannerActionIdentifiersParse() {
        XCTAssertEqual(NotifyBannerAction.parse(identifier: UNNotificationDefaultActionIdentifier, text: nil), .open)
        XCTAssertEqual(NotifyBannerAction.parse(identifier: UNNotificationDismissActionIdentifier, text: nil), .dismiss)
        XCTAssertEqual(NotifyBannerAction.parse(identifier: "pd.copy", text: nil), .copyCode)
        XCTAssertEqual(NotifyBannerAction.parse(identifier: "pd.a.0", text: nil), .button(0))
        XCTAssertEqual(NotifyBannerAction.parse(identifier: "pd.r.1", text: "hi"), .reply(1, "hi"))
        XCTAssertNil(NotifyBannerAction.parse(identifier: "pd.a.x", text: nil))
        XCTAssertNil(NotifyBannerAction.parse(identifier: "pd.other", text: nil))
    }

    func testCategoryIdIsStablePerShapeAndCarriesNoText() {
        let a = NotifyCategories.identifier(titles: ["Mark as read", "Reply"], reply: true, code: false)
        let b = NotifyCategories.identifier(titles: ["Mark as read", "Reply"], reply: true, code: false)
        XCTAssertEqual(a, b)
        XCTAssertTrue(a.hasPrefix("pd.n."))
        XCTAssertEqual(a.count, "pd.n.".count + 16, "a 64-bit hash, fixed width")
        XCTAssertFalse(a.contains("Mark"))
        XCTAssertFalse(a.contains("Reply"))
        XCTAssertNotEqual(a, NotifyCategories.identifier(titles: ["Reply", "Mark as read"], reply: true, code: false))
        XCTAssertNotEqual(a, NotifyCategories.identifier(titles: ["Mark as read", "Reply"], reply: true, code: true))
        XCTAssertNotEqual(a, NotifyCategories.identifier(titles: ["Mark as read", "Reply"], reply: false, code: false))
    }

    func testCategoryRegistryReusesShapesAndStaysBounded() {
        let registry = NotifyCategoryRegistry()
        var updates = 0
        registry.onUpdate = { _ in updates += 1 }

        let first = registry.category(for: replyNotification(), hasCode: false)
        XCTAssertEqual(registry.category(for: replyNotification(), hasCode: false), first)
        XCTAssertEqual(updates, 1, "the same shape is registered once")
        XCTAssertEqual(registry.count, 1)

        let withCode = registry.category(for: replyNotification(), hasCode: true)
        XCTAssertNotEqual(withCode, first)
        XCTAssertEqual(registry.count, 2)

        for index in 0..<100 {
            let n = PhoneNotification(id: "k\(index)", pkg: "com.chat", when: nil, title: nil, text: nil,
                                      actions: [NotifyActionInfo(i: 0, title: "button \(index)")])
            _ = registry.category(for: n, hasCode: false)
        }
        XCTAssertEqual(registry.count, NotifyCategories.maxRegistered)
        XCTAssertEqual(registry.all().count, NotifyCategories.maxRegistered)
    }

    func testMutedSetIsPerPhoneAndSorted() {
        let suite = "notify-mute-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertTrue(NotifyMute.muted(deviceId: "p1", defaults: defaults).isEmpty)
        NotifyMute.setMuted(true, pkg: "com.b", deviceId: "p1", defaults: defaults)
        NotifyMute.setMuted(true, pkg: "com.a", deviceId: "p1", defaults: defaults)
        NotifyMute.setMuted(true, pkg: "com.c", deviceId: "p2", defaults: defaults)
        XCTAssertTrue(NotifyMute.isMuted("com.a", deviceId: "p1", defaults: defaults))
        XCTAssertFalse(NotifyMute.isMuted("com.c", deviceId: "p1", defaults: defaults))
        XCTAssertEqual(defaults.stringArray(forKey: NotifyMute.key(deviceId: "p1")), ["com.a", "com.b"],
                       "sorted, package names only")
        NotifyMute.setMuted(false, pkg: "com.a", deviceId: "p1", defaults: defaults)
        XCTAssertFalse(NotifyMute.isMuted("com.a", deviceId: "p1", defaults: defaults))
    }
}
