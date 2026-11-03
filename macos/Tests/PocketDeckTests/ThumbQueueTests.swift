// The thumbnail queue (FilesThumbQueue.swift): the pure transition table, the
// 3-in-flight cap, the FIFO, cancel and the 8 s deadline measured from the ask
// (docs/specs/files.md FILES-25/29). A stub host stands in for the session.

import Foundation
import XCTest
@testable import PocketDeck

private let thumbBytes = FilesThumb(data: [1, 2, 3], mime: "image/jpeg", sha256: "ab")

@MainActor
private final class StubThumbHost: FilesThumbHost {
    struct Call {
        let item: String
        let size: Int
        let onStart: (UInt32) -> Void
        let completion: (Result<FilesThumb, FsError>) -> Void
    }

    var calls: [Call] = []
    var cancels: [UInt32] = []
    private var nextID: UInt32 = 1

    func thumb(item: String, size: Int,
               onStart: @escaping (UInt32) -> Void,
               completion: @escaping (Result<FilesThumb, FsError>) -> Void) {
        let id = nextID
        nextID += 1
        onStart(id)
        calls.append(Call(item: item, size: size, onStart: onStart, completion: completion))
    }

    func cancel(id: UInt32) { cancels.append(id) }

    func finish(_ index: Int, _ result: Result<FilesThumb, FsError>) {
        calls[index].completion(result)
    }
}

@MainActor
final class ThumbQueueTests: XCTestCase {
    private var queue: FilesThumbQueue!
    private var host: StubThumbHost!
    private var answers: [UInt32: [ThumbAnswer]] = [:]

    override func setUp() {
        queue = FilesThumbQueue()
        host = StubThumbHost()
        answers = [:]
    }

    private func ask(_ id: UInt32, item: String = "ino:1", size: Int = 512,
                     deadline: TimeInterval = 8, client: ObjectIdentifier? = nil) {
        queue.request(id: id, client: client ?? ObjectIdentifier(host), item: item, size: size,
                      deadline: deadline, host: host) { [weak self] answer in
            self?.answers[id, default: []].append(answer)
        }
    }

    private func wait(_ timeout: TimeInterval = 2, _ test: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if test() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        return test()
    }

    /// The whole table: all 6 phases x 6 events, including the ignored ones.
    func testEveryTransition() {
        let thumb = FilesThumb(data: [1], mime: "image/jpeg", sha256: "ab")
        typealias Step = (ThumbPhase, [ThumbAction])
        let request: [ThumbPhase: [ThumbEvent: Step]] = [
            .queued: [
                .slotFree: (.running, [.sendRequest]),
                .end(thumb): (.queued, []),
                .failure(code: "x"): (.queued, []),
                .cancel: (.cancelled, [.answer(.failure(code: "cancelled"))]),
                .deadline: (.expired, [.answer(.failure(code: "timeout"))]),
                .drop: (.cancelled, [.answer(.failure(code: "offline"))]),
            ],
            .running: [
                .slotFree: (.running, []),
                .end(thumb): (.done, [.answer(.success(thumb))]),
                .failure(code: "x"): (.done, [.answer(.failure(code: "x"))]),
                .cancel: (.cancelled, [.sendCancel, .answer(.failure(code: "cancelled"))]),
                .deadline: (.expired, [.sendCancel, .answer(.failure(code: "timeout"))]),
                .drop: (.cancelled, [.answer(.failure(code: "offline"))]),
            ],
        ]
        let terminal: [ThumbPhase] = [.done, .cancelled, .expired]
        let events: [ThumbEvent] = [.slotFree, .end(thumb), .failure(code: "x"),
                                    .cancel, .deadline, .drop]
        for phase in terminal {
            for event in events {
                let (next, actions) = FilesThumbQueue.transition(phase, event)
                XCTAssertEqual(next, phase, "\(phase) + \(event)")
                XCTAssertEqual(actions, [], "\(phase) + \(event)")
            }
        }
        for (phase, byEvent) in request where !terminal.contains(phase) {
            for event in events {
                let expected = byEvent[event] ?? (phase, [])
                let (next, actions) = FilesThumbQueue.transition(phase, event)
                XCTAssertEqual(next, expected.0, "\(phase) + \(event)")
                XCTAssertEqual(actions, expected.1, "\(phase) + \(event)")
            }
        }
    }

    func testThreeRunAndTheFourthWaits() {
        for id in 1...3 { ask(UInt32(id)) }
        XCTAssertEqual(3, host.calls.count)
        ask(4)
        XCTAssertEqual(3, host.calls.count, "the fourth started before a slot was free")
        guard host.calls.count == 3 else { return }
        host.finish(0, .success(thumbBytes))
        XCTAssertEqual(4, host.calls.count)
        XCTAssertEqual(1, answers[1]?.count)
        XCTAssertEqual([.success(thumbBytes)], answers[1])
    }

    func testTheFourthRunsInArrivalOrder() {
        for id in 1...3 { ask(UInt32(id), item: "ino:\(id)") }
        ask(4, item: "ino:4")
        guard host.calls.count == 3 else { return }
        host.finish(1, .success(thumbBytes))
        XCTAssertEqual("ino:4", host.calls.last?.item)
    }

    func testACancelLeavesTheQueue() {
        for id in 1...3 { ask(UInt32(id)) }
        ask(4)
        XCTAssertTrue(queue.cancel(id: 4))
        XCTAssertEqual(.failure(code: "cancelled"), answers[4]?.first)
        XCTAssertEqual(3, host.calls.count, "a cancelled queued ask reached the phone")
    }

    func testACancelOfARunningOneSendsFsCancel() {
        ask(1)
        XCTAssertTrue(queue.cancel(id: 1))
        XCTAssertEqual([1], host.cancels)
        XCTAssertEqual(.failure(code: "cancelled"), answers[1]?.first)
    }

    func testTheDeadlineAnswersTimeoutAndCancels() {
        ask(1, deadline: 0.05)
        XCTAssertTrue(wait { self.answers[1] != nil })
        XCTAssertEqual([.failure(code: "timeout")], answers[1])
        XCTAssertEqual([1], host.cancels)
    }

    func testAQueuedOneExpiresWithoutAPhoneRequest() {
        for id in 1...3 { ask(UInt32(id)) }
        ask(4, deadline: 0.05)
        XCTAssertTrue(wait { self.answers[4] != nil })
        XCTAssertEqual([.failure(code: "timeout")], answers[4])
        XCTAssertEqual(3, host.calls.count, "an expired queued ask reached the phone")
    }

    func testADropAnswersOfflineWithoutAPhoneCancel() {
        ask(1)
        queue.reset()
        XCTAssertEqual([.failure(code: "offline")], answers[1])
        XCTAssertEqual([], host.cancels)
    }

    func testAClientGoingAwayDropsItsOwnOnly() {
        let one = ObjectIdentifier(host)
        let other = ObjectIdentifier(queue)
        ask(1, client: one)
        ask(2, client: other)
        queue.cancel(client: one)
        XCTAssertEqual(.failure(code: "cancelled"), answers[1]?.first)
        XCTAssertNil(answers[2])
    }

    func testOneAnswerPerRequest() {
        ask(1)
        guard host.calls.count == 1 else { return }
        host.finish(0, .success(thumbBytes))
        queue.cancel(id: 1)
        queue.cancel(id: 1)
        XCTAssertEqual(1, answers[1]?.count)
        XCTAssertEqual([], host.cancels, "a finished request was cancelled on the phone")
    }
}
