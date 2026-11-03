#if POCKETDECK_DIRECT
import Darwin
import Foundation
import PDLWIP
import XCTest
@testable import pocketdeck_directd

/// The helper's lwIP stack on a fake link: `linkoutput` writes into a
/// socketpair, and `pdl_input` is fed the frames a kernel would send. No BPF,
/// no root, no interface (docs/design/direct-link.md §7.1.1).
final class DirectStackTests: XCTestCase {
    private let ownMAC: [UInt8] = [0x66, 0x65, 0x74, 0x68, 0x00, 0x00]
    private let peerMAC: [UInt8] = [0x66, 0x65, 0x74, 0x68, 0x00, 0x01]
    private let ownLL: [UInt8] = [0xfe, 0x80, 0, 0, 0, 0, 0, 0,
                                  0x64, 0x65, 0x74, 0xff, 0xfe, 0x68, 0x00, 0xa5]
    private let peerLL: [UInt8] = [0xfe, 0x80, 0, 0, 0, 0, 0, 0,
                                   0x64, 0x65, 0x74, 0xff, 0xfe, 0x68, 0x00, 0x01]

    func testLinkLocalIsValidAfterBringUp() throws {
        let link = try FakeLink(ownMAC: ownMAC, ownLL: ownLL)
        XCTAssertEqual(pdl_address_state(link.stack), 0x30,
                       "lwIP's link-local must be preferred (0x30), not tentative (0x08…)")
    }

    func testNeighbourSolicitationGetsOneAdvertisement() throws {
        let link = try FakeLink(ownMAC: ownMAC, ownLL: ownLL)
        link.send(link.neighbourSolicitation(from: peerLL, fromMAC: peerMAC))
        let frames = link.drainFrames()
        XCTAssertEqual(frames.count, 1, "one NS must make lwIP emit exactly one NA")
        let frame = try XCTUnwrap(frames.first)
        XCTAssertEqual(link.ethernetDestination(frame), peerMAC)
        XCTAssertEqual(link.ethernetSource(frame), ownMAC)
        XCTAssertEqual(link.ipv6Source(frame), ownLL)
        XCTAssertEqual(link.ipv6Destination(frame), peerLL)
        XCTAssertEqual(frame[54], 136, "ICMPv6 type: neighbour advertisement")
        XCTAssertEqual(frame[55], 0)
        XCTAssertEqual(frame[58], 0x60, "Solicited and Override flags")
        XCTAssertEqual(Array(frame[62..<78]), ownLL)
        XCTAssertEqual(Array(frame[78..<80]), [2, 1], "target link-layer option")
        XCTAssertEqual(Array(frame[80..<86]), ownMAC)
        XCTAssertEqual(link.ipv6Checksum(frame, payloadOffset: 54), 0,
                       "the NA's ICMPv6 checksum must verify")
    }

    func testConnectEmitsOneSynToTheStaticPeer() throws {
        let link = try FakeLink(ownMAC: ownMAC, ownLL: ownLL)
        pdl_set_peer(link.stack, peerLL, peerMAC)
        resetCallbacks()
        let conn = try XCTUnwrap(link.connect(to: peerLL, port: 47_990))
        defer { link.closeConnection(conn) }

        let frames = link.drainFrames()
        XCTAssertEqual(frames.count, 1, "tcp_connect must put exactly one SYN on the wire")
        let frame = try XCTUnwrap(frames.first)
        XCTAssertEqual(link.ethernetDestination(frame), peerMAC)
        XCTAssertEqual(link.ethernetSource(frame), ownMAC)
        XCTAssertEqual(link.ipv6Source(frame), ownLL)
        XCTAssertEqual(link.ipv6Destination(frame), peerLL)
        XCTAssertEqual(frame[20], 6, "next header: TCP")
        XCTAssertEqual(frame[66] >> 4, 6, "TCP header length with the MSS option")
        XCTAssertEqual(frame[67] & 0x3f, 0x02, "SYN without ACK")
        XCTAssertEqual(link.ipv6Checksum(frame, payloadOffset: 54), 0,
                       "the SYN's TCP checksum must verify")
        XCTAssertTrue(link.mssOptions(frame).contains(1400),
                      "the SYN advertises MSS 1400, got \(link.mssOptions(frame))")
    }

