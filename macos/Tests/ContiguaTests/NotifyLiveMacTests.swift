import UserNotifications
import XCTest
@testable import Contigua

// Notification images and Android 16 Live Updates (docs/design/notify.md,
// "Part 2b design"): the store's in-place updates and one-per-second rule, the
// menu bar row text, the Mac's image caps and the recording lines. No real
// picture bytes or hashes appear anywhere here.

final class NotifyLiveMacTests: XCTestCase {

    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    private func live(progress: Double? = nil, chip: String? = nil,
                      chrono: Date? = nil, countDown: Bool = false) -> NotifyLive {
        NotifyLive(progress: progress, chip: chip, chrono: chrono, countDown: countDown)
    }

    // MARK: live store

    func testFirstLivePostBannersAndLaterOnesUpdateInPlace() {
        let store = NotifyLiveStore()
        XCTAssertEqual(store.post(id: "l1", pkg: "com.uber", label: "Uber",
                                  live: live(progress: 0.1, chip: "4 min"), now: base), .banner)
        XCTAssertEqual(store.items.count, 1)
        XCTAssertEqual(store.post(id: "l1", pkg: "com.uber", label: "Uber",
                                  live: live(progress: 0.4, chip: "3 min"),
                                  now: base.addingTimeInterval(1.2)), .updated)
        let item = store.item("l1")!
        XCTAssertEqual(item.progress!, 0.4, accuracy: 0.0001)
        XCTAssertEqual(item.chip, "3 min")
        XCTAssertEqual(store.items.count, 1, "an update never adds a row")
    }

    func testUpdatesInsideOneSecondAreCoalescedAndTheNewestWins() {
        let store = NotifyLiveStore()
        _ = store.post(id: "l1", pkg: "com.uber", label: nil, live: live(progress: 0.1), now: base)
        // Four updates within the window: none applies yet.
        for step in 1...4 {
            let when = base.addingTimeInterval(Double(step) * 0.2)
            XCTAssertEqual(store.post(id: "l1", pkg: "com.uber", label: nil,
                                      live: live(progress: 0.1 * Double(step + 1)), now: when),
                           .coalesced)
        }
        XCTAssertEqual(store.item("l1")!.progress!, 0.1, accuracy: 0.0001)
        XCTAssertTrue(store.hasPending)
        // Before the window opens nothing is applied…
        XCTAssertTrue(store.flush(now: base.addingTimeInterval(0.9)).isEmpty)
        // …at the boundary the newest state lands, once.
        let applied = store.flush(now: base.addingTimeInterval(1.0))
        XCTAssertEqual(applied.count, 1)
        XCTAssertEqual(applied[0].progress!, 0.5, accuracy: 0.0001)
        XCTAssertFalse(store.hasPending)
        XCTAssertEqual(store.flush(now: base.addingTimeInterval(1.1)).count, 0)
    }

    func testDifferentIdsHaveTheirOwnWindows() {
        let store = NotifyLiveStore()
        _ = store.post(id: "a", pkg: "com.a", label: nil, live: live(progress: 0.1), now: base)
        XCTAssertEqual(store.post(id: "b", pkg: "com.b", label: nil,
                                  live: live(progress: 0.2), now: base.addingTimeInterval(0.1)),
                       .banner)
        XCTAssertEqual(store.items.count, 2)
    }

    func testEndRemovesTheRowAndAPendingUpdate() {
        let store = NotifyLiveStore()
        _ = store.post(id: "l1", pkg: "com.uber", label: nil, live: live(progress: 0.1), now: base)
        _ = store.post(id: "l1", pkg: "com.uber", label: nil, live: live(progress: 0.2),
                       now: base.addingTimeInterval(0.2))
        XCTAssertTrue(store.hasPending)
        XCTAssertTrue(store.end("l1"))
        XCTAssertTrue(store.items.isEmpty)
        XCTAssertFalse(store.hasPending)
        XCTAssertTrue(store.flush(now: base.addingTimeInterval(5)).isEmpty)
        XCTAssertFalse(store.end("l1"), "ending twice is a no-op")
    }

