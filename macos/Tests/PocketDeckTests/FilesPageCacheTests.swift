// The extension's one phone-page cache (FILES-30): a 3,000-item folder
// enumerated the way the system does — a fresh enumerator for every Finder
// page, the next page's token handed over — asks the phone for each of its
// three pages once, and a change push makes the next page fetch again.
// The reader is driven here with a synchronous fake phone; the extension's
// observer glue is proved by the VM check.

import FileProvider
import XCTest
@testable import PocketDeck

final class FilesPageCacheTests: XCTestCase {
    /// A phone with `count` items in pages of `pageSize`; every `fs.list` is
    /// counted with its cursor and answers at once (timing is the VM's job).
    final class FakePhone {
        let count: Int
        let pageSize: Int
        private(set) var asks: [String?] = []
        var deferred: ((_ done: @escaping (Result<(items: [FileItem], next: String?), FilesFailure>) -> Void) -> Void)?

        init(count: Int, pageSize: Int) {
            self.count = count
            self.pageSize = pageSize
        }

        func load(container: String, cursor: String?,
                  completion: @escaping (Result<(items: [FileItem], next: String?), FilesFailure>) -> Void) {
            asks.append(cursor)
            if let deferred {
                self.deferred = nil
                deferred(completion)
                return
            }
            let start = cursor.flatMap(Int.init) ?? 0
            let end = min(start + pageSize, count)
            let items = (start..<end).map(Self.item)
            completion(.success((items: items, next: end < count ? String(end) : nil)))
        }

        var pagesAsked: Int { asks.count }

        static func item(_ index: Int) -> FileItem {
            FileItem(identifier: "ino:\(index)", parentIdentifier: "ino:10",
                     name: "img\(index).jpg", isDirectory: false, size: 4,
                     modificationDate: Date(timeIntervalSince1970: 0),
                     contentTypeIdentifier: "public.jpeg", etag: "aa",
                     contentVersion: Data("c\(index)".utf8), metadataVersion: Data("m\(index)".utf8))
        }
    }

    private let container = "ino:10"

    /// The system's walk: one fresh enumerator per Finder page, the previous
    /// page's token handed over until the folder ends.
    @discardableResult
    private func walk(_ phone: FakePhone, cache: FilesPageCache,
                      betweenBatches: (() -> Void)? = nil) -> (delivered: Int, batches: Int) {
        var token: FilesPageToken? = FilesPageToken(cursor: nil)
        var delivered = 0
        var batches = 0
        while let current = token, batches < 100 {
            var next: FilesPageToken?
            FilesPageReader(cache: cache).enumerate(
                container: container, token: current, load: phone.load,
                deliver: { delivery in
                    delivered += delivery.items.count
                    next = delivery.next
                },
                fail: { XCTFail("enumerate failed: \($0.rawValue)") })
            token = next
            batches += 1
            if let betweenBatches { betweenBatches() }
        }
        return (delivered, batches)
    }

    func testAFreshEnumeratorPerFinderPageAsksEachPhonePageOnce() {
        let phone = FakePhone(count: 3000, pageSize: 1000)
        let result = walk(phone, cache: FilesPageCache())
        XCTAssertEqual(3000, result.delivered)
        XCTAssertEqual(12, result.batches, "12 Finder pages of 250")
        XCTAssertEqual([nil, "1000", "2000"], phone.asks,
                       "one fs.list per phone page, not one per Finder page")
    }

    func testAChangeBetweenPagesMakesTheNextPageFetchAgain() throws {
        let cache = FilesPageCache()
        let phone = FakePhone(count: 3000, pageSize: 1000)
        let first = walkOnce(phone, cache: cache, token: FilesPageToken(cursor: nil))
        XCTAssertEqual(1, phone.pagesAsked)
        cache.drop(containers: [container])
        let second = walkOnce(phone, cache: cache, token: try XCTUnwrap(first.next))
        XCTAssertEqual(2, phone.pagesAsked, "the change was not hidden by the cache")
        XCTAssertEqual(500, first.delivered + second.delivered)
    }

    private func walkOnce(_ phone: FakePhone, cache: FilesPageCache,
                          token: FilesPageToken) -> (delivered: Int, next: FilesPageToken?) {
        var delivered = 0
        var next: FilesPageToken?
        FilesPageReader(cache: cache).enumerate(
            container: container, token: token, load: phone.load,
            deliver: { delivery in
                delivered += delivery.items.count
                next = delivery.next
            },
            fail: { XCTFail("enumerate failed: \($0.rawValue)") })
        return (delivered, next)
    }

    func testAPageOlderThanOnePassIsFetchedAgain() {
        var now = Date(timeIntervalSince1970: 1_000)
        let cache = FilesPageCache()
        let phone = FakePhone(count: 3000, pageSize: 1000)
        let token = FilesPageToken(cursor: nil)
        // A later batch of the same phone page: offset 0 of the first page
        // starts a new pass and always fetches (testANewPass…).
        let later = FilesPageToken(cursor: nil, offset: FilesPageReader.batchSize)
        func reader() -> FilesPageReader { FilesPageReader(cache: cache, clock: { now }) }
        reader().enumerate(container: container, token: token, load: phone.load,
                           deliver: { _ in }, fail: { XCTFail("\($0.rawValue)") })
        now += FilesPageCache.lifetime - 1
        reader().enumerate(container: container, token: later, load: phone.load,
                           deliver: { _ in }, fail: { XCTFail("\($0.rawValue)") })
        XCTAssertEqual(1, phone.pagesAsked, "a page inside the pass is reused")
        now += 2
        reader().enumerate(container: container, token: later, load: phone.load,
                           deliver: { _ in }, fail: { XCTFail("\($0.rawValue)") })
        XCTAssertEqual(2, phone.pagesAsked, "a page older than the pass is fetched again")
    }