    func testSynAckBringsTheLinkUpAndIsAcknowledged() throws {
        let link = try FakeLink(ownMAC: ownMAC, ownLL: ownLL)
        pdl_set_peer(link.stack, peerLL, peerMAC)
        resetCallbacks()
        let conn = try XCTUnwrap(link.connect(to: peerLL, port: 47_990))
        defer { link.closeConnection(conn) }

        let syn = try XCTUnwrap(link.drainFrames().first)
        let synSeq = link.tcpSequence(syn)
        let synAckSeq: UInt32 = 0x1122_3344
        let synAck = link.synAck(from: peerLL, fromMAC: peerMAC, to: ownLL,
                                 clientPort: link.tcpSourcePort(syn),
                                 serverPort: link.tcpDestinationPort(syn),
                                 sequence: synAckSeq, acknowledgement: synSeq &+ 1)
        link.send(synAck)
        XCTAssertEqual(directTestConnected, 1, "the connected callback runs on the SYN-ACK")
        XCTAssertEqual(pdl_conn_alive(conn), 1)

        let frames = link.drainFrames()
        XCTAssertEqual(frames.count, 1, "the SYN-ACK must be answered with one ACK")
        let frame = try XCTUnwrap(frames.first)
        XCTAssertEqual(link.ethernetDestination(frame), peerMAC)
        XCTAssertEqual(frame[66] >> 4, 5)
        XCTAssertEqual(frame[67] & 0x3f, 0x10, "ACK without SYN")
        XCTAssertEqual(link.tcpAcknowledgement(frame), synAckSeq &+ 1)
        XCTAssertEqual(link.ipv6Checksum(frame, payloadOffset: 54), 0,
                       "the ACK's TCP checksum must verify")
    }

    func testDataAfterHandshakeUsesTheNegotiatedMss() throws {
        let link = try FakeLink(ownMAC: ownMAC, ownLL: ownLL)
        pdl_set_peer(link.stack, peerLL, peerMAC)
        resetCallbacks()
        let conn = try XCTUnwrap(link.connect(to: peerLL, port: 47_990))
        defer { link.closeConnection(conn) }

        let syn = try XCTUnwrap(link.drainFrames().first)
        let synAckSeq: UInt32 = 0x1122_3344
        link.send(link.synAck(from: peerLL, fromMAC: peerMAC, to: ownLL,
                              clientPort: link.tcpSourcePort(syn),
                              serverPort: link.tcpDestinationPort(syn),
                              sequence: synAckSeq, acknowledgement: link.tcpSequence(syn) &+ 1))
        _ = link.drainFrames()

        let payload = (0..<4096).map { UInt8($0 & 0xff) }
        var accepted = 0
        payload.withUnsafeBufferPointer {
            XCTAssertEqual(pdl_write(conn, $0.baseAddress, payload.count, &accepted), 0)
        }
        XCTAssertEqual(accepted, payload.count)
        pdl_output(conn)

        let frames = link.drainFrames()
        XCTAssertFalse(frames.isEmpty, "data queued before the handshake must reach the wire")
        var sent: [UInt8] = []
        for frame in frames {
            let headerLength = Int(frame[66] >> 4) * 4
            let payloadLength = Int(u16(frame, 18)) - headerLength
            XCTAssertLessThanOrEqual(payloadLength, 1400, "a segment larger than the MSS")
            XCTAssertEqual(link.ipv6Checksum(frame, payloadOffset: 54), 0,
                           "every data segment needs a valid TCP checksum")
            sent += frame[(54 + headerLength)..<(54 + headerLength + payloadLength)]
        }
        XCTAssertEqual(sent, payload, "the peer must receive the bytes in order")
    }

