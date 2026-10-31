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

        func send(_ bytes: [UInt8]) { lock.lock(); writes.append(bytes); lock.unlock() }
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
                                          close: wire.close, isWritable: wire.isWritable))
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
        layer.pingAll()
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
        layer.pingAll()
        clock += 1_499
        XCTAssertTrue(layer.lostPings().isEmpty)
        clock += 2
        XCTAssertEqual(["aaaa0001"], layer.lostPings())
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

    /// R-6, the reviewer's scratch case: a key typed while 13 bulk chunks wait
    /// for credit goes out at once. Only bulk queues behind bulk.
    func testAKeyGoesOutAtOnceWhilePendingBulkWaitsForCredit() throws {
        let size = (1 << 20) - 100
        let bulk = { (byte: UInt8) in
            Frame(type: .dropData, stream: 1,
                  payload: [UInt8](repeating: byte, count: size))
        }
        for byte in UInt8(1)...UInt8(13) { layer.send(bulk(byte)) }
        // Twelve admittable chunks hold 12,581,928 B of the 12 MiB bulk budget;
        // the 13th waits for an ack.
        XCTAssertEqual(12, wire.all().count, "twelve bulk chunks fit the credit")
        layer.send(json("key"))
        let sent = try wire.all().map { try XCTUnwrap(Frame(encoded: $0)) }
        XCTAssertEqual(13, sent.count, "the KEY must go out while bulk waits for credit")
        let last = try PathCodec.decodeReliable(sent[12])
        XCTAssertEqual("key", JSONFrame.decode(payload: last.inner.payload)?.t)
        XCTAssertEqual(13, last.seq)
        // The seqs on the wire are 1...13: control did not jump a gap, it was
        // admitted after the twelve.
        XCTAssertEqual(Array(1...UInt64(13)), try sent.map { try PathCodec.decodeReliable($0).seq })
        // The waiting chunk keeps its order once an ack frees room.
        _ = layer.receive(path: "aaaa0001", frame: PathCodec.encodeAck(13))
        let all = try wire.all().map { try XCTUnwrap(Frame(encoded: $0)) }
        XCTAssertEqual(14, all.count, "the waiting chunk fits after the ack")
        XCTAssertEqual(Array(1...UInt64(14)), try all.map { try PathCodec.decodeReliable($0).seq })
        let payloads = try all.dropFirst(11).map { try PathCodec.decodeReliable($0).inner.payload.first ?? 0 }
        XCTAssertEqual([12, 0x7b, 13], payloads)
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
        layer.pingAll()
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
        layer.pingAll()
        clock += 1_000
        let inbound = Frame(type: .json, stream: 0, payload: JSONFrame.payload(["t": "noop"]))
        _ = layer.receive(path: "aaaa0001", frame: inbound)
        clock += 600                                    // 1.6 s after the ping
        XCTAssertTrue(layer.lostPings().isEmpty, "a receiving path was reported lost")
        clock += 1_000                                  // 1.6 s after the last inbound
        XCTAssertEqual(["aaaa0001"], layer.lostPings())
    }

    /// An unplanned switch clears the old path's held bulk and replays the
    /// frames once on the new path; the old path is a standby, not closed.
    func testHeldBulkMovesToTheNewPathOnAnUnplannedSwitch() throws {
        let second = Wire()
        layer.attach(PathLayer.Path(id: "bbbb0002", kind: .lan, send: second.send,
                                    close: second.close, isWritable: second.isWritable), joined: true)
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