    func testTheCacheHoldsOnlyAFewPages() {
        let cache = FilesPageCache()
        let phone = FakePhone(count: 10_000, pageSize: 1000)
        walk(phone, cache: cache)
        XCTAssertEqual(10, phone.pagesAsked, "each of the ten phone pages once")
        // Only a few pages stay: walking back to the first asks the phone again.
        walkOnce(phone, cache: cache, token: FilesPageToken(cursor: nil))
        XCTAssertEqual(11, phone.pagesAsked)
    }

    func testAChangeDuringAFetchIsNotStoredAsAPage() {
        let cache = FilesPageCache()
        let phone = FakePhone(count: 3000, pageSize: 1000)
        var release: ((Result<(items: [FileItem], next: String?), FilesFailure>) -> Void)?
        phone.deferred = { done in release = done }
        let token = FilesPageToken(cursor: nil)
        FilesPageReader(cache: cache).enumerate(
            container: container, token: token, load: phone.load,
            deliver: { _ in }, fail: { XCTFail("\($0.rawValue)") })
        cache.drop(containers: [container])
        release?(.success((items: (0..<1000).map(FakePhone.item), next: "1000")))
        // The answer was in flight when the change landed: it must not be
        // remembered as the folder's page.
        walkOnce(phone, cache: cache, token: token)
        XCTAssertEqual(2, phone.pagesAsked)
    }

    func testTheTokenCarriesTheOffsetAndThePhonePage() {
        XCTAssertEqual(FilesPageToken(cursor: nil, offset: 0),
                       FilesPageToken(NSFileProviderPage.initialPageSortedByName as Data))
        XCTAssertEqual(FilesPageToken(cursor: nil, offset: 0),
                       FilesPageToken(NSFileProviderPage.initialPageSortedByDate as Data))
        XCTAssertEqual(FilesPageToken(cursor: "1000", offset: 750),
                       FilesPageToken(Data("b750@1000".utf8)))
        XCTAssertEqual(FilesPageToken(cursor: nil, offset: 0),
                       FilesPageToken(Data("junk".utf8)), "a foreign token starts the folder")
        XCTAssertEqual(Data("b250@".utf8), FilesPageToken(cursor: nil, offset: 250).page)
        XCTAssertEqual(Data("b0@1000".utf8), FilesPageToken(cursor: "1000", offset: 0).page)
    }

    func testThePageLineCarriesCountsAndDurationsOnly() {
        XCTAssertEqual("enumerate page n=250 phone=fetch ms=1234",
                       FilesPageLog.line(count: 250, fetched: true, milliseconds: 1234))
        XCTAssertEqual("enumerate page n=250 phone=hit ms=0",
                       FilesPageLog.line(count: 250, fetched: false, milliseconds: 0))
    }

    func testTheNextTokenMovesInsideThePhonePageThenToTheNextOne() {
        let token = FilesPageToken(cursor: nil, offset: 0)
        XCTAssertEqual(FilesPageToken(cursor: nil, offset: 250),
                       token.next(delivered: 250, of: 1000, nextPhonePage: "1000"))
        XCTAssertEqual(FilesPageToken(cursor: "1000", offset: 0),
                       FilesPageToken(cursor: nil, offset: 750)
                        .next(delivered: 250, of: 1000, nextPhonePage: "1000"))
        XCTAssertNil(FilesPageToken(cursor: "2000", offset: 750)
                        .next(delivered: 250, of: 1000, nextPhonePage: nil))
    }
    /// A new pass starts at the folder's first page and must never replay the
    /// last pass's pages: the app signals the system about a change before the
    /// extension's own push may have arrived, so a cached first page (or a
    /// later page whose items shifted) would hide the change. Each pass still
    /// asks each phone page once.
    func testANewPassFetchesEveryPageAgainEvenWithoutAPush() {
        let phone = FakePhone(count: 3000, pageSize: 1000)
        let cache = FilesPageCache()
        walk(phone, cache: cache)
        XCTAssertEqual([nil, "1000", "2000"], phone.asks)

        walk(phone, cache: cache)
        XCTAssertEqual([nil, "1000", "2000", nil, "1000", "2000"], phone.asks,
                       "the second pass replayed a cached page")
    }

    /// Inside one pass the first phone page's later batches still come from
    /// the cache: only offset 0 of the first page starts a pass.
    func testTheFirstPagesLaterBatchesAreHits() {
        let phone = FakePhone(count: 900, pageSize: 1000)
        let cache = FilesPageCache()
        let result = walk(phone, cache: cache)
        XCTAssertEqual(900, result.delivered)
        XCTAssertEqual(4, result.batches)
        XCTAssertEqual([nil], phone.asks)
    }
}
