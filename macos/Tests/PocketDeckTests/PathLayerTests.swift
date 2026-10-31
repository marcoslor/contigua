// The Mac's path layer (PATH-4/7/9/12): seq/ack/replay over a fake transport,
// the reorder window, the bare ping, and the switch marker's seq field.

import XCTest
@testable import PocketDeck

final class PathLayerTests: XCTestCase {
    private final class Wire {
        let lock = NSLock()
        var writes: [[UInt8]] = []
        var closed = false
        var writable = true
        var reading: [Bool] = []

        func send(_ bytes: [UInt8]) { lock.lock(); writes.append(bytes); lock.unlock() }
        func setReading(_ on: Bool) { lock.lock(); reading.append(on); lock.unlock() }
        func readings() -> [Bool] { lock.lock(); defer { lock.unlock() }; return reading }
        func close() { lock.lock(); closed = true; lock.unlock() }
        func all() -> [[UInt8]] { lock.lock(); defer { lock.unlock() }; return writes }
        func clear() { lock.lock(); writes.removeAll(); lock.unlock() }
        func setWritable(_ value: Bool) { lock.lock(); writable = value; lock.unlock() }
        func isWritable() -> Bool { lock.lock(); defer { lock.unlock() }; return writable }
    }

    private var clock: Int64 = 2_500
    private var wire = Wire()
    private var layer: PathLayer!

    override func setUp() {
        clock = 2_500
        wire = Wire()
        layer = PathLayer(nowMs: { [unowned self] in self.clock })
        layer.start(first: PathLayer.Path(id: "aaaa0001", kind: .lan, send: wire.send,
                                          close: wire.close, isWritable: wire.isWritable,
                                          setReading: wire.setReading))
    }

    private func json(_ t: String) -> Frame {
        Frame(type: .json, stream: 0, payload: JSONFrame.payload(["t": t]))
    }

    private func decoded(_ index: Int) -> Frame? {
        Frame(encoded: wire.all()[index])
    }

    func testAReliableFrameIsWrappedAndNumberedFromOne() throws {
        layer.send(json("ping"))
        let wrapped = try XCTUnwrap(decoded(0))
        XCTAssertEqual(PathCodec.reliableType, wrapped.type)
        let reliable = try PathCodec.decodeReliable(wrapped)
        XCTAssertEqual(1, reliable.seq)
        XCTAssertEqual("ping", JSONFrame.decode(payload: reliable.inner.payload)?.t)
    }

    func testLossyFramesGoBareAndNeverEnterTheReplayBuffer() throws {
        layer.send(Frame(type: .hover, stream: 3, payload: [1, 2, 3]))
        XCTAssertEqual(0, layer.heldBytes)
        let bare = try XCTUnwrap(decoded(0))
        XCTAssertEqual(MessageType.hover.rawValue, bare.type)
        XCTAssertEqual([1, 2, 3], bare.payload)
    }

    func testAnAckReleasesTheReplayBuffer() {
        layer.send(json("a"))
        layer.send(json("b"))
        XCTAssertGreaterThan(layer.heldBytes, 0)
        _ = layer.receive(path: "aaaa0001", frame: PathCodec.encodeAck(3))
        XCTAssertEqual(0, layer.heldBytes)
    }

    func testADuplicateIsDroppedAndAckedAtOnce() {
        let wrapped = (try? PathCodec.encodeReliable(seq: 1, inner: json("x")).encoded) ?? []
        let frame = Frame(encoded: wrapped)!
        let one = layer.receive(path: "aaaa0001", frame: frame)
        XCTAssertEqual(one.count, 1)
        wire.clear()
        let two = layer.receive(path: "aaaa0001", frame: frame)
        XCTAssertTrue(two.isEmpty)
        // The duplicate is answered with an ACK straight away.
        XCTAssertTrue(wire.all().contains { Frame(encoded: $0)?.type == PathCodec.ackType })
    }

    func testAnOutOfOrderFrameWaitsForTheGap() throws {
        let second = Frame(encoded: try PathCodec.encodeReliable(seq: 2, inner: json("second")).encoded)!
        let first = Frame(encoded: try PathCodec.encodeReliable(seq: 1, inner: json("first")).encoded)!
        XCTAssertTrue(layer.receive(path: "aaaa0001", frame: second).isEmpty)
        let delivered = layer.receive(path: "aaaa0001", frame: first)
        XCTAssertEqual(delivered.count, 2)
        if case .deliver(let one) = delivered[0] { XCTAssertEqual("first", JSONFrame.decode(payload: one.payload)?.t) }
        if case .deliver(let two) = delivered[1] { XCTAssertEqual("second", JSONFrame.decode(payload: two.payload)?.t) }
    }

