// PATH-53 (#190, #159): every transition of the dial-group machine, and the
// holder against a real event-loop group.

import NIOCore
import NIOPosix
import XCTest
@testable import Contigua

final class DialGroupMachineTests: XCTestCase {
    private func step(_ state: DialGroupState, _ event: DialGroupEvent) -> (DialGroupState, [DialGroupAction]) {
        DialGroupMachine.handle(state, event)
    }

    // MARK: open

    func testPATH53_OpenCountsAStartedDial() {
        XCTAssertEqual(step(.open(dials: 0), .dialStarted).0, .open(dials: 1))
        XCTAssertEqual(step(.open(dials: 2), .dialStarted).0, .open(dials: 3))
        XCTAssertEqual(step(.open(dials: 0), .dialStarted).1, [])
    }

    func testPATH53_OpenCountsAnEndedDialAndNeverGoesBelowZero() {
        XCTAssertEqual(step(.open(dials: 2), .dialEnded).0, .open(dials: 1))
        XCTAssertEqual(step(.open(dials: 1), .dialEnded).0, .open(dials: 0))
        XCTAssertEqual(step(.open(dials: 0), .dialEnded).0, .open(dials: 0))
        XCTAssertEqual(step(.open(dials: 1), .dialEnded).1, [])
    }

    func testPATH53_CloseWithNoDialShutsDownAtOnce() {
        let (state, actions) = step(.open(dials: 0), .close)
        XCTAssertEqual(state, .shutDown)
        XCTAssertEqual(actions, [.shutdown])
    }

    func testPATH53_CloseWithDialsRunningWaitsForThem() {
        let (state, actions) = step(.open(dials: 2), .close)
        XCTAssertEqual(state, .closing(dials: 2))
        XCTAssertEqual(actions, [])
    }

    // MARK: closing

    func testPATH53_ClosingRefusesANewDial() {
        let (state, actions) = step(.closing(dials: 1), .dialStarted)
        XCTAssertEqual(state, .closing(dials: 1))
        XCTAssertEqual(actions, [.refuseDial])
    }

    func testPATH53_ClosingShutsDownWhenTheLastDialEnds() {
        XCTAssertEqual(step(.closing(dials: 2), .dialEnded).0, .closing(dials: 1))
        XCTAssertEqual(step(.closing(dials: 2), .dialEnded).1, [])
        let (state, actions) = step(.closing(dials: 1), .dialEnded)
        XCTAssertEqual(state, .shutDown)
        XCTAssertEqual(actions, [.shutdown])
    }

    func testPATH53_ASecondCloseWhileClosingChangesNothing() {
        let (state, actions) = step(.closing(dials: 1), .close)
        XCTAssertEqual(state, .closing(dials: 1))
        XCTAssertEqual(actions, [])
    }

    // MARK: shutDown

    func testPATH53_ShutDownRefusesADialAndIgnoresTheRest() {
        XCTAssertEqual(step(.shutDown, .dialStarted).0, .shutDown)
        XCTAssertEqual(step(.shutDown, .dialStarted).1, [.refuseDial])
        XCTAssertEqual(step(.shutDown, .dialEnded).0, .shutDown)
        XCTAssertEqual(step(.shutDown, .dialEnded).1, [])
        XCTAssertEqual(step(.shutDown, .close).0, .shutDown)
        XCTAssertEqual(step(.shutDown, .close).1, [])
    }

    // MARK: the holder

    func testPATH53_AnOwnedGroupStaysUpForARunningDialAndShutsDownAfterIt() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let shutDown = expectation(description: "the group shut down after the last dial")
        let holder = DialGroup(group: group, owned: true, onShutdown: { shutDown.fulfill() })
        XCTAssertTrue(holder.dialStarted())
        holder.close()
        XCTAssertEqual(holder.current, .closing(dials: 1))
        XCTAssertFalse(holder.dialStarted(), "a closing group must refuse a new dial")
        // The running dial can still use the loop.
        XCTAssertEqual(try group.next().submit { 7 }.wait(), 7)
        holder.dialEnded()
        XCTAssertEqual(holder.current, .shutDown)
        wait(for: [shutDown], timeout: 3)
    }

    func testPATH53_CloseWithNoDialShutsAnOwnedGroupDownBeforeItReturns() {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let done = SessionLockedBox(value: false)
        let holder = DialGroup(group: group, owned: true, onShutdown: { done.set(true) })
        holder.close()
        XCTAssertEqual(holder.current, .shutDown)
        XCTAssertTrue(done.get(), "close with no dial running must shut down synchronously")
    }

    func testPATH53_AGroupTheSessionDoesNotOwnIsNeverShutDown() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? group.syncShutdownGracefully() }
        let holder = DialGroup(group: group, owned: false)
        holder.close()
        XCTAssertEqual(holder.current, .shutDown)
        XCTAssertEqual(try group.next().submit { 3 }.wait(), 3)
    }
}