    func testClearDropsEverything() {
        let store = NotifyLiveStore()
        _ = store.post(id: "l1", pkg: "com.uber", label: nil, live: live(progress: 0.1), now: base)
        store.clear()
        XCTAssertTrue(store.items.isEmpty)
        XCTAssertEqual(store.post(id: "l1", pkg: "com.uber", label: nil,
                                  live: live(progress: 0.3), now: base), .banner)
    }

    // MARK: menu bar text

    func testLiveRowCarriesTheChipAndATextProgressBar() {
        let item = NotifyLiveItem(id: "l1", pkg: "com.uber", label: "Uber", chip: "4 min",
                                  progress: 0.6, chrono: nil, countDown: false, updated: base)
        XCTAssertEqual(NotifyLiveText.menuTitle(item, now: base), "Uber — 4 min ▮▮▮▮▮▮▯▯▯▯")
        // No label: the package names the row.
        var bare = item
        bare.label = nil
        XCTAssertTrue(NotifyLiveText.menuTitle(bare, now: base).hasPrefix("com.uber — "))
    }

    func testAChronometerRunsInItsOwnDirection() {
        let chrono = base.addingTimeInterval(65)
        let down = NotifyLiveItem(id: "l1", pkg: "com.uber", label: "Uber", chip: nil,
                                  progress: nil, chrono: chrono, countDown: true, updated: base)
        XCTAssertEqual(NotifyLiveText.menuTitle(down, now: base), "Uber — 1:05")
        // Countdown passed zero: it stays at 0:00 rather than going negative.
        XCTAssertEqual(NotifyLiveText.clock(chrono, countDown: true,
                                            now: base.addingTimeInterval(120)), "0:00")
        let up = NotifyLiveItem(id: "l1", pkg: "com.uber", label: "Uber", chip: nil,
                                progress: nil, chrono: base, countDown: false, updated: base)
        XCTAssertEqual(NotifyLiveText.menuTitle(up, now: base.addingTimeInterval(3723)),
                       "Uber — 1:02:03")
    }

    func testTheProgressBarClampsAndRounds() {
        XCTAssertEqual(NotifyLiveText.progressBar(0), "▯▯▯▯▯▯▯▯▯▯")
        XCTAssertEqual(NotifyLiveText.progressBar(1), "▮▮▮▮▮▮▮▮▮▮")
        XCTAssertEqual(NotifyLiveText.progressBar(2), "▮▮▮▮▮▮▮▮▮▮")
        XCTAssertEqual(NotifyLiveText.progressBar(-1), "▯▯▯▯▯▯▯▯▯▯")
        XCTAssertEqual(NotifyLiveText.progressBar(0.44).filter { $0 == "▮" }.count, 4)
    }

    // MARK: the wire's live object

    func testTheWireLiveObjectIsCappedAndClamped() {
        let parsed = NotifyLive(json: ["progress": 1.7, "chip": "  4 min to arrival  ",
                                       "chrono": 1_700_000_000_000, "countDown": true])!
        XCTAssertEqual(parsed.progress!, 1.0, accuracy: 0.0001)
        XCTAssertEqual(parsed.chip, "4 min to arrival")
        XCTAssertNotNil(parsed.chrono)
        XCTAssertTrue(parsed.countDown)

        XCTAssertNil(NotifyLive(json: nil))
        XCTAssertNil(NotifyLive(json: "nope"))
        let empty = NotifyLive(json: [String: Any]())!
        XCTAssertNil(empty.progress)
        XCTAssertNil(empty.chip)
        let negated = NotifyLive(json: ["progress": -3, "chrono": 0])!
        XCTAssertEqual(negated.progress!, 0, accuracy: 0.0001)
        XCTAssertNil(negated.chrono, "a zero chrono is not a time")
    }

    // MARK: image caps and records

