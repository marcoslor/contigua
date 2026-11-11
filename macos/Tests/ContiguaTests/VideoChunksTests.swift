import XCTest
@testable import Contigua

/// MEDIA-18/19: VIDEO_CHUNK fragments are reassembled one access unit per
/// stream, and a stub thrown away must break the reference chain — never a
/// silent hole the decoder could fill with a delta (WIN-62's `incomplete`).
final class VideoChunksTests: XCTestCase {
    private func chunk(pts: UInt64, index: UInt16, count: UInt16,
                       flags: UInt8 = 0) -> VideoChunkData {
        VideoChunkData(ptsUs: pts, flags: flags, index: index, count: count,
                       data: [UInt8](repeating: UInt8(truncatingIfNeeded: index), count: 4))
    }

    func testFragmentsReassembleOneUnitPerStream() {
        var chunks = VideoChunkAssembler()
        let a0 = chunks.add(stream: 1, chunk: chunk(pts: 10, index: 0, count: 2))
        let b0 = chunks.add(stream: 2, chunk: chunk(pts: 20, index: 0, count: 2))
        XCTAssertNil(a0.frame)
        XCTAssertNil(b0.frame)
        XCTAssertFalse(a0.discardedIncomplete)
        XCTAssertFalse(b0.discardedIncomplete)

        let a1 = chunks.add(stream: 1, chunk: chunk(pts: 10, index: 1, count: 2))
        XCTAssertEqual(a1.frame?.ptsUs, 10)
        XCTAssertEqual(a1.frame?.annexB, [0, 0, 0, 0, 1, 1, 1, 1])
        // The other stream's unit is untouched by the first one completing.
        let b1 = chunks.add(stream: 2, chunk: chunk(pts: 20, index: 1, count: 2))
        XCTAssertEqual(b1.frame?.ptsUs, 20)
        XCTAssertEqual(b1.frame?.annexB, [0, 0, 0, 0, 1, 1, 1, 1])
    }

    /// R6: the fragment of a different pts discards the stub; the guard then
    /// holds every delta (the rest of the new unit included) until a keyframe.
    func testADifferentPtsDiscardsTheStubAndBreaksTheChain() {
        var chunks = VideoChunkAssembler()
        var chain = ChainGuard()
        _ = chunks.add(stream: 1, chunk: chunk(pts: 10, index: 0, count: 2))
        let interrupted = chunks.add(stream: 1, chunk: chunk(pts: 20, index: 0, count: 2))
        XCTAssertTrue(interrupted.discardedIncomplete)
        XCTAssertNil(interrupted.frame)

        XCTAssertEqual(chain.handle(.breakChain(.incomplete, now: 1)),
                       [.logBroken(.incomplete), .requestKeyframe, .scheduleRetry])
        // The rest of the new access unit completes, but it is a delta: the
        // decoder must not see it while the chain is broken.
        let delta = chunks.add(stream: 1, chunk: chunk(pts: 20, index: 1, count: 2))
        XCTAssertNotNil(delta.frame)
        XCTAssertFalse(delta.frame!.isKeyframe)
        XCTAssertEqual(chain.handle(.sample(isKeyframe: false, now: 1.016)), [.drop])
        XCTAssertEqual(chain.handle(.sample(isKeyframe: false, now: 1.032)), [.drop])

        let key = chunks.add(stream: 1, chunk: chunk(pts: 30, index: 0, count: 1, flags: 1))
        XCTAssertEqual(key.frame?.isKeyframe, true)
        XCTAssertEqual(chain.handle(.sample(isKeyframe: true, now: 1.25)),
                       [.feed, .logRestored(afterMs: 250), .cancelRetry])
        XCTAssertEqual(chain.state, .flowing)
    }

    func testADuplicateFragmentIsABadPayload() {
        var chunks = VideoChunkAssembler()
        _ = chunks.add(stream: 3, chunk: chunk(pts: 5, index: 0, count: 3))
        let duplicate = chunks.add(stream: 3, chunk: chunk(pts: 5, index: 0, count: 3))
        XCTAssertTrue(duplicate.discardedIncomplete)
        XCTAssertNil(duplicate.frame)
    }

    func testForgetReportsOnlyAStubItThrowsAway() {
        var chunks = VideoChunkAssembler()
        _ = chunks.add(stream: 4, chunk: chunk(pts: 7, index: 0, count: 2))
        XCTAssertTrue(chunks.forget(stream: 4), "the stub was incomplete")
        XCTAssertFalse(chunks.forget(stream: 4), "nothing left to throw away")

        _ = chunks.add(stream: 5, chunk: chunk(pts: 8, index: 0, count: 1))
        XCTAssertFalse(chunks.forget(stream: 5), "a whole unit was handed over, not dropped")
    }
}