    func testAPongMeasuresTheRoundTripOnOurOwnClock() throws {
        layer.attach(PathLayer.Path(id: "bbbb0002", kind: .lan, send: { _ in }, close: {}), joined: true)
        layer.pingAll(active: true)
        let ping = try XCTUnwrap(decoded(0))
        let message = try XCTUnwrap(JSONFrame.decode(payload: ping.payload))
        XCTAssertEqual("path.ping", message.t)
        let ts = try XCTUnwrap(message.int("ts"))
        clock += 25
        let pong = Frame(type: .json, stream: 0, payload: JSONFrame.payload([
            "t": "path.pong", "path": "aaaa0001", "ts": ts,
        ]))
        var rtt: Double?
        for event in layer.receive(path: "aaaa0001", frame: pong) {
            if case .pong(_, let measured) = event { rtt = measured }
        }
        XCTAssertEqual(25.0, rtt ?? -1)
    }

    func testNoPongInOneAndAHalfSecondsIsALostPing() {
        layer.attach(PathLayer.Path(id: "bbbb0002", kind: .lan, send: { _ in }, close: {}), joined: true)
        layer.pingAll(active: true)
        clock += 1_499
        XCTAssertTrue(layer.lostPings().isEmpty)
        clock += 2
        XCTAssertEqual(["aaaa0001", "bbbb0002"], layer.lostPings().sorted())
    }

    func testTheSwitchMarkerNamesTheFrameAfterItself() throws {
        layer.send(json("before"))
        XCTAssertTrue(layer.sendMarker(on: "aaaa0001", to: "aaaa0001"))
        let marker = try XCTUnwrap(decoded(1))
        let reliable = try PathCodec.decodeReliable(marker)
        XCTAssertEqual(2, reliable.seq)
        let body = try XCTUnwrap(JSONFrame.decode(payload: reliable.inner.payload))
        XCTAssertEqual("path.switch", body.t)
        XCTAssertEqual(3, body.int("seq"))
        XCTAssertEqual("aaaa0001", body.string("path"))
    }

    func testAWrappedSwitchMarkerIsThePeersSwitchNotADelivery() throws {
        layer.attach(PathLayer.Path(id: "bbbb0002", kind: .lan,
                                    send: { _ in }, close: {}), joined: true)
        let marker = Frame(type: .json, stream: 0, payload: JSONFrame.payload([
            "t": "path.switch", "path": "bbbb0002", "seq": 4,
        ]))
        let frame = Frame(encoded: try PathCodec.encodeReliable(seq: 1, inner: marker).encoded)!
        let events = layer.receive(path: "aaaa0001", frame: frame)
        XCTAssertEqual(1, events.count)
        if case .peerSwitch(let path, let seq, let arrivedOn) = events[0] {
            XCTAssertEqual("bbbb0002", path)
            XCTAssertEqual(4, seq)
            XCTAssertEqual("aaaa0001", arrivedOn)
        } else {
            XCTFail("expected peerSwitch, got \(events)")
        }
    }

    /// E-6/RR-6: a `path.switch` marker is a small control frame and never
    /// waits for credit. At a full replay buffer the old code put it in the
    /// pending list with its `seq` field frozen at the seq it would have had,
    /// so when it was finally admitted its field named a frame that was not
    /// next. The marker is admitted at once and its field is the seq of the
    /// frame after it.
    func testAMarkerAtFullCreditBypassesCreditAndCarriesTheRightSeq() throws {
        let control = { (size: Int) in
            Frame(type: .touch, stream: 1, payload: [UInt8](repeating: 1, count: size))
        }
        for _ in 0..<16 { layer.send(control((1 << 20) - 100)) }
        layer.send(control(ReplayBuffer.capacity - layer.heldBytes - PathCodec.wrapperBytes - 4))
        XCTAssertEqual(ReplayBuffer.capacity, layer.heldBytes, "the replay buffer is full")
        let lastSeq = try XCTUnwrap(wire.all().last.flatMap { Frame(encoded: $0) })
            .flatMap { try? PathCodec.decodeReliable($0) }?.seq
        XCTAssertTrue(layer.sendMarker(on: "aaaa0001", to: "aaaa0001"),
                      "the marker waited for credit")
        let marker = try XCTUnwrap(wire.all().last.flatMap { Frame(encoded: $0) })
        let reliable = try PathCodec.decodeReliable(marker)
        XCTAssertEqual((lastSeq ?? 0) + 1, reliable.seq, "the marker is the next seq")
        let body = try XCTUnwrap(JSONFrame.decode(payload: reliable.inner.payload))
        XCTAssertEqual("path.switch", body.t)
        XCTAssertEqual(Int((lastSeq ?? 0) + 2), body.int("seq"),
                       "the field names the frame after the marker")
    }

