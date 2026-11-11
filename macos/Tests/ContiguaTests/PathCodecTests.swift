// The paths wire (docs/design/paths.md §5.3, docs/PROTOCOL.md § "Paths"):
// the two golden byte strings, the 8 MiB − 18 inner payload bound, the outer
// stream mirror and the type table.

import XCTest
@testable import Contigua

final class PathCodecTests: XCTestCase {
    private func bytes(_ hex: String) -> [UInt8] {
        hex.split(whereSeparator: { $0 == " " || $0 == "\n" }).compactMap { UInt8($0, radix: 16) }
    }

    func testAckGoldenBytes() throws {
        let expected: [UInt8] = [
            0x00, 0x00, 0x00, 0x0d,
            0x31,
            0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x2a,
        ]
        let frame = PathCodec.encodeAck(42)
        XCTAssertEqual(frame.encoded, expected)
        XCTAssertEqual(try PathCodec.decodeAck(frame), 42)
    }

    func testReliableGoldenBytes() {
        let json = Array(#"{"t":"clip.set","text":"hi"}"#.utf8)
        let expected: [UInt8] =
            bytes("00 00 00 2e 30 00 00 00 00")
            + bytes("00 00 00 00 00 00 00 07")
            + bytes("01 00 00 00 00")
            + json
        let inner = Frame(type: .json, stream: 0, payload: json)
        let frame = try! PathCodec.encodeReliable(seq: 7, inner: inner)
        XCTAssertEqual(frame.encoded, expected)
        let decoded = try! PathCodec.decodeReliable(frame)
        XCTAssertEqual(decoded.seq, 7)
        XCTAssertEqual(decoded.inner, inner)
    }

    func testLargestInnerPayloadRoundTrips() {
        let payload = [UInt8](repeating: 0x5a, count: PathCodec.maxInnerPayload)
        let inner = Frame(type: .json, stream: 9, payload: payload)
        let frame = try! PathCodec.encodeReliable(seq: 1, inner: inner)
        XCTAssertEqual(frame.encoded.count, 4 + Int(maxFrameSize))
        let decoded = try! PathCodec.decodeReliable(frame)
        XCTAssertEqual(decoded.inner.payload.count, PathCodec.maxInnerPayload)
        XCTAssertEqual(decoded.inner, inner)
    }

    func testOneBytePastTheLargestInnerPayloadIsRefused() {
        let inner = Frame(type: .json, stream: 0,
                          payload: [UInt8](repeating: 0, count: PathCodec.maxInnerPayload + 1))
        XCTAssertThrowsError(try PathCodec.encodeReliable(seq: 1, inner: inner)) { error in
            XCTAssertEqual(error as? PathCodecError, .frameTooLarge(PathCodec.maxInnerPayload + 1))
        }
    }

    func testOuterStreamMustMirrorTheInnerStream() {
        let inner = Frame(type: .touch, stream: 4, payload: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0])
        var frame = try! PathCodec.encodeReliable(seq: 3, inner: inner)
        frame.stream = 5
        XCTAssertThrowsError(try PathCodec.decodeReliable(frame)) { error in
            XCTAssertEqual(error as? PathCodecError, .streamMismatch(outer: 5, inner: 4))
        }
    }

    func testOnlyTheReliableTypesMayBeWrapped() {
        for type: UInt8 in [0x01, 0x10, 0x11, 0x12, 0x20, 0x21, 0x22, 0x23, 0x24] {
            XCTAssertTrue(PathCodec.isReliable(type), "0x\(String(type, radix: 16))")
            _ = try! PathCodec.encodeReliable(seq: 1, inner: Frame(type: type, stream: 0, payload: []))
        }
        for type: UInt8 in [0x02, 0x03, 0x04, 0x05, 0x13, 0x30, 0x31] {
            XCTAssertFalse(PathCodec.isReliable(type), "0x\(String(type, radix: 16))")
            XCTAssertThrowsError(try PathCodec.encodeReliable(seq: 1, inner: Frame(type: type, stream: 0, payload: [])))
        }
    }

    func testUnknownInnerTypeStillDecodesSoTheReceiverCanAckAndDrop() {
        let frame = Frame(type: 0x30, stream: 0, payload: [0, 0, 0, 0, 0, 0, 0, 1, 0x7f, 0, 0, 0, 0])
        let decoded = try! PathCodec.decodeReliable(frame)
        XCTAssertEqual(decoded.inner.type, 0x7f)
        XCTAssertFalse(PathCodec.isReliable(decoded.inner.type))
    }

    func testBulkTypes() {
        for type: UInt8 in [0x20, 0x21, 0x22, 0x23, 0x24] { XCTAssertTrue(PathCodec.isBulk(type)) }
        for type: UInt8 in [0x01, 0x10, 0x11, 0x12] { XCTAssertFalse(PathCodec.isBulk(type)) }
    }
}