    func testLinkPumpsAppBytesAfterAttach() throws {
        let fake = try FakeLink(ownMAC: ownMAC, ownLL: ownLL)
        pdl_set_peer(fake.stack, peerLL, peerMAC)
        resetCallbacks()
        let conn = try XCTUnwrap(fake.connect(to: peerLL, port: 47_990))
        let syn = try XCTUnwrap(fake.drainFrames().first)
        let synAckSeq: UInt32 = 0x1122_3344
        fake.send(fake.synAck(from: peerLL, fromMAC: peerMAC, to: ownLL,
                              clientPort: fake.tcpSourcePort(syn),
                              serverPort: fake.tcpDestinationPort(syn),
                              sequence: synAckSeq, acknowledgement: fake.tcpSequence(syn) &+ 1))
        _ = fake.drainFrames()

        var pair = [Int32](repeating: 0, count: 2)
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair), 0)
        let link = Link(id: "0123456789abcdef", peer: "peer", sock: pair[1],
                        port: 47_990, remote: "fe80::1")
        defer {
            link.closeByApp()
            link.releaseConnection()
            close(pair[0])
            close(pair[1])
        }

        link.attach(conn)
        link.connected()
        let payload = (0..<2048).map { UInt8($0 & 0xff) }
        payload.withUnsafeBufferPointer { XCTAssertTrue(link.appendFromApp($0)) }
        link.pumpToStack()

        let frames = fake.drainFrames()
        XCTAssertFalse(frames.isEmpty, "an attached link must write the app's bytes to the peer")
        XCTAssertEqual(frames.reduce(0) { $0 + Int(u16($1, 18)) - Int($1[66] >> 4) * 4 },
                       payload.count)
    }

    // MARK: callbacks

    private func resetCallbacks() {
        directTestConnected = 0
        directTestErrors = []
    }
}

private var directTestConnected = 0
private var directTestErrors: [Int32] = []

private func directTestConnectedCallback(_ context: UnsafeMutableRawPointer?) {
    _ = context
    directTestConnected += 1
}

private func directTestRecvCallback(_ context: UnsafeMutableRawPointer?,
                                    _ data: UnsafePointer<UInt8>?,
                                    _ length: UInt16) -> UInt16 {
    _ = context
    _ = data
    _ = length
    return 0
}

private func directTestSentCallback(_ context: UnsafeMutableRawPointer?, _ free: UInt16) {
    _ = context
    _ = free
}

private func directTestErrorCallback(_ context: UnsafeMutableRawPointer?, _ code: Int32) {
    _ = context
    directTestErrors.append(code)
}

// MARK: - the fake link

private final class FakeLink {
    let stack: OpaquePointer
    private let writeFD: Int32
    private let readFD: Int32
    private var pending = Data()
    private let ownMAC: [UInt8]
    private let ownLL: [UInt8]

    enum Failure: Error { case socketpair, stack }

    init(ownMAC: [UInt8], ownLL: [UInt8]) throws {
        self.ownMAC = ownMAC
        self.ownLL = ownLL
        var pair = [Int32](repeating: 0, count: 2)
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else { throw Failure.socketpair }
        let write = pair[0]
        let read = pair[1]
        writeFD = write
        readFD = read
        _ = fcntl(read, F_SETFL, O_NONBLOCK)
        guard let stack = ownMAC.withUnsafeBufferPointer({ pdl_new(write, $0.baseAddress) }) else {
            close(write)
            close(read)
            throw Failure.stack
        }
        self.stack = stack
        guard ownLL.withUnsafeBufferPointer({ pdl_start(stack, $0.baseAddress, 0) }) == 0 else {
            pdl_free(stack)
            close(writeFD)
            close(readFD)
            throw Failure.stack
        }
    }

    deinit {
        pdl_free(stack)
        close(writeFD)
        close(readFD)
    }

    func connect(to peer: [UInt8], port: UInt16) -> OpaquePointer? {
        peer.withUnsafeBufferPointer { address in
            pdl_connect(stack, address.baseAddress, port, nil,
                        directTestConnectedCallback, directTestRecvCallback,
                        directTestSentCallback, directTestErrorCallback)
        }
    }