    /// R-6/E-4, the reviewer's scratch case: a key typed while 13 bulk chunks
    /// wait outside the seq space goes out at once, behind only the bulk the
    /// path already has room for. Only bulk queues behind bulk.
    func testAKeyGoesOutAtOnceWhilePendingBulkWaitsForCredit() throws {
        let size = (1 << 20) - 100
        let bulk = { (byte: UInt8) in
            Frame(type: .dropData, stream: 1,
                  payload: [UInt8](repeating: byte, count: size))
        }
        for byte in UInt8(1)...UInt8(13) { layer.send(bulk(byte)) }
        // E-4: one chunk is in flight (the unacked window is the 256 KiB
        // watermark, so the next one waits for its ack) and the other twelve
        // have no seq yet.
        XCTAssertEqual(1, wire.all().count, "bulk enters the seq space only while the path has room")
        layer.send(json("key"))
        let sent = try wire.all().map { try XCTUnwrap(Frame(encoded: $0)) }
        XCTAssertEqual(2, sent.count, "the KEY must go out while bulk waits for credit")
        let last = try PathCodec.decodeReliable(sent[1])
        XCTAssertEqual("key", JSONFrame.decode(payload: last.inner.payload)?.t)
        XCTAssertEqual(2, last.seq, "the KEY is the second seq: the writer never jumped a gap")
        // Each ack frees the window for one more chunk, in order.
        for ack in UInt64(3)...UInt64(15) {
            _ = layer.receive(path: "aaaa0001", frame: PathCodec.encodeAck(ack))
        }
        let all = try wire.all().map { try XCTUnwrap(Frame(encoded: $0)) }
        XCTAssertEqual(Array(1...UInt64(14)), try all.map { try PathCodec.decodeReliable($0).seq })
        let payloads = try all.map { bytes -> Int in
            let frame = try PathCodec.decodeReliable(bytes)
            guard frame.inner.type == MessageType.dropData.rawValue else { return 17 }
            return Int(frame.inner.payload.first ?? 0)
        }
        XCTAssertEqual([1, 17, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13], payloads,
                       "the waiting chunks keep their order after the key")
    }

    /// Bulk still queues behind bulk, in order, and waits for credit.
    func testBulkBehindPendingBulkKeepsItsOrderAndWaitsForTheAck() throws {
        let size = (8 << 20) - 1_000
        let bulk = { (byte: UInt8) in
            Frame(type: .dropData, stream: 1,
                  payload: [UInt8](repeating: byte, count: size))
        }
        layer.send(bulk(1))
        layer.send(bulk(2))         // does not fit the 12 MiB bulk budget
        layer.send(bulk(3))         // still queued behind the second
        XCTAssertEqual(1, wire.all().count, "only the first frame was admitted")
        _ = layer.receive(path: "aaaa0001", frame: PathCodec.encodeAck(2))
        XCTAssertEqual(2, wire.all().count, "one more bulk frame fits")
        _ = layer.receive(path: "aaaa0001", frame: PathCodec.encodeAck(3))
        let sent = try wire.all().map { try XCTUnwrap(Frame(encoded: $0)) }
        XCTAssertEqual(3, sent.count)
        let payloads = try sent.map { try PathCodec.decodeReliable($0).inner.payload.first ?? 0 }
        XCTAssertEqual([1, 2, 3], payloads)
    }

    func testAnAckAboveWhatWasSentIsAProtocolError() {
        let events = layer.receive(path: "aaaa0001", frame: PathCodec.encodeAck(99))
        XCTAssertEqual(1, events.count)
        if case .ackAboveSent = events[0] {} else { XCTFail("expected ackAboveSent") }
    }

    func testAChannelsFailureReportsThePathDown() {
        let events = layer.receive(path: "aaaa0001", frame: Frame(type: 0x30, stream: 0, payload: [0]))
        XCTAssertEqual(1, events.count)
        if case .down(let path) = events[0] { XCTAssertEqual("aaaa0001", path) } else { XCTFail("expected down") }
    }
}

// MARK: - D-2: bulk flow control, priority, liveness, demote

