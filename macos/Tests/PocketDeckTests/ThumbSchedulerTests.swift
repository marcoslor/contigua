// The extension's thumbnail pool (FilesThumbScheduler.swift): one answer per
// id, one completion per Finder batch, and a cancelled batch that still keeps
// the contract (docs/specs/files.md FILES-25/26/29). A fake `start` stands in
// for the bridge connection.

import Foundation
import XCTest
@testable import PocketDeck

final class ThumbSchedulerTests: XCTestCase {
    private final class FakePhone {
        struct Ask {
            let item: String
            let isCancelled: () -> Bool
            let complete: (Data?, Error?) -> Void
        }

        private(set) var asks: [Ask] = []

        func start(_ item: String, _ isCancelled: @escaping () -> Bool,
                   _ completion: @escaping (Data?, Error?) -> Void) {
            asks.append(Ask(item: item, isCancelled: isCancelled, complete: completion))
        }

        func finish(_ index: Int, data: Data? = nil, error: Error? = nil) {
            asks[index].complete(data, error)
        }
    }

    private final class Recorder {
        var answers: [String: [(data: Data?, error: Error?)]] = [:]
        var doneCount = 0

        func open(_ scheduler: FilesThumbScheduler, ids: [String], phone: FakePhone) -> Int {
            scheduler.open(items: ids, start: phone.start,
                           per: { [self] item, data, error in
                               answers[item, default: []].append((data, error))
                           },
                           done: { [self] _ in doneCount += 1 })
        }
    }

    private func errorCode(_ error: Error?) -> Int? {
        (error as NSError?)?.code
    }

    /// The bug the brief names: a cancelled batch used to leave its unstarted
    /// ids unanswered and never call `done`, so Finder could wait for ever.
    func testACancelledBatchAnswersEveryUnstartedIdOnceAndCompletesOnce() {
        let scheduler = FilesThumbScheduler()
        let phone = FakePhone()
        let recorder = Recorder()
        let ids = (1...10).map { "ino:\($0)" }
        let id = recorder.open(scheduler, ids: ids, phone: phone)
        XCTAssertEqual(3, phone.asks.count)

        scheduler.cancel(id)

        XCTAssertEqual(3, phone.asks.count, "a cancelled batch reached the phone again")
        XCTAssertEqual(7, recorder.answers.count, "the unstarted ids did not answer")
        for item in ids[3...] {
            let answers = recorder.answers[item] ?? []
            XCTAssertEqual(1, answers.count, "\(item) answered more than once")
            XCTAssertNil(answers.first?.data)
            XCTAssertEqual(NSCocoaErrorDomain, (answers.first?.error as NSError?)?.domain)
            XCTAssertEqual(NSUserCancelledError, errorCode(answers.first?.error),
                           "not the File Provider header's cancellation error")
        }
        XCTAssertEqual(0, recorder.doneCount, "done before the in-flight asks answered")

        for index in 0..<3 {
            XCTAssertTrue(phone.asks[index].isCancelled())
            phone.finish(index)
        }
        XCTAssertEqual(1, recorder.doneCount, "the batch did not complete exactly once")
        XCTAssertEqual(10, recorder.answers.values.reduce(0) { $0 + $1.count })
    }

    /// In-flight asks keep today's behaviour: one fs.cancel from the connection
    /// and a nil answer; the scheduler itself never invents an answer twice.
    func testAnInFlightAskStillAnswersOnceAfterTheCancel() {
        let scheduler = FilesThumbScheduler()
        let phone = FakePhone()
        let recorder = Recorder()
        let id = recorder.open(scheduler, ids: ["ino:1"], phone: phone)
        XCTAssertEqual(1, phone.asks.count)
        scheduler.cancel(id)
        XCTAssertTrue(phone.asks[0].isCancelled())
        phone.finish(0)
        XCTAssertEqual(1, recorder.answers["ino:1"]?.count)
        XCTAssertNil(recorder.answers["ino:1"]?.first?.data)
        XCTAssertNil(recorder.answers["ino:1"]?.first?.error)
        XCTAssertEqual(1, recorder.doneCount)
    }

    func testEveryIdAnswersOnceAndTheBatchCompletesOnce() {
        let scheduler = FilesThumbScheduler()
        let phone = FakePhone()
        let recorder = Recorder()
        let ids = (1...5).map { "ino:\($0)" }
        _ = recorder.open(scheduler, ids: ids, phone: phone)
        XCTAssertEqual(3, phone.asks.count)
        for index in 0..<phone.asks.count {
            phone.finish(index, data: Data([UInt8(index)]))
        }
        // The completions start the rest; finish them too.
        while phone.asks.count < ids.count {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        for index in 3..<phone.asks.count {
            phone.finish(index, data: Data([3]))
        }
        for item in ids {
            XCTAssertEqual(1, recorder.answers[item]?.count, item)
        }
        XCTAssertEqual(1, recorder.doneCount)
    }

    func testOnePoolHoldsTheLimitAcrossBatches() {
        let scheduler = FilesThumbScheduler()
        let phone = FakePhone()
        let recorder = Recorder()
        _ = recorder.open(scheduler, ids: (1...4).map { "a\($0)" }, phone: phone)
        _ = recorder.open(scheduler, ids: (1...4).map { "b\($0)" }, phone: phone)
        XCTAssertEqual(3, phone.asks.count, "two batches ran more than three asks")
        phone.finish(0)
        XCTAssertEqual(4, phone.asks.count)
    }

    func testACancelAfterTheBatchFinishedDoesNothing() {
        let scheduler = FilesThumbScheduler()
        let phone = FakePhone()
        let recorder = Recorder()
        let id = recorder.open(scheduler, ids: ["ino:1"], phone: phone)
        phone.finish(0, data: Data([1]))
        XCTAssertEqual(1, recorder.doneCount)
        scheduler.cancel(id)
        XCTAssertEqual(1, recorder.answers["ino:1"]?.count)
        XCTAssertEqual(1, recorder.doneCount)
    }

    func testAnEmptyBatchCompletesOnceWithoutAnAsk() {
        let scheduler = FilesThumbScheduler()
        let phone = FakePhone()
        let recorder = Recorder()
        _ = recorder.open(scheduler, ids: [], phone: phone)
        XCTAssertEqual(0, phone.asks.count)
        XCTAssertEqual(1, recorder.doneCount)
    }

    /// The newest Finder batch is what the person is looking at: when a slot
    /// frees, its unstarted ids go before an older batch's queued ones.
    func testANewerBatchGoesAheadOfAnOlderBatchesUnstartedIds() {
        let scheduler = FilesThumbScheduler()
        let phone = FakePhone()
        let recorder = Recorder()
        _ = recorder.open(scheduler, ids: (1...10).map { "old\($0)" }, phone: phone)
        _ = recorder.open(scheduler, ids: (1...10).map { "new\($0)" }, phone: phone)
        XCTAssertEqual(["old1", "old2", "old3"], phone.asks.map(\.item))

        phone.finish(0)
        XCTAssertEqual("new1", phone.asks.last?.item,
                       "a newer batch's first id waited behind the older batch")
    }
}
