// Which folders the Mac keeps watched on the phone (docs/design/files.md "S5
// round 3"). A replicated extension is not told what Finder is showing and its
// enumerators are short-lived, so "watch while an enumerator exists" watched
// nothing exactly when a phone-side change arrived. A folder is kept from the
// moment the system touches it until `ttl` after the last touch, at most
// `capacity` folders, the least recently touched dropped first.
//
// A pure value with an injected clock: the app schedules the timers, the tests
// move time by hand.

import Foundation

struct FilesWatchSet: Equatable {
    /// The most folders one Mac keeps watched on the phone (design, round 3).
    static let capacity = 64
    /// Ten minutes after the last touch (design, round 3). The host check
    /// shortens it through the environment so a TTL expiry is observable in
    /// seconds; nothing else may change it.
    static let ttl: TimeInterval = {
        if let text = ProcessInfo.processInfo.environment["PD_FILES_WATCH_TTL"],
           let seconds = Double(text), seconds > 0 {
            return seconds
        }
        return 600
    }()

    enum Touch: Equatable {
        /// The folder was not watched: it is now, and the least recently
        /// touched folder (if any) had to go to make room.
        case added(evicted: String?)
        /// Already watched; its ten minutes start again.
        case refreshed
    }

    private(set) var lastTouch: [String: TimeInterval] = [:]
    let capacity: Int
    let ttl: TimeInterval

    init(capacity: Int = FilesWatchSet.capacity, ttl: TimeInterval = FilesWatchSet.ttl) {
        self.capacity = capacity
        self.ttl = ttl
    }

    var count: Int { lastTouch.count }

    /// The folders currently watched, by identifier.
    var watched: [String] { lastTouch.keys.sorted() }

    func isWatched(_ item: String) -> Bool { lastTouch[item] != nil }

    func lastTouch(of item: String) -> TimeInterval? { lastTouch[item] }

    /// A touch keeps the folder for `ttl` from now. When the set is full the
    /// least recently touched folder leaves, unless that folder is [item]
    /// itself (which cannot be, as it is new).
    mutating func touch(_ item: String, now: TimeInterval) -> Touch {
        if lastTouch[item] != nil {
            lastTouch[item] = now
            return .refreshed
        }
        var evicted: String?
        if lastTouch.count >= capacity,
           let oldest = lastTouch.min(by: { $0.value < $1.value })?.key {
            lastTouch.removeValue(forKey: oldest)
            evicted = oldest
        }
        lastTouch[item] = now
        return .added(evicted: evicted)
    }

    /// Folders whose ten minutes are over, oldest first. The caller unwatches
    /// them on the phone.
    @discardableResult
    mutating func expire(now: TimeInterval) -> [String] {
        let gone = lastTouch
            .filter { now - $0.value >= ttl }
            .sorted { $0.value < $1.value }
            .map(\.key)
        for item in gone { lastTouch.removeValue(forKey: item) }
        return gone
    }

    /// How long until [item] expires; nil when it is not watched.
    func remaining(_ item: String, now: TimeInterval) -> TimeInterval? {
        guard let touched = lastTouch[item] else { return nil }
        return max(0, touched + ttl - now)
    }

    mutating func remove(_ item: String) {
        lastTouch.removeValue(forKey: item)
    }

    mutating func removeAll() {
        lastTouch.removeAll()
    }
}