extension PathLayerTests {
    private func bulkFrame(_ byte: UInt8, size: Int = 256 << 10) -> Frame {
        Frame(type: .dropData, stream: 1, payload: [UInt8](repeating: byte, count: size))
    }

    /// E-4: bulk is admitted to the seq space only while the path's outbox is
    /// under its 256 KiB low watermark. A key typed while bulk waits goes out
    /// behind at most the watermark, not behind megabytes of an admitted file
    /// (the old FIFO put the whole 12 MiB credit ahead of it).
    func testBulkWaitsOutsideTheSeqSpaceWhileTheOutboxIsOverTheWatermark() throws {
        wire.setWritable(false)
        for byte in UInt8(1)...UInt8(4) {
            layer.send(bulkFrame(byte, size: 300 << 10))
        }
        // Only one chunk took a seq: the unacked window is the same 256 KiB.
        XCTAssertEqual(307_222, layer.heldBytes, "one chunk is in flight, three wait outside the seq space")
        layer.send(json("key"))
        wire.setWritable(true)
        layer.writable("aaaa0001")
        let sent = try wire.all().map { try XCTUnwrap(Frame(encoded: $0)) }
        let frames = try sent.map { try PathCodec.decodeReliable($0) }
        XCTAssertEqual([UInt64(1), 2], frames.map(\.seq),
                       "the key is the second seq, behind one chunk and no more")
        XCTAssertEqual("key", JSONFrame.decode(payload: frames[1].inner.payload)?.t)
        // Each ack frees the window for one more chunk, and they keep the
        // order they were handed over in.
        for ack in UInt64(3)...UInt64(5) {
            _ = layer.receive(path: "aaaa0001", frame: PathCodec.encodeAck(ack))
        }
        let all = try wire.all().map { try XCTUnwrap(Frame(encoded: $0)) }
        XCTAssertEqual(Array(1...UInt64(5)), try all.map { try PathCodec.decodeReliable($0).seq })
        XCTAssertEqual([1, 17, 2, 3, 4], try all.map { bytes -> Int in
            let frame = try PathCodec.decodeReliable(bytes)
            guard frame.inner.type == MessageType.dropData.rawValue else { return 17 }
            return Int(frame.inner.payload.first ?? 0)
        }, "the three waiting chunks keep their order after the key")
    }

    /// Bulk is held by the layer while the channel is not writable and goes out
    /// only when NIO says it can take more (the 256 KiB water mark).
    func testBulkWaitsForTheChannelToBecomeWritable() throws {
        wire.setWritable(false)
        layer.send(bulkFrame(1))
        XCTAssertTrue(wire.all().isEmpty, "bulk entered a channel that is over its water mark")
        layer.writable("aaaa0001")
        XCTAssertTrue(wire.all().isEmpty, "still not writable: no write")
        wire.setWritable(true)
        layer.writable("aaaa0001")
        let sent = try wire.all().map { try XCTUnwrap(Frame(encoded: $0)) }
        XCTAssertEqual(1, sent.count)
        XCTAssertEqual(MessageType.dropData.rawValue, try PathCodec.decodeReliable(sent[0]).inner.type)
    }

    /// A ping and an ACK jump the bulk that is waiting for writability: they
    /// are bare frames, never queued in the layer (D-2 priority).
    func testPingAndAckJumpTheBulkHeldOnANonWritablePath() throws {
        let second = Wire()
        layer.attach(PathLayer.Path(id: "bbbb0002", kind: .lan, send: second.send,
                                    close: second.close, isWritable: second.isWritable), joined: true)
        wire.setWritable(false)
        layer.send(bulkFrame(1))
        XCTAssertTrue(wire.all().isEmpty, "bulk held back")
        layer.pingAll(active: true)
        let frames = try wire.all().map { try XCTUnwrap(Frame(encoded: $0)) }
        XCTAssertEqual(1, frames.count, "the ping is not behind the bulk")
        XCTAssertEqual(MessageType.json.rawValue, frames[0].type)
        XCTAssertEqual("path.ping", JSONFrame.decode(payload: frames[0].payload)?.t)
        second.clear()
        // An inbound reliable frame is answered with a bare ACK at once, ahead
        // of the held bulk.
        let inbound = Frame(encoded: try PathCodec.encodeReliable(seq: 1, inner: json("x")).encoded)!
        _ = layer.receive(path: "bbbb0002", frame: inbound)
        let acks = try second.all().map { try XCTUnwrap(Frame(encoded: $0)) }
        XCTAssertEqual(1, acks.count)
        XCTAssertEqual(PathCodec.ackType, acks[0].type)
    }

