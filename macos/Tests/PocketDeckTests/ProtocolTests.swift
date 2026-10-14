import XCTest
@testable import PocketDeck

final class ProtocolTests: XCTestCase {

    // MARK: Frame round-trip for every type

    func testJSONFrameRoundTrip() throws {
        let payload = [UInt8](#"{"t":"hello","v":1}"#.utf8)
        try assertRoundTrip(Frame(type: .json, stream: 0, payload: payload), chunks: [1, 2, 3, 7])
    }

    func testVideoConfigRoundTrip() throws {
        let config = VideoConfig(width: 1792, height: 1200, parameterSets: [0, 0, 0, 1, 0x67, 0x11])
        let frame = Frame(type: .videoConfig, stream: 7, payload: config.payload)
        let decoded = try assertRoundTrip(frame, chunks: [5, 1, 100])
        XCTAssertEqual(try VideoConfig(payload: decoded.payload), config)
    }

    func testVideoFrameRoundTrip() throws {
        let video = VideoFrameData(ptsUs: 123_456_789, flags: 0x01, annexB: [0, 0, 1, 0x65, 9, 9])
        let frame = Frame(type: .videoFrame, stream: 3, payload: video.payload)
        let decoded = try assertRoundTrip(frame, chunks: [8, 1, 4])
        XCTAssertEqual(try VideoFrameData(payload: decoded.payload), video)
        XCTAssertTrue(try VideoFrameData(payload: decoded.payload).isKeyframe)
    }

    func testAudioConfigRoundTrip() throws {
        let config = AudioConfig(codec: AudioConfig.codecOpus, sampleRate: 48000, channels: 2, frameMs: 20, setup: [0x12, 0x10])
        let frame = Frame(type: .audioConfig, stream: 0, payload: config.payload)
        let decoded = try assertRoundTrip(frame, chunks: [5, 1, 100])
        XCTAssertEqual(try AudioConfig(payload: decoded.payload), config)
    }

    func testAudioFrameRoundTrip() throws {
        let audio = AudioFrameData(ptsUs: 987_654_321, packet: [0x4F, 0x70, 0x75, 0x73, 1, 2])
        let frame = Frame(type: .audioFrame, stream: 0, payload: audio.payload)
        let decoded = try assertRoundTrip(frame, chunks: [8, 1, 4])
        XCTAssertEqual(try AudioFrameData(payload: decoded.payload), audio)
    }

    func testTouchFrameRoundTrip() throws {
        let touch = TouchEvent(action: .move, pointerId: 0, nx: 0.25, ny: 0.75)
        let frame = Frame(type: .touch, stream: 1, payload: touch.payload)
        let decoded = try assertRoundTrip(frame, chunks: [2, 2])
        XCTAssertEqual(try TouchEvent(payload: decoded.payload), touch)
    }

    func testScrollFrameRoundTrip() throws {
        let scroll = ScrollEvent(nx: 0.5, ny: 0.5, hscroll: -1.5, vscroll: 2)
        let frame = Frame(type: .scroll, stream: 2, payload: scroll.payload)
        let decoded = try assertRoundTrip(frame, chunks: [4, 20])
        XCTAssertEqual(try ScrollEvent(payload: decoded.payload), scroll)
    }

    func testKeyFrameRoundTrip() throws {
        let key = KeyEvent(action: 0, keycode: 66, metaState: 0x3000)
        let frame = Frame(type: .key, stream: 9, payload: key.payload)
        let decoded = try assertRoundTrip(frame, chunks: [1, 1, 1, 1, 1, 1])
        XCTAssertEqual(try KeyEvent(payload: decoded.payload), key)
    }

    @discardableResult
    private func assertRoundTrip(_ frame: Frame, chunks: [Int]) throws -> Frame {
        let bytes = frame.encoded
        // Header layout: u32 len (type+stream+payload), then type, stream.
        XCTAssertEqual(bytes.count, 4 + 1 + 4 + frame.payload.count)
        var decoder = FrameDecoder()
        var decoded: [Frame] = []
        var index = 0
        var chunkIndex = 0
        while index < bytes.count {
            let size = min(chunks[chunkIndex % chunks.count], bytes.count - index)
            decoded += try decoder.append(Array(bytes[index..<(index + size)]))
            index += size
            chunkIndex += 1
        }
        XCTAssertEqual(decoded.count, 1)
        let result = try XCTUnwrap(decoded.first)
        XCTAssertEqual(result.type, frame.type)
        XCTAssertEqual(result.stream, frame.stream)
        XCTAssertEqual(result.payload, frame.payload)
        XCTAssertEqual(result.encoded, bytes)
        return result
    }

    func testDecoderYieldsMultipleFramesFromOneChunk() throws {
        let first = Frame(type: .touch, stream: 1, payload: TouchEvent(action: .down, nx: 0, ny: 0).payload)
        let second = Frame(type: .key, stream: 2, payload: KeyEvent(action: 1, keycode: 4).payload)
        var decoder = FrameDecoder()
        let frames = try decoder.append(first.encoded + second.encoded)
        XCTAssertEqual(frames, [first, second])
    }

    func testOversizedFrameIsRejected() {
        var decoder = FrameDecoder()
        let header: [UInt8] = [0xFF, 0xFF, 0xFF, 0xFF]
        XCTAssertThrowsError(try decoder.append(header)) { error in
            XCTAssertEqual(error as? ProtocolError, .oversizedFrame(0xFFFF_FFFF))
        }
    }

    func testShortFrameIsRejected() {
        var decoder = FrameDecoder()
        XCTAssertThrowsError(try decoder.append([0, 0, 0, 4, 1])) { error in
            XCTAssertEqual(error as? ProtocolError, .shortFrame(4))
        }
    }

    // MARK: f32 big-endian

    func testFloatIsBigEndian() {
        var bytes = [UInt8]()
        bytes.appendBE(Float(0.5))
        XCTAssertEqual(bytes, [0x3F, 0x00, 0x00, 0x00])
        bytes = []
        bytes.appendBE(Float(1.0))
        XCTAssertEqual(bytes, [0x3F, 0x80, 0x00, 0x00])
        bytes = []
        bytes.appendBE(Float(-2.5))
        XCTAssertEqual(bytes, [0xC0, 0x20, 0x00, 0x00])
    }

    func testFloatRoundTripsThroughByteReader() throws {
        for value: Float in [0, 1, -1, 0.1, 12_345.678, .greatestFiniteMagnitude, .leastNonzeroMagnitude] {
            var bytes = [UInt8]()
            bytes.appendBE(value)
            var reader = ByteReader(bytes)
            XCTAssertEqual(try reader.f32(), value, accuracy: abs(value) * 1e-5)
        }
    }

    func testTouchPayloadLayoutIsExact() {
        let payload = TouchEvent(action: .down, pointerId: 1, nx: 1, ny: 0).payload
        XCTAssertEqual(payload.count, 1 + 1 + 4 + 4)
        XCTAssertEqual(payload[0], 0)
        XCTAssertEqual(payload[1], 1)
        XCTAssertEqual(Array(payload[2..<6]), [0x3F, 0x80, 0x00, 0x00])
        XCTAssertEqual(Array(payload[6..<10]), [0x00, 0x00, 0x00, 0x00])
    }

    func testKeyPayloadLayoutIsExact() {
        let payload = KeyEvent(action: 0, keycode: 29, metaState: 0x3000).payload
        XCTAssertEqual(payload.count, 1 + 4 + 4)
        XCTAssertEqual(Array(payload[1..<5]), [0x00, 0x00, 0x00, 0x1D])
        XCTAssertEqual(Array(payload[5..<9]), [0x00, 0x00, 0x30, 0x00])
    }

    func testJSONEnvelopeEncodesBigEndianLength() {
        let bytes = JSONFrame.encode(["t": "ping"])
        // len = type + stream + payload = 5 + 12.
        XCTAssertEqual(Array(bytes[0..<4]), [0x00, 0x00, 0x00, 17])
        XCTAssertEqual(bytes[4], MessageType.json.rawValue)
        XCTAssertEqual(Array(bytes[5..<9]), [0, 0, 0, 0])
        XCTAssertEqual(JSONFrame.decode(payload: Array(bytes[9...]))?.t, "ping")
    }
}
