// The Mac's path layer (PATH-4/7/9/12): seq/ack/replay over a fake transport,
// the reorder window, the bare ping, and the switch marker's seq field.

import XCTest
@testable import PocketDeck

final class PathLayerTests: XCTestCase {
    private final class Wire {
        let lock = NSLock()
        var writes: [[UInt8]] = []
        var closed = false

        func send(_ bytes: [UInt8]) { lock.lock(); writes.append(bytes); lock.unlock() }
        func close() { lock.lock(); closed = true; lock.unlock() }
        func all() -> [[UInt8]] { lock.lock(); defer { lock.unlock() }; return writes }
        func clear() { lock.lock(); writes.removeAll(); lock.unlock() }
    }

    private var clock: Int64 = 2_500
    private var wire = Wire()
    private var layer: PathLayer!

    override func setUp() {
        clock = 2_500
        wire = Wire()
        layer = PathLayer(nowMs: { [unowned self] in self.clock })
        layer.start(first: PathLayer.Path(id: "aaaa0001", kind: .lan, send: wire.send, close: wire.close))
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