    func closeConnection(_ conn: OpaquePointer) {
        pdl_close(conn)
        pdl_release(conn)
    }

    func send(_ frame: [UInt8]) {
        frame.withUnsafeBufferPointer { pdl_input(stack, $0.baseAddress, frame.count) }
    }

    /// Every complete Ethernet frame the stack wrote since the last call.
    func drainFrames() -> [[UInt8]] {
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let got = read(readFD, &buffer, buffer.count)
            guard got > 0 else { break }
            pending.append(contentsOf: buffer[0..<got])
        }
        var all = Array(pending)
        var frames: [[UInt8]] = []
        var offset = 0
        while all.count - offset >= 54 {
            let payloadLength = Int(all[offset + 18]) << 8 | Int(all[offset + 19])
            let total = 14 + 40 + payloadLength
            guard all.count - offset >= total else { break }
            frames.append(Array(all[offset..<offset + total]))
            offset += total
        }
        all.removeFirst(offset)
        pending = Data(all)
        return frames
    }

    // MARK: frames the kernel would send

    func neighbourSolicitation(from source: [UInt8], fromMAC mac: [UInt8]) -> [UInt8] {
        let destination = solicitedNode(ownLL)
        var icmp = [UInt8](repeating: 0, count: 32)
        icmp[0] = 135
        icmp[8..<24] = ownLL[...]
        icmp[24] = 1
        icmp[25] = 1
        icmp[26..<32] = mac[...]
        setChecksum(&icmp, at: 2, pseudo: pseudoHeader(source: source, destination: destination,
                                                       nextHeader: 58, payload: icmp))
        return ethernet(destination: ethernetMulticast(destination), source: mac,
                        nextHeader: 58, sourceAddress: source,
                        destinationAddress: destination, payload: icmp)
    }

    func synAck(from source: [UInt8], fromMAC mac: [UInt8], to destination: [UInt8],
                clientPort: UInt16, serverPort: UInt16,
                sequence: UInt32, acknowledgement: UInt32) -> [UInt8] {
        var tcp = [UInt8](repeating: 0, count: 24)
        put16(&tcp, 0, serverPort)
        put16(&tcp, 2, clientPort)
        put32(&tcp, 4, sequence)
        put32(&tcp, 8, acknowledgement)
        tcp[12] = 6 << 4
        tcp[13] = 0x12 // SYN | ACK
        put16(&tcp, 14, 65_535)
        tcp[20] = 2 // MSS option
        tcp[21] = 4
        put16(&tcp, 22, 1400)
        setChecksum(&tcp, at: 16, pseudo: pseudoHeader(source: source, destination: destination,
                                                       nextHeader: 6, payload: tcp))
        return ethernet(destination: ownMAC, source: mac, nextHeader: 6,
                        sourceAddress: source, destinationAddress: destination, payload: tcp)
    }

    // MARK: frame readers

    func ethernetDestination(_ frame: [UInt8]) -> [UInt8] { Array(frame[0..<6]) }
    func ethernetSource(_ frame: [UInt8]) -> [UInt8] { Array(frame[6..<12]) }
    func ipv6Source(_ frame: [UInt8]) -> [UInt8] { Array(frame[22..<38]) }
    func ipv6Destination(_ frame: [UInt8]) -> [UInt8] { Array(frame[38..<54]) }
    func tcpSourcePort(_ frame: [UInt8]) -> UInt16 { u16(frame, 54) }
    func tcpDestinationPort(_ frame: [UInt8]) -> UInt16 { u16(frame, 56) }
    func tcpSequence(_ frame: [UInt8]) -> UInt32 { u32(frame, 58) }
    func tcpAcknowledgement(_ frame: [UInt8]) -> UInt32 { u32(frame, 62) }

    func mssOptions(_ frame: [UInt8]) -> [UInt16] {
        let headerLength = Int(frame[66] >> 4) * 4
        var offset = 54 + 20
        let end = 54 + headerLength
        var values: [UInt16] = []
        while offset + 1 < end {
            let kind = frame[offset]
            if kind == 0 { break }
            if kind == 1 { offset += 1; continue }
            guard offset + 1 < end else { break }
            let length = Int(frame[offset + 1])
            guard length >= 2, offset + length <= end else { break }
            if kind == 2, length == 4 { values.append(u16(frame, offset + 2)) }
            offset += length
        }
        return values
    }

    /// Zero when the transport checksum in `payloadOffset` verifies.
    func ipv6Checksum(_ frame: [UInt8], payloadOffset: Int) -> UInt16 {
        let length = Int(u16(frame, 18))
        let source = Array(frame[22..<38])
        let destination = Array(frame[38..<54])
        let nextHeader = frame[20]
        let payload = Array(frame[payloadOffset..<payloadOffset + length])
        return internetChecksum(pseudoHeader(source: source, destination: destination,
                                             nextHeader: nextHeader, payload: payload)
                                + payload)
    }

    // MARK: bytes

    private func ethernet(destination: [UInt8], source: [UInt8], nextHeader: UInt8,
                          sourceAddress: [UInt8], destinationAddress: [UInt8],
                          payload: [UInt8]) -> [UInt8] {
        var frame = destination + source + [0x86, 0xdd]
        let length = payload.count
        frame += [0x60, 0, 0, 0, UInt8(length >> 8), UInt8(length & 0xff),
                  nextHeader, 255]
        frame += sourceAddress + destinationAddress + payload
        return frame
    }

    private func solicitedNode(_ address: [UInt8]) -> [UInt8] {
        [0xff, 0x02, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0xff,
         address[13], address[14], address[15]]
    }

    private func ethernetMulticast(_ address: [UInt8]) -> [UInt8] {
        [0x33, 0x33, address[12], address[13], address[14], address[15]]
    }

    private func pseudoHeader(source: [UInt8], destination: [UInt8],
                              nextHeader: UInt8, payload: [UInt8]) -> [UInt8] {
        let length = payload.count
        return source + destination
            + [UInt8(length >> 24), UInt8((length >> 16) & 0xff),
               UInt8((length >> 8) & 0xff), UInt8(length & 0xff),
               0, 0, 0, nextHeader]
    }

    private func setChecksum(_ bytes: inout [UInt8], at offset: Int, pseudo: [UInt8]) {
        bytes[offset] = 0
        bytes[offset + 1] = 0
        let sum = internetChecksum(pseudo + bytes)
        bytes[offset] = UInt8(sum >> 8)
        bytes[offset + 1] = UInt8(sum & 0xff)
    }
}