    /// A path that keeps delivering frames is alive even when its pong is late:
    /// a pong can queue behind our own bulk on a slow link (D-2).
    func testAPathThatKeepsReceivingIsAliveThoughItsPongIsLate() {
        let second = Wire()
        layer.attach(PathLayer.Path(id: "bbbb0002", kind: .lan, send: second.send,
                                    close: second.close, isWritable: second.isWritable), joined: true)
        wire.clear()
        layer.pingAll(active: true)
        XCTAssertEqual(1, wire.all().count, "the ping under test went out")
        clock += 1_000
        let inbound = Frame(type: .json, stream: 0, payload: JSONFrame.payload(["t": "noop"]))
        _ = layer.receive(path: "aaaa0001", frame: inbound)
        clock += 600                                    // 1.6 s after the ping
        XCTAssertFalse(layer.lostPings().contains("aaaa0001"),
                       "a receiving path was reported lost")
        clock += 1_000                                  // 1.6 s after the last inbound
        XCTAssertEqual(["aaaa0001"], layer.lostPings())
    }

    /// An unplanned switch clears the old path's held bulk and replays the
    /// frames once on the new path; the old path is a standby, not closed.
    func testHeldBulkMovesToTheNewPathOnAnUnplannedSwitch() throws {
        let second = Wire()
        layer.attach(PathLayer.Path(id: "bbbb0002", kind: .lan, send: second.send,
                                    close: second.close, isWritable: second.isWritable), joined: true)
        second.clear()      // the join's own ping
        wire.setWritable(false)
        layer.send(bulkFrame(1))
        XCTAssertTrue(wire.all().isEmpty)
        layer.moveTo("bbbb0002", plannedFrom: nil)
        layer.replayOnCurrent()
        XCTAssertTrue(wire.all().isEmpty, "the old path writes nothing more")
        let writes = second.all()
        XCTAssertEqual(1, writes.count, "the held bulk is replayed once on the new path")
        let frame = try XCTUnwrap(Frame(encoded: writes[0]))
        XCTAssertEqual(MessageType.dropData.rawValue, try PathCodec.decodeReliable(frame).inner.type)
        XCTAssertFalse(second.closed)
    }
}

extension PathLayerTests {
    /// E-3: a planned switch leaves the old path attached and draining; the
    /// Mac itself closes it after the 2 s drain backstop (the phone never
    /// closes a path on a switch).
    func testAPlannedSwitchDrainsTheOldPathAndTheMacClosesIt() {
        let second = Wire()
        layer.attach(PathLayer.Path(id: "bbbb0002", kind: .lan, send: second.send,
                                    close: second.close, isWritable: second.isWritable),
                     joined: true)
        XCTAssertTrue(layer.sendMarker(on: "aaaa0001", to: "bbbb0002"))
        layer.moveTo("bbbb0002", plannedFrom: "aaaa0001")
        XCTAssertTrue(layer.hasPath("aaaa0001"), "the old path is kept while it drains")
        XCTAssertFalse(wire.closed)
        clock += 1_999
        XCTAssertTrue(layer.closeDrained().isEmpty, "no drain before the 2 s backstop")
        XCTAssertTrue(layer.hasPath("aaaa0001"))
        clock += 1
        XCTAssertEqual(["aaaa0001"], layer.closeDrained(), "the drain backstop passed")
        XCTAssertTrue(layer.detach("aaaa0001"), "the Mac closes the old path itself")
        XCTAssertTrue(wire.closed)
        XCTAssertEqual(["bbbb0002"], layer.pathIds)
    }

    /// E-3/D-2: a demoted path is a standby, not a drain: it stays attached
    /// and open for as long as the session lives, so it can win back on margin.
    func testADemotedStandbySurvivesTheSwitchAndIsNeverDrained() {
        let second = Wire()
        layer.attach(PathLayer.Path(id: "bbbb0002", kind: .lan, send: second.send,
                                    close: second.close, isWritable: second.isWritable),
                     joined: true)
        layer.moveTo("bbbb0002", plannedFrom: nil)
        XCTAssertEqual("bbbb0002", layer.currentPath)
        XCTAssertTrue(layer.hasPath("aaaa0001"), "the demoted path was closed on the switch")
        clock += 30_000
        XCTAssertTrue(layer.closeDrained().isEmpty, "a standby must never be drained")
        XCTAssertFalse(wire.closed, "the standby's socket was closed")
        XCTAssertEqual(["aaaa0001", "bbbb0002"], layer.pathIds)
    }
}

