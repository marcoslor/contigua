import UserNotifications
import XCTest
@testable import PocketDeck

// NOTIFY-1/PATH-6 (ISS-5): after a same-session rejoin the phone answers the
// repeated `notify.enable` with its active set — the posts then one
// `notify.snapshot` naming the ids it still holds. The Mac reconciles against
// it: a row or banner the set no longer has leaves, and a changed one updates
// in place without a second banner. Records carry ids and counts, never text.

final class NotifySnapshotMacTests: XCTestCase {

    private func temporaryLog() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("notify-snapshot-\(UUID().uuidString).log")
    }

    @MainActor
    private func center(log: URL) -> NotifyCenter {
        let center = NotifyCenter()
        center.log = log
        center.hold = 0
        return center
    }

    private func lines(_ url: URL) throws -> [String] {
        try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n").map(String.init)
    }

    private func live(_ progress: Double) -> NotifyLive {
        NotifyLive(progress: progress)
    }

    /// A changed row is updated in place by the snapshot's post: the person
    /// gets the new progress and no second banner.
    @MainActor
    func testASnapshotUpdatesAChangedRowInPlaceWithoutASecondBanner() throws {
        let url = temporaryLog()
        defer { try? FileManager.default.removeItem(at: url) }
        let center = center(log: url)
        center.post(PhoneNotification(id: "l1", pkg: "com.uber", when: nil,
                                      title: "Ride", text: "Arriving",
                                      live: live(0.2), alert: true),
                    phoneId: "phone-1", phoneName: "Nicky", phonesPaired: 2, labelFor: { _ in nil })
        // The one-per-second window must be open before the snapshot's post.
        Thread.sleep(forTimeInterval: 1.05)  // real-time: the Live Update store's window is wall-clock
        center.post(PhoneNotification(id: "l1", pkg: "com.uber", when: nil,
                                      title: "Ride", text: "Arriving",
                                      live: live(0.9), alert: false),
                    phoneId: "phone-1", phoneName: "Nicky", phonesPaired: 2, labelFor: { _ in nil })
        center.snapshot(ids: ["l1"])
        let all = try lines(url)
        let posts = all.filter { $0.hasPrefix("notify post id=l1 ") }
        XCTAssertEqual(1, posts.filter { $0.contains(" presented=1 ") }.count,
                       "the snapshot's quiet post presented a second banner")
        XCTAssertEqual(1, center.liveItems.count)
        XCTAssertEqual(0.9, center.liveItems[0].progress ?? -1, accuracy: 0.0001,
                       "the row carries the snapshot's progress")
        XCTAssertTrue(all.contains("notify snapshot ids=1 ended=0"),
                      "the snapshot kept every id: \(all)")
    }

    /// A row and a banner the active set no longer holds leave, and the record
    /// names the ids, not any content.
    @MainActor
    func testASnapshotDropsARowAndABannerItNoLongerHolds() throws {
        let url = temporaryLog()
        defer { try? FileManager.default.removeItem(at: url) }
        let center = center(log: url)
        center.post(PhoneNotification(id: "l1", pkg: "com.uber", when: nil,
                                      title: "Ride", text: "Arriving",
                                      live: live(0.4), alert: true),
                    phoneId: "phone-1", phoneName: "Nicky", phonesPaired: 2, labelFor: { _ in nil })
        center.post(PhoneNotification(id: "p1", pkg: "com.whatsapp", when: nil,
                                      title: "Chat", text: "One", alert: true),
                    phoneId: "phone-1", phoneName: "Nicky", phonesPaired: 2, labelFor: { _ in nil })
        center.snapshot(ids: ["l1"])
        XCTAssertEqual(["l1"], center.liveItems.map(\.id))
        XCTAssertFalse(center.performOpen(id: "p1"), "the banner is forgotten")
        XCTAssertTrue(center.performOpen(id: "l1"), "the kept row's banner stays known")
        let all = try lines(url)
        XCTAssertTrue(all.contains("notify snapshot end id=p1"), "\(all)")
        XCTAssertFalse(all.contains("notify snapshot end id=l1"), "\(all)")
        XCTAssertTrue(all.contains("notify snapshot ids=1 ended=1"), "\(all)")
        XCTAssertFalse(all.joined().contains("Arriving"), "no text reaches the record")
    }

    /// A snapshot that names every held id changes nothing (a rejoin with no
    /// loss must not disturb the list).
    @MainActor
    func testASnapshotNamingEveryIdRemovesNothing() throws {
        let url = temporaryLog()
        defer { try? FileManager.default.removeItem(at: url) }
        let center = center(log: url)
        center.post(PhoneNotification(id: "p1", pkg: "com.whatsapp", when: nil,
                                      title: "Chat", text: "One", alert: true),
                    phoneId: "phone-1", phoneName: "Nicky", phonesPaired: 2, labelFor: { _ in nil })
        center.snapshot(ids: ["p1"])
        XCTAssertTrue(center.performOpen(id: "p1"))
        XCTAssertTrue(try lines(url).contains("notify snapshot ids=1 ended=0"))
    }
}
