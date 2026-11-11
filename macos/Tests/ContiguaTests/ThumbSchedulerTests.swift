// The extension's thumbnail pool (FilesThumbScheduler.swift): one answer per
// id, one completion per Finder batch, and a cancelled batch that still keeps
// the contract (docs/specs/files.md FILES-25/26/29). A fake `start` stands in
// for the bridge connection.

import Foundation
import XCTest
@testable import Contigua

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
        var doneErrors: [Error?] = []

        func open(_ scheduler: FilesThumbScheduler, ids: [String], phone: FakePhone) -> Int {
            scheduler.open(items: ids, start: phone.start,
                           per: { [self] item, data, error in
                               XCTAssertEqual(0, doneCount, "\(item) answered after the batch completed")
                               answers[item, default: []].append((data, error))
                           },
                           done: { [self] error in
                               doneCount += 1
                               doneErrors.append(error)
                           })
        }
    }

    private func errorCode(_ error: Error?) -> Int? {
        (error as NSError?)?.code
    }

    /// The bug the brief names: a cancelled batch used to leave its unstarted
    /// ids unanswered and never call `done`, so Finder could wait for ever.
    /// The header's rule (NSFileProviderThumbnailing.h, "Cancellations"): the
    /// completion handler gets NSUserCancelledError in the cancellation
    /// handler, and no per-thumbnail block may follow it.
    func testACancelledBatchAnswersEveryUnstartedIdOnceAndCompletesAtOnce() {
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
        XCTAssertEqual(1, recorder.doneCount, "the cancel did not complete the batch at once")
        XCTAssertEqual(NSUserCancelledError, errorCode(recorder.doneErrors.first ?? nil),
                       "the batch did not complete with the cancellation error")

        for index in 0..<3 {
            XCTAssertTrue(phone.asks[index].isCancelled())
            phone.finish(index)
        }
        XCTAssertEqual(1, recorder.doneCount, "the batch completed twice")
        XCTAssertEqual(7, recorder.answers.values.reduce(0) { $0 + $1.count },
                       "a late in-flight answer followed the completion")
    }

    /// An in-flight ask of a cancelled batch stops (one fs.cancel from the
    /// connection); its late answer is dropped, and its slot goes back to the
    /// pool, so the next batch is not starved by the cancelled one.
    func testAnInFlightAskOfACancelledBatchFreesItsSlotAndAnswersNothing() {
        let scheduler = FilesThumbScheduler()
        let phone = FakePhone()
        let recorder = Recorder()
        let id = recorder.open(scheduler, ids: ["a1", "a2", "a3"], phone: phone)
        XCTAssertEqual(3, phone.asks.count)
        scheduler.cancel(id)
        XCTAssertEqual(1, recorder.doneCount)
        XCTAssertTrue(phone.asks[0].isCancelled())

        let next = Recorder()
        _ = next.open(scheduler, ids: ["b1", "b2", "b3"], phone: phone)
        XCTAssertEqual(3, phone.asks.count, "the pool started past its limit")
        for index in 0..<3 { phone.finish(index) }
        XCTAssertNil(recorder.answers["a1"], "a late answer followed the completion")
        XCTAssertEqual(["a1", "a2", "a3", "b1", "b2", "b3"], phone.asks.map(\.item),
                       "the cancelled batch's slots never came back")
        XCTAssertEqual(0, next.doneCount)
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

    /// The load test's "asked after its cancel" (K2 on the merge, 2026-11-04):
    /// the pool took an id under its lock and asked the phone after letting go,
    /// so a cancel landing in between still sent that ask. Here the cancel
    /// lands exactly there, every time: after `cancel` returns, the phone hears
    /// nothing more for the batch, and the slot is free for the next one.
    func testACancelBetweenTakingAnIdAndAskingSendsNoAsk() {
        let scheduler = FilesThumbScheduler(limit: 1)
        let phone = FakePhone()
        let recorder = Recorder()
        var cancelled = false
        var batch = 0
        scheduler.willStartForTesting = { [self] id in
            guard id == batch, phone.asks.count == 1, !cancelled else { return }
            cancelled = true
            scheduler.cancel(id)
        }
        batch = recorder.open(scheduler, ids: ["a0", "a1", "a2"], phone: phone)
        XCTAssertEqual(["a0"], phone.asks.map(\.item))

        // a0's answer frees the slot; the pool takes a1, and the cancel lands
        // before a1's ask goes out.
        phone.finish(0, data: Data([1]))
        XCTAssertTrue(cancelled, "the hook never ran between the take and the ask")
        XCTAssertEqual(["a0"], phone.asks.map(\.item), "the phone was asked after the batch's cancel")
        XCTAssertEqual(1, recorder.doneCount)
        XCTAssertEqual(NSUserCancelledError, errorCode(recorder.doneErrors.first ?? nil))

        // The never-sent ask gave its slot back.
        let next = Recorder()
        _ = next.open(scheduler, ids: ["b0"], phone: phone)
        XCTAssertEqual("b0", phone.asks.last?.item, "the cancelled take kept the pool's only slot")
    }
}