    func testImageCapsAcceptOnlyThePhonePromisedShape() {
        XCTAssertNil(NotifyImageCaps.refusal(mime: "image/jpeg", width: 512, height: 384,
                                             decoded: 100_000))
        XCTAssertNil(NotifyImageCaps.refusal(mime: "image/png", width: 1024, height: 1, decoded: 1))
        XCTAssertEqual(NotifyImageCaps.refusal(mime: "image/gif", width: 10, height: 10, decoded: 10),
                       "mime")
        XCTAssertEqual(NotifyImageCaps.refusal(mime: "image/jpeg", width: 1025, height: 10, decoded: 10),
                       "size")
        XCTAssertEqual(NotifyImageCaps.refusal(mime: "image/jpeg", width: 0, height: 10, decoded: 10),
                       "size")
        XCTAssertEqual(NotifyImageCaps.refusal(mime: "image/jpeg", width: 10, height: 10,
                                               decoded: NotifyImageCaps.maxBytes + 1), "bytes")
        XCTAssertEqual(NotifyImageCaps.refusal(mime: "image/jpeg", width: 10, height: 10, decoded: 0),
                       "bytes")
        XCTAssertEqual(NotifyImageCaps.fileExtension("image/png"), "png")
        XCTAssertEqual(NotifyImageCaps.fileExtension("image/jpeg"), "jpg")
    }

    func testImageAndLiveLinesCarryOnlyFacts() {
        let info = NotifyImageInfo(mime: "image/jpeg", width: 512, height: 384, size: 1234,
                                   attachment: "/tmp/p/notify/pd.phone.k1.jpg")
        XCTAssertEqual(NotifyMapping.record(image: "k1", info: info),
                       "notify image id=k1 image=image/jpeg w=512 h=384 size=1234"
                       + " attachment=/tmp/p/notify/pd.phone.k1.jpg")
        XCTAssertEqual(NotifyMapping.record(imageRefused: "k1", reason: "bytes"),
                       "notify image id=k1 refused=bytes")
        XCTAssertEqual(NotifyMapping.record(imageLate: "k1"), "notify image id=k1 late")
        let at = Date(timeIntervalSince1970: 1_700_000_000.5)
        XCTAssertEqual(NotifyMapping.record(live: "l1", progress: 0.62, chip: "4 min",
                                            chrono: false, countDown: false, at: at),
                       "notify live id=l1 progress=6 chip=5 chrono=0 countDown=0 at=1700000000500")
        XCTAssertEqual(NotifyMapping.record(live: "l1", progress: nil, chip: nil,
                                            chrono: true, countDown: true, at: at),
                       "notify live id=l1 progress=- chip=0 chrono=1 countDown=1 at=1700000000500")
        XCTAssertEqual(NotifyMapping.record(liveEnded: "l1"), "notify live id=l1 end")
    }

    func testThePostLineSaysItIsLiveAndCarriesTheImageFacts() {
        let n = PhoneNotification(id: "l1", pkg: "com.uber", when: nil, title: "Ride",
                                  text: "Arriving", live: live(progress: 0.2))
        let facts = NotifyBannerFacts(alert: true, banners: 1, presented: 1, quiet: 0)
        var line = NotifyMapping.record(posted: n, title: "Ride (Nicky)", body: "Arriving",
                                        thread: "phone-1", code: false, category: "pd.n.x",
                                        facts: facts)
        XCTAssertTrue(line.hasSuffix(" live=1"))
        let info = NotifyImageInfo(mime: "image/jpeg", width: 160, height: 120, size: 1615)
        line = NotifyMapping.record(posted: n, title: "Ride (Nicky)", body: "Arriving",
                                    thread: "phone-1", code: false, category: "pd.n.x",
                                    facts: facts, image: info)
        XCTAssertTrue(line.contains(" image=image/jpeg w=160 h=120 size=1615"))
    }

    // MARK: session decode

    func testNotifyImageFrameDecodesToAnEvent() throws {
        let payload = try JSONSerialization.data(withJSONObject: [
            "t": "notify.image", "id": "k1", "mime": "image/jpeg", "w": 160, "h": 120,
            "data": Data([0xFF, 0xD8, 0xFF]).base64EncodedString(),
        ])
        let frame = JSONFrame.decode(payload: [UInt8](payload))!
        XCTAssertEqual(frame.string("t"), "notify.image")
        XCTAssertEqual(frame.int("w"), 160)
        XCTAssertEqual(frame.data("data"), Data([0xFF, 0xD8, 0xFF]))
    }
}
