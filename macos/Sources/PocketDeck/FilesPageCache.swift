// The extension's phone pages (FILES-30): the token the system hands back for
// the next Finder batch, the one page cache every enumerator shares, and the
// reader the extension drives.
//
// The VM run of 2026-11-03 read 3,000 names in 16.3 s: the system asked for 12
// Finder batches of 250, each with a fresh enumerator and the next page's
// token, and every 1,000-item phone page was fetched four times because the
// cache lived on the enumerator. The cache therefore belongs to the extension
// process, not to an enumerator.

import FileProvider
import Foundation

/// `b<offset>@<phone page>`: how far into the phone's page this Finder batch
/// starts, and which phone page it is. The initial tokens are the folder's
/// first page; anything that is not ours starts there too, because only the
/// extension writes a page token.
struct FilesPageToken: Equatable {
    var cursor: String?
    var offset: Int

    init(cursor: String?, offset: Int = 0) {
        self.cursor = cursor
        self.offset = offset
    }

    init(_ page: Data) {
        let initialByName = NSFileProviderPage.initialPageSortedByName as Data
        let initialByDate = NSFileProviderPage.initialPageSortedByDate as Data
        guard page != initialByName, page != initialByDate,
              let text = String(data: page, encoding: .utf8),
              text.hasPrefix("b"),
              let at = text.firstIndex(of: "@") else {
            self.init(cursor: nil)
            return
        }
        let offset = Int(text[text.index(after: text.startIndex)..<at]) ?? 0
        let rest = String(text[text.index(after: at)...])
        self.init(cursor: rest.isEmpty ? nil : rest, offset: offset)
    }

    var page: Data { Data(encode().utf8) }

    private func encode() -> String { "b\(offset)@\(cursor ?? "")" }

    /// The next Finder batch inside this phone page, else the phone's next
    /// page, else nil at the folder's end.
    func next(delivered: Int, of count: Int, nextPhonePage: String?) -> FilesPageToken? {
        if offset + delivered < count {
            return FilesPageToken(cursor: cursor, offset: offset + delivered)
        }
        if let nextPhonePage { return FilesPageToken(cursor: nextPhonePage) }
        return nil
    }
}

/// One folder's phone page as the phone answered it. `storedAt` is the reader's
/// clock, so the lifetime is testable without sleeping.
struct FilesPage: Equatable {
    var items: [FileItem]
    var next: String?
    var storedAt: Date
}

/// The one phone-page cache of an extension process, keyed by container and the
/// phone's cursor.
///
/// **Lifetime: one enumeration pass, at most 30 s.** The system walks a folder's
/// pages back to back — the VM's 12-page pass over 3,000 names took 16.3 s,
/// with 1.2-1.5 s of the system's own time between pages — so 30 s covers a
/// pass with margin. It is also short enough that a page the system re-reads
/// after a pause is at most 30 s old. A change push drops that container's
/// pages at once (`drop(container:)`), so a change is never hidden; the
/// generation counter makes a fetch that was already in flight at the push
/// store nothing.
final class FilesPageCache {
    static let lifetime: TimeInterval = 30
    /// Four phone pages: one 3,000-item pass needs three, and a deeper walk
    /// re-reads only what the system asks for again.
    static let capacity = 4

    private struct Key: Hashable {
        var container: String
        /// `""` stands for the first page (the token's nil cursor).
        var cursor: String
    }

    private let lock = NSLock()
    private var pages: [Key: FilesPage] = [:]
    /// Least recently used first.
    private var order: [Key] = []
    private var generations: [String: Int] = [:]

    /// The cached page, or nil when it is absent or older than one pass.
    func page(container: String, cursor: String?, now: Date) -> FilesPage? {
        let key = Key(container: container, cursor: cursor ?? "")
        lock.lock()
        defer { lock.unlock() }
        guard let page = pages[key] else { return nil }
        let age = now.timeIntervalSince(page.storedAt)
        guard age >= 0, age < Self.lifetime else {
            removeLocked(key)
            return nil
        }
        touchLocked(key)
        return page
    }

    /// The container's change generation. A reader takes it before its fetch
    /// and hands it back to `store`, so an answer that crosses a change push is
    /// not remembered as the folder's page.
    func generation(_ container: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return generations[container] ?? 0
    }