extension PathLayerTests {
    /// E-1: a lossy frame is written without credit, so a path that cannot
    /// take more must not queue an unbounded pile of them. At most 128 KiB
    /// waits in the channel; past it the frame is dropped (lossy by design)
    /// and writing resumes when the channel drains.
    func testLossyFramesAreCappedWhileTheChannelIsNotWritable() {
        wire.setWritable(false)
        let hover = Frame(type: .hover, stream: 1, payload: [UInt8](repeating: 0, count: 8 << 10))
        for _ in 0..<20 { layer.send(hover) }
        XCTAssertEqual(16, wire.all().count, "more than 128 KiB of lossy frames queued on a stalled path")
        wire.setWritable(true)
        layer.writable("aaaa0001")
        for _ in 0..<4 { layer.send(hover) }
        XCTAssertEqual(20, wire.all().count, "the cap was not reset when the channel drained")
    }

    /// RR-14: one pump per path, so two senders' frames reach the channel in
    /// seq order. The first write parks inside the channel; a second sender
    /// must not take the next frame and write it ahead of the parked one.
    func testTwoSendersOnOnePathKeepTheWiresSeqOrder() throws {
        let entered = DispatchSemaphore(value: 0)
        let gate = DispatchSemaphore(value: 0)
        let done = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var writes: [UInt64] = []
        var first = true
        let parked = PathLayer.Path(id: "cccc0003", kind: .lan, send: { bytes in
            lock.lock(); let isFirst = first; first = false; lock.unlock()
            if isFirst {
                entered.signal()
                _ = gate.wait(timeout: .now() + 5)
            }
            if let frame = Frame(encoded: bytes),
               let reliable = try? PathCodec.decodeReliable(frame) {
                lock.lock(); writes.append(reliable.seq); lock.unlock()
            }
        }, close: {})
        layer.attach(parked, joined: false)
        layer.moveTo("cccc0003", plannedFrom: nil)
        let parkedSend = expectation(description: "the parked writer")
        DispatchQueue.global().async {
            self.layer.send(self.json("one"))
            parkedSend.fulfill()
            done.signal()
        }
        XCTAssertEqual(.success, entered.wait(timeout: .now() + 2), "the first write never parked")
        layer.send(json("two"))
        gate.signal()
        wait(for: [parkedSend], timeout: 5)
        _ = done.wait(timeout: .now() + 1)
        lock.lock()
        let seqs = writes
        lock.unlock()
        XCTAssertEqual(Array(1...UInt64(seqs.count)), seqs, "writes reached the channel out of seq order")
        XCTAssertEqual([1, 2], Array(seqs.suffix(2)), "the parked frame went first")
    }
}

// MARK: - D-1: the ping policy

extension PathLayerTests {
    /// One path, screen on and sending: still no path.ping (D-1).
    func testAOnePathSessionIsNeverPinged() {
        for _ in 0..<20 {
            clock += 1_000
            layer.pingAll(active: true)
        }
        XCTAssertTrue(wire.all().isEmpty, "a one-path session sent a path.ping")
        XCTAssertTrue(layer.lostPings().isEmpty)
    }

    /// Two paths: every 2 s while the screen is on or a transfer runs, every
    /// 15 s otherwise.
    func testTwoPathsPingEveryTwoSecondsWhenActiveAndFifteenWhenIdle() throws {
        let second = Wire()
        layer.attach(PathLayer.Path(id: "bbbb0002", kind: .lan, send: second.send,
                                    close: second.close, isWritable: second.isWritable), joined: true)
        second.clear()      // the join's own immediate ping
        clock += 2_000
        layer.pingAll(active: true)
        let pings = try wire.all().map { try XCTUnwrap(Frame(encoded: $0)) }
            .filter { JSONFrame.decode(payload: $0.payload)?.t == "path.ping" }
        XCTAssertEqual(1, pings.count)
        let standbyPings = second.all().compactMap { Frame(encoded: $0) }
            .filter { JSONFrame.decode(payload: $0.payload)?.t == "path.ping" }
        XCTAssertEqual(1, standbyPings.count, "both paths are pinged, the standby included")
        wire.clear(); second.clear()
        clock += 1_900
        layer.pingAll(active: true)
        XCTAssertTrue(wire.all().isEmpty, "no ping before the 2 s interval")
        clock += 100
        layer.pingAll(active: true)
        XCTAssertFalse(wire.all().isEmpty, "the 2 s interval passed")
        // Screen off, no transfer: 15 s.
        wire.clear(); second.clear()
        clock += 1_000
        layer.pingAll(active: false)
        XCTAssertTrue(wire.all().isEmpty)
        clock += 13_900                             // 14.9 s since the last ping
        layer.pingAll(active: false)
        XCTAssertTrue(wire.all().isEmpty, "the idle interval is 15 s, not 2 s")
        clock += 100
        layer.pingAll(active: false)
        XCTAssertFalse(wire.all().isEmpty, "the 15 s idle interval passed")
    }

