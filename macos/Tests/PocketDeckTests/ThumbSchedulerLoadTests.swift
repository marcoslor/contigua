// The scroll NFR (docs/specs/files.md FILES-25/30): a folder of thousands of
// icons, Finder opening 50-id batches as the person scrolls and cancelling the
// previous one every 2 s, against a phone that takes 300 ms per thumbnail.
// Proves the newest batch goes first, a cancelled batch is never asked again,
// every batch completes once, and the pending set stays one live batch plus the
// three-ask pool.

import Foundation
import XCTest
@testable import PocketDeck

final class ThumbSchedulerLoadTests: XCTestCase {
    private final class Locked<Value> {
        private let lock = NSLock()
        private var value: Value

        init(_ value: Value) { self.value = value }

        func with<T>(_ body: (inout Value) -> T) -> T {
            lock.lock()
            defer { lock.unlock() }
            return body(&value)
        }
    }

    /// A phone whose one turn is 300 ms; the answer's bytes are irrelevant.
    private final class DelayedPhone {
        struct Ask {
            let batch: Int
            let at: TimeInterval
        }

        private let delay: TimeInterval
        private let lock = NSLock()
        private var asks: [Ask] = []
        private var firstAsk: [Int: TimeInterval] = [:]

        init(delay: TimeInterval) { self.delay = delay }

        func start(batch: Int) -> FilesThumbScheduler.Start {
            { [self] _, _, completion in
                let at = Date().timeIntervalSince1970
                lock.lock()
                asks.append(Ask(batch: batch, at: at))
                if firstAsk[batch] == nil { firstAsk[batch] = at }
                lock.unlock()
                DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + delay) {
                    completion(Data([UInt8(batch % 251)]), nil)
                }
            }
        }

        func snapshot() -> (asks: [Ask], firstAsk: [Int: TimeInterval]) {
            lock.lock()
            defer { lock.unlock() }
            return (asks, firstAsk)
        }
    }

    func testTheScrollLoad() {
        let scheduler = FilesThumbScheduler()
        let phone = DelayedPhone(delay: 0.3)
        let batches = 60
        let size = 50
        let interval = 2.0
        let batchIDs = Locked<[Int]>([])
        let opened = Locked<[Int: TimeInterval]>([:])
        let cancelled = Locked<[Int: TimeInterval]>([:])
        let doneCounts = Locked<[Int: Int]>([:])
        let doneCodes = Locked<[Int: Int]>([:])
        let answers = Locked<[String: Int]>([:])
        let pendingMax = Locked<Int>(0)
        let start = Date().timeIntervalSince1970

        for index in 0..<batches {
            let due = start + Double(index) * interval
            let now = Date().timeIntervalSince1970
            if due > now { Thread.sleep(forTimeInterval: due - now) }  // real-time: the NFR's phone turn and scroll interval are the measurement
            if index > 0 {
                let previous = index - 1
                // The contract is "nothing new once cancel returns": an ask the
                // pool was already starting may finish starting during the call.
                scheduler.cancel(batchIDs.with { $0[previous] })
                cancelled.with { $0[previous] = Date().timeIntervalSince1970 }
            }
            let items = (0..<size).map { "b\(index)-\($0)" }
            opened.with { $0[index] = Date().timeIntervalSince1970 }
            let id = scheduler.open(
                items: items,
                start: phone.start(batch: index),
                per: { item, _, _ in answers.with { $0[item, default: 0] += 1 } },
                done: { error in
                    doneCounts.with { $0[index, default: 0] += 1 }
                    doneCodes.with { $0[index] = (error as NSError?)?.code ?? 0 }
                })
            batchIDs.with { $0.append(id) }
            pendingMax.with { $0 = max($0, scheduler.pendingCount) }
        }

        // The last batch is not cancelled: it drains through the pool.
        let deadline = Date().addingTimeInterval(60)
        while doneCounts.with({ $0.count }) < batches && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)  // real-time: the last batch drains at the fake phone's 300 ms pace
        }

        let snapshot = phone.snapshot()
        let openTimes = opened.with { $0 }
        let cancelTimes = cancelled.with { $0 }
        var latencies: [Double] = []
        for index in 0..<batches {
            guard let first = snapshot.firstAsk[index], let at = openTimes[index] else {
                XCTFail("batch \(index) never asked for anything")
                continue
            }
            latencies.append(first - at)
        }
        latencies.sort()
        let p50 = latencies.isEmpty ? 0 : latencies[latencies.count / 2]
        let p95 = latencies.isEmpty ? 0 : latencies[min(latencies.count - 1, (latencies.count * 95) / 100)]
        let maxLatency = latencies.last ?? 0
        print(String(format: "scroll load: batches=%d ids=%d p50=%.3fs p95=%.3fs max=%.3fs pendingMax=%d",
                     batches, batches * size, p50, p95, maxLatency, pendingMax.with { $0 }))

        XCTAssertLessThanOrEqual(maxLatency, 0.5,
                                 "a new batch's first id waited past one 300 ms turn plus scheduling")
        for ask in snapshot.asks {
            guard let cancelledAt = cancelTimes[ask.batch] else { continue }
            XCTAssertLessThanOrEqual(ask.at, cancelledAt + 0.001,
                                     "batch \(ask.batch) asked after its cancel")
        }
        for index in 0..<batches {
            XCTAssertEqual(1, doneCounts.with { $0[index] ?? 0 }, "batch \(index)'s done count")
        }
        // A cancelled batch completes at once with NSUserCancelledError, which
        // covers the asks it still had in flight (the header's rule), so only
        // those may go without a per-thumbnail answer: at most the pool's 3
        // per cancelled batch. The last batch is never cancelled and answers
        // every id.
        for index in 0..<(batches - 1) {
            XCTAssertEqual(NSUserCancelledError, doneCodes.with { $0[index] },
                           "cancelled batch \(index) did not complete with the cancellation error")
        }
        XCTAssertEqual(0, doneCodes.with { $0[batches - 1] }, "the last batch did not complete cleanly")
        let answeredCount = answers.with { $0.count }
        XCTAssertGreaterThanOrEqual(answeredCount, batches * size - (batches - 1) * 3,
                                    "more ids went unanswered than the cancelled batches had in flight")
        let lastAnswered = answers.with { all in all.keys.filter { $0.hasPrefix("b\(batches - 1)-") }.count }
        XCTAssertEqual(size, lastAnswered, "the live batch did not answer every id")
        let wrong = answers.with { $0.filter { $0.value != 1 } }
        XCTAssertEqual(0, wrong.count, "ids answered more than once: \(wrong.keys.prefix(3))")
        XCTAssertLessThanOrEqual(pendingMax.with { $0 }, 3 + size,
                                 "the pending set grew past one live batch plus the pool")
    }
}