private func internetChecksum(_ bytes: [UInt8]) -> UInt16 {
    var sum: UInt32 = 0
    var index = 0
    while index + 1 < bytes.count {
        sum += UInt32(bytes[index]) << 8 | UInt32(bytes[index + 1])
        index += 2
    }
    if index < bytes.count {
        sum += UInt32(bytes[index]) << 8
    }
    while sum >> 16 != 0 {
        sum = (sum & 0xffff) + (sum >> 16)
    }
    return UInt16(~sum & 0xffff)
}

private func u16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
    UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1])
}

private func u32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
    UInt32(bytes[offset]) << 24 | UInt32(bytes[offset + 1]) << 16
        | UInt32(bytes[offset + 2]) << 8 | UInt32(bytes[offset + 3])
}

private func put16(_ bytes: inout [UInt8], _ offset: Int, _ value: UInt16) {
    bytes[offset] = UInt8(value >> 8)
    bytes[offset + 1] = UInt8(value & 0xff)
}

private func put32(_ bytes: inout [UInt8], _ offset: Int, _ value: UInt32) {
    bytes[offset] = UInt8(value >> 24)
    bytes[offset + 1] = UInt8((value >> 16) & 0xff)
    bytes[offset + 2] = UInt8((value >> 8) & 0xff)
    bytes[offset + 3] = UInt8(value & 0xff)
}
#endif