    /// A transfer keeps the fast interval even with the screen off.
    func testARunningTransferKeepsTheFastInterval() {
        let second = Wire()
        layer.attach(PathLayer.Path(id: "bbbb0002", kind: .lan, send: second.send,
                                    close: second.close, isWritable: second.isWritable), joined: true)
        clock += 2_000
        layer.pingAll(active: false)
        wire.clear(); second.clear()
        layer.send(bulkFrame(1))
        clock += 1_500
        layer.pingAll(active: false)
        XCTAssertFalse(wire.all().isEmpty, "a transfer runs: the fast interval applies")
    }

    /// RR-14/D-2: a pong lost on a path that is still receiving is a ranking
    /// sample, not a silent drop (the phone records one too).
    func testALatePongOnAnAlivePathIsOneRankingSample() {
        let second = Wire()
        layer.attach(PathLayer.Path(id: "bbbb0002", kind: .lan, send: second.send,
                                    close: second.close, isWritable: second.isWritable), joined: true)
        clock += 2_000
        layer.pingAll(active: true)
        clock += 1_400
        let inbound = Frame(type: .json, stream: 0, payload: JSONFrame.payload(["t": "noop"]))
        _ = layer.receive(path: "aaaa0001", frame: inbound)
        clock += 200      // 1.6 s after the ping; the path received 0.2 s ago
        XCTAssertEqual(["aaaa0001"], layer.latePongs())
        XCTAssertFalse(layer.lostPings().contains("aaaa0001"),
                       "an alive path was reported failed")
        XCTAssertTrue(layer.latePongs().isEmpty, "one lost ping is one sample")
    }

    /// A joined path is pinged at once, before any tick (PATH-12/D-1).
    func testAJoinedPathIsPingedAtOnce() throws {
        let second = Wire()
        layer.attach(PathLayer.Path(id: "bbbb0002", kind: .lan, send: second.send,
                                    close: second.close, isWritable: second.isWritable), joined: true)
        let writes = try second.all().map { try XCTUnwrap(Frame(encoded: $0)) }
        XCTAssertEqual(1, writes.count)
        XCTAssertEqual("path.ping", JSONFrame.decode(payload: writes[0].payload)?.t)
        XCTAssertEqual("bbbb0002", JSONFrame.decode(payload: writes[0].payload)?.string("path"))
    }
}

// MARK: - R-11, R-15, R-16

extension PathLayerTests {
    /// R-11/RR-7, the reviewer's scratch case: seqs 2…66 arrive before 1 on
    /// the same path. The gap is on that path's own stream, so its reader must
    /// keep reading (a paused reader could never read the missing seq 1); the
    /// frames wait in the overflow, bounded by one window, and deliver when 1
    /// arrives.
    func testAFullWindowOnTheSamePathsOwnStreamKeepsItsReaderReading() throws {
        let inner = { (n: Int) in
            Frame(type: MessageType.json.rawValue, stream: 0, payload: JSONFrame.payload(["t": "x", "i": n]))
        }
        for seq in UInt64(2)...UInt64(66) {
            let frame = Frame(encoded: try PathCodec.encodeReliable(seq: seq, inner: inner(Int(seq))).encoded)!
            XCTAssertTrue(layer.receive(path: "aaaa0001", frame: frame).isEmpty, "seq \(seq) waits for 1")
        }
        XCTAssertEqual([], wire.readings(), "the path holding its own gap must keep reading")
        XCTAssertEqual(1, layer.ackValue, "nothing past the gap was acknowledged")
        let first = Frame(encoded: try PathCodec.encodeReliable(seq: 1, inner: inner(1)).encoded)!
        let delivered = layer.receive(path: "aaaa0001", frame: first)
        XCTAssertEqual(66, delivered.count, "every held seq delivered after the gap filled")
        XCTAssertEqual(67, layer.ackValue)
        XCTAssertEqual([], wire.readings(), "the reader was never stopped")
    }