    /// Remembers one phone page, unless that container changed since
    /// `generation` was taken.
    func store(_ page: FilesPage, container: String, cursor: String?, generation: Int) {
        let key = Key(container: container, cursor: cursor ?? "")
        lock.lock()
        defer { lock.unlock() }
        guard (generations[container] ?? 0) == generation else { return }
        pages[key] = page
        touchLocked(key)
        while order.count > Self.capacity, let oldest = order.first {
            removeLocked(oldest)
        }
    }

    /// A change push for these containers (S5): forget every page of theirs at
    /// once and invalidate fetches already in flight.
    func drop(containers: [String]) {
        lock.lock()
        defer { lock.unlock() }
        let dropped = Set(containers)
        guard !dropped.isEmpty else { return }
        for container in dropped {
            generations[container, default: 0] += 1
        }
        for key in order where dropped.contains(key.container) {
            pages[key] = nil
        }
        order.removeAll { dropped.contains($0.container) }
    }

    private func touchLocked(_ key: Key) {
        order.removeAll { $0 == key }
        order.append(key)
    }

    private func removeLocked(_ key: Key) {
        pages[key] = nil
        order.removeAll { $0 == key }
    }
}

/// The one line the extension writes per Finder page (FILES-27, FILES-30):
/// count, cache hit or fetch, and the time from the enumeration request to the
/// delivery. The app's own relay timing plus this line give the listing's
/// breakdown: phone time, our time, and the system's gap to the next page.
enum FilesPageLog {
    static func line(count: Int, fetched: Bool, milliseconds: Int) -> String {
        "enumerate page n=\(count) phone=\(fetched ? "fetch" : "hit") ms=\(milliseconds)"
    }
}

/// One folder's Finder batch. The system builds a fresh enumerator for every
/// batch and hands the previous batch's token over; every reader of one
/// extension process shares its `FilesPageCache`, so a phone page costs one
/// `fs.list` per enumeration pass instead of one per Finder batch.
final class FilesPageReader {
    struct Delivery {
        var items: [FileItem]
        var next: FilesPageToken?
        /// True when the phone answered this batch (a cache miss); false when
        /// the page came from the cache.
        var fetched: Bool
        /// The time from the enumeration request to this delivery.
        var milliseconds: Int
    }

    typealias LoadCompletion = (Result<(items: [FileItem], next: String?), FilesFailure>) -> Void

    /// A phone page is delivered to Finder in batches of this size (design
    /// "S5 round 3": 1,000 items in one callback listed as empty in the VM).
    static let batchSize = 250

    private let cache: FilesPageCache
    private let clock: () -> Date

    init(cache: FilesPageCache, clock: @escaping () -> Date = Date.init) {
        self.cache = cache
        self.clock = clock
    }

    func enumerate(container: String, token: FilesPageToken,
                   load: @escaping (_ container: String, _ cursor: String?,
                                    _ completion: @escaping LoadCompletion) -> Void,
                   deliver: @escaping (Delivery) -> Void,
                   fail: @escaping (FilesFailure) -> Void) {
        let started = clock()
        if let page = cache.page(container: container, cursor: token.cursor, now: started) {
            deliverNow(page.items, page.next, token: token, fetched: false,
                       started: started, deliver: deliver)
            return
        }
        let generation = cache.generation(container)
        load(container, token.cursor) { result in
            switch result {
            case .success(let listing):
                self.cache.store(FilesPage(items: listing.items, next: listing.next,
                                           storedAt: self.clock()),
                                 container: container, cursor: token.cursor,
                                 generation: generation)
                self.deliverNow(listing.items, listing.next, token: token, fetched: true,
                               started: started, deliver: deliver)
            case .failure(let failure):
                fail(failure)
            }
        }
    }

    private func deliverNow(_ items: [FileItem], _ nextPhonePage: String?,
                            token: FilesPageToken, fetched: Bool, started: Date,
                            deliver: (Delivery) -> Void) {
        let slice = Array(items.dropFirst(max(0, token.offset)).prefix(Self.batchSize))
        let elapsed = Int(clock().timeIntervalSince(started) * 1000)
        deliver(Delivery(items: slice,
                         next: token.next(delivered: slice.count, of: items.count,
                                          nextPhonePage: nextPhonePage),
                         fetched: fetched,
                         milliseconds: max(0, elapsed)))
    }
}