    /// RR-7/PATH-10: the reader stops only when the gap is on another path. A
    /// path's frames ahead of the gap that path A holds wait in that path's
    /// overflow, and the reader resumes when the gap fills.
    func testAFullWindowAheadOfAnotherPathsGapStopsOnlyThatReader() throws {
        let second = Wire()
        layer.attach(PathLayer.Path(id: "bbbb0002", kind: .lan, send: second.send,
                                    close: second.close, isWritable: second.isWritable,
                                    setReading: second.setReading), joined: true)
        second.clear()
        let inner = { (n: Int) in
            Frame(type: MessageType.json.rawValue, stream: 0, payload: JSONFrame.payload(["t": "x", "i": n]))
        }
        let frame = { (seq: UInt64) in
            Frame(encoded: try! PathCodec.encodeReliable(seq: seq, inner: inner(Int(seq))).encoded)!
        }
        XCTAssertEqual(1, layer.receive(path: "aaaa0001", frame: frame(1)).count)
        for seq in UInt64(3)...UInt64(66) {
            XCTAssertTrue(layer.receive(path: "bbbb0002", frame: frame(seq)).isEmpty, "seq \(seq) waits for 2")
        }
        XCTAssertEqual([], wire.readings(), "the path holding the gap keeps reading")
        XCTAssertTrue(layer.receive(path: "bbbb0002", frame: frame(67)).isEmpty,
                      "the 65th buffered frame does not fit")
        XCTAssertEqual([false], second.readings(), "the path ahead of another path's gap stopped reading")
        XCTAssertEqual(2, layer.ackValue)
        // The gap's own path fills it: everything delivers and the paused
        // reader resumes.
        let delivered = layer.receive(path: "aaaa0001", frame: frame(2))
        XCTAssertEqual(66, delivered.count)
        let readings = second.readings()
        XCTAssertEqual([false, true], readings, "the reader resumed after the gap filled")
        XCTAssertEqual(68, layer.ackValue)
    }

    /// R-15: a burst inside 10 ms is acknowledged by the timer, not by the next
    /// frame.
    func testTheCoalescedAckFlushesAfterTenMilliseconds() throws {
        let inner = { (n: Int) in
            Frame(type: MessageType.json.rawValue, stream: 0, payload: JSONFrame.payload(["t": "x", "i": n]))
        }
        let first = Frame(encoded: try PathCodec.encodeReliable(seq: 1, inner: inner(1)).encoded)!
        _ = layer.receive(path: "aaaa0001", frame: first)
        let lateFirstAck = wire.all().last.flatMap { Frame(encoded: $0) }?.type == PathCodec.ackType
        XCTAssertTrue(lateFirstAck, "the first frame acks at once")
        wire.clear()
        for seq in UInt64(2)...UInt64(4) {
            let frame = Frame(encoded: try PathCodec.encodeReliable(seq: seq, inner: inner(Int(seq))).encoded)!
            _ = layer.receive(path: "aaaa0001", frame: frame)
        }
        XCTAssertFalse(wire.all().last.flatMap { Frame(encoded: $0) }?.type == PathCodec.ackType,
                       "a burst inside 10 ms is not acked by arrival alone")
        let expectation = expectation(description: "the 10 ms flush")
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(30)) { expectation.fulfill() }
        wait(for: [expectation], timeout: 1)
        let last = try XCTUnwrap(wire.all().last.flatMap { Frame(encoded: $0) })
        XCTAssertEqual(PathCodec.ackType, last.type)
        XCTAssertEqual(5, try PathCodec.decodeAck(last))
    }

    /// R-16: a reliable frame whose outer stream disagrees with its inner one is
    /// a session protocol error, not one path going down.
    func testAMismatchedOuterStreamIsAProtocolError() throws {
        let inner = Frame(type: .touch, stream: 9, payload: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0])
        let wrapped = try PathCodec.encodeReliable(seq: 1, inner: inner)
        // The wrapper says stream 9 inside; the outer frame claims 7.
        let mismatched = Frame(type: PathCodec.reliableType, stream: 7, payload: wrapped.payload)
        let events = layer.receive(path: "aaaa0001", frame: mismatched)
        XCTAssertEqual(1, events.count)
        if case .protocolError = events[0] {} else { XCTFail("expected protocolError, got \(events)") }
    }
}

extension PathLayerTests {
    /// PATH-12: a pong naming a path this side never opened is ignored.
    func testAPongForAnUnknownPathIsIgnored() {
        let pong = Frame(type: .json, stream: 0, payload: JSONFrame.payload([
            "t": "path.pong", "path": "deadbeef", "ts": 1,
        ]))
        XCTAssertTrue(layer.receive(path: "aaaa0001", frame: pong).isEmpty)
    }
}
