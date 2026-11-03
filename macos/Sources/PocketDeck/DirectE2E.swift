#if POCKETDECK_DIRECT
import Darwin
import Foundation
import NIOCore
import NIOPosix
import PocketDeckDirectCore

/// The direct-link e2e client (docs/design/direct-link.md §7.2): the app's own
/// TLS code over the helper's fd, so the VM check measures what the product
/// will run. Test-only, compiled only with POCKETDECK_DIRECT.
enum DirectE2E {
    static func requestedMode(_ arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: "--direct-e2e"),
              index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

    static func run(mode: String, arguments: [String]) -> Never {
        setvbuf(stdout, nil, _IOLBF, 0)
        alarm(600)
        let options = LaunchOptions.parse(arguments)
        if let refusal = options.launchRefusal(releaseBuild: false) {
            fail(refusal)
        }
        do {
            try runMode(mode)
        } catch {
            fail("\(error)")
        }
        exit(0)
    }

    private static func fail(_ message: String) -> Never {
        print("DIRECT-ERROR \(message)")
        exit(1)
    }

    private static func env(_ name: String) -> String {
        ProcessInfo.processInfo.environment[name] ?? ""
    }

    private static func socketPath() -> String {
        env("PD_DIRECT_SOCK")
    }

    private static func peerMAC() -> String { env("PD_DIRECT_PEER_MAC") }
    private static func peerLL() -> String { env("PD_DIRECT_PEER_LL") }
    private static func portrait() -> UInt16 { UInt16(env("PD_DIRECT_PORT")) ?? 47990 }
    private static func tlsPort() -> UInt16 { UInt16(env("PD_DIRECT_TLS_PORT")) ?? 47991 }
    private static func seconds() -> Double { Double(env("PD_DIRECT_SECS")) ?? 30 }

    private static func runMode(_ mode: String) throws {
        switch mode {
        case "path": try runPath()
        case "close": try runClose()
        case "shared": try runShared()
        case "bench": try runBench()
        default: fail("unknown mode \(mode)")
        }
    }

    private static func helloAndPeer(_ client: HelperClient) throws {
        let hello = try client.call(["op": "hello", "v": 1])
        guard hello["ok"] as? Bool == true, hello["v"] as? Int == 1 else {
            throw DirectE2EError.reply("hello", hello)
        }
        print("DIRECT hello ok")
        let peer = try client.call(["op": "peer", "if": "feth0",
                                    "mac": peerMAC(), "ll": peerLL()])
        guard peer["ok"] as? Bool == true else { throw DirectE2EError.reply("peer", peer) }
        print("DIRECT peer ok \(peerMAC()) \(peerLL())")
    }

    private static func dial(_ client: HelperClient, port: UInt16) throws -> (String, Int32) {
        let reply = try client.call(["op": "dial", "port": Int(port)])
        guard reply["ok"] as? Bool == true,
              let link = reply["link"] as? String,
              let fd = client.takeReceivedFD() else {
            throw DirectE2EError.reply("dial", reply)
        }
        print("DIRECT dial ok link=\(link) mtu=\(reply["mtu"] as? Int ?? 0)")
        return (link, fd)
    }

    // MARK: the correctness path (§7.2)

    private static func runPath() throws {
        let client = try HelperClient(path: socketPath())
        try helloAndPeer(client)
        let (link, fd) = try dial(client, port: portrait())
        defer { close(fd) }
        configureSocket(fd)

        try echo(fd: fd, bytes: 1 << 20)
        print("DIRECT echo ok bytes=1048576")

        for size in [1399, 1400, 1401, 2800, 4200] {
            try echo(fd: fd, bytes: size)
        }
        print("DIRECT mss ok sizes=1399,1400,1401,2800,4200")

        let closed = try client.call(["op": "close", "link": link])
        guard closed["ok"] as? Bool == true else { throw DirectE2EError.reply("close", closed) }
        print("DIRECT close ok")
    }

    private static func runShared() throws {
        let client = try HelperClient(path: socketPath())
        try helloAndPeer(client)
        let (_, fd) = try dial(client, port: portrait())
        defer { close(fd) }
        configureSocket(fd)
        do {
            try echo(fd: fd, bytes: 4096)
            print("DIRECT shared-echo ok")
        } catch {
            print("DIRECT shared-echo fail \(error)")
        }
    }

    /// The peer closes 1 s after accept; the helper must report the link down
    /// within 5 s of the app seeing EOF, not hang.
    private static func runClose() throws {
        let client = try HelperClient(path: socketPath())
        try helloAndPeer(client)
        let (link, fd) = try dial(client, port: portrait())
        defer { close(fd) }
        configureSocket(fd)

        let state = LinkProbe(fd: fd).writeUntilBroken(deadline: Date().addingTimeInterval(6))
        let endedAt = Date()
        let probe = try HelperClient(path: socketPath())
        for _ in 0..<200 {
            let reply = try probe.call(["op": "links"])
            if let links = reply["links"] as? [[String: Any]],
               let ours = links.first(where: { $0["link"] as? String == link }) {
                if ours["state"] as? String == "down" {
                    let milliseconds = Int(Date().timeIntervalSince(endedAt) * 1000)
                    print("DIRECT eof detected=\(state.rawValue) down ms=\(milliseconds)")
                    return
                }
            } else if reply["ok"] as? Bool == false {
                throw DirectE2EError.reply("links", reply)
            }
            usleep(100_000)
        }
        throw DirectE2EError.message("the link never reported down after the peer closed")
    }

    // MARK: the benchmark (§7.3)

    private static func runBench() throws {
        let client = try HelperClient(path: socketPath())
        try helloAndPeer(client)
        let duration = seconds()

        let (plainLink, plainFD) = try dial(client, port: portrait())
        configureSocket(plainFD)
        let plain = try measureWrites(fd: plainFD, seconds: duration)
        close(plainFD)
        _ = try client.call(["op": "close", "link": plainLink])
        print("DIRECT plain bytes=\(plain.bytes) seconds=\(String(format: "%.2f", plain.seconds)) mbps=\(String(format: "%.2f", plain.mbps))")

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? group.syncShutdownGracefully() }
        let (identity, _) = IdentityGeneratorV2.make(deviceId: "directp2-e2e")
        let connector = TlsConnectorV2(identity: identity, pinnedPhone: nil, group: group)
        let (tlsLink, tlsFD) = try dial(client, port: tlsPort())
        let started = Date()
        let connection = try connector.connect(socket: tlsFD, onFrame: { _ in }, onError: { _ in })
        print("DIRECT tls handshake ms=\(Int(Date().timeIntervalSince(started) * 1000))")
        let tls = try measureTLSWrites(channel: connection.channel, seconds: duration)
        connection.channel.close(promise: nil)
        _ = try client.call(["op": "close", "link": tlsLink])
        print("DIRECT tls bytes=\(tls.bytes) seconds=\(String(format: "%.2f", tls.seconds)) mbps=\(String(format: "%.2f", tls.mbps))")
    }

    private struct Measured {
        var bytes: Int
        var seconds: Double
        var mbps: Double
    }

    private static func measureWrites(fd: Int32, seconds: Double) throws -> Measured {
        let chunk = pattern(count: 64 * 1024, seed: 0)
        var total = 0
        let start = Date()
        var first = Date()
        while true {
            if total == 0 { first = Date() }
            try writeAll(fd: fd, bytes: chunk, deadline: Date().addingTimeInterval(60))
            total += chunk.count
            let elapsed = Date().timeIntervalSince(first)
            if elapsed >= seconds { break }
        }
        let elapsed = max(Date().timeIntervalSince(first), 0.001)
        return Measured(bytes: total, seconds: elapsed,
                        mbps: Double(total) * 8 / 1_000_000 / elapsed)
    }

    private static func measureTLSWrites(channel: Channel, seconds: Double) throws -> Measured {
        let chunk = pattern(count: 64 * 1024, seed: 1)
        var total = 0
        let first = Date()
        while true {
            var copy = channel.allocator.buffer(capacity: chunk.count)
            copy.writeBytes(chunk)
            try channel.writeAndFlush(copy).wait()
            total += chunk.count
            if Date().timeIntervalSince(first) >= seconds { break }
        }
        let elapsed = max(Date().timeIntervalSince(first), 0.001)
        return Measured(bytes: total, seconds: elapsed,
                        mbps: Double(total) * 8 / 1_000_000 / elapsed)
    }

    // MARK: socket helpers

    private static func configureSocket(_ fd: Int32) {
        var timeout = timeval(tv_sec: 30, tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    }

    private static func pattern(count: Int, seed: Int) -> [UInt8] {
        (0..<count).map { UInt8(truncatingIfNeeded: (($0 &* 31) &+ 7) &+ seed) }
    }

    /// Writes and reads back `bytes` in 64 KiB chunks, comparing every byte.
    private static func echo(fd: Int32, bytes: Int) throws {
        let chunkSize = 64 * 1024
        var offset = 0
        while offset < bytes {
            let count = min(chunkSize, bytes - offset)
            let data = (0..<count).map { UInt8(truncatingIfNeeded: ($0 &+ offset) &* 13) }
            try writeAll(fd: fd, bytes: data, deadline: Date().addingTimeInterval(30))
            var got = [UInt8](repeating: 0, count: count)
            try readAll(fd: fd, into: &got, deadline: Date().addingTimeInterval(30))
            guard got == data else {
                throw DirectE2EError.message("echo mismatch at offset \(offset)")
            }
            offset += count
        }
    }

    private static func writeAll(fd: Int32, bytes: [UInt8], deadline: Date) throws {
        var sent = 0
        try bytes.withUnsafeBytes { raw in
            while sent < raw.count {
                let wrote = write(fd, raw.baseAddress!.advanced(by: sent), raw.count - sent)
                if wrote > 0 { sent += wrote; continue }
                if wrote < 0 && (errno == EINTR) { continue }
                if wrote < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                    if Date() > deadline { throw DirectE2EError.message("write timed out") }
                    continue
                }
                throw DirectE2EError.message("write failed: \(String(cString: strerror(errno)))")
            }
        }
    }

    private static func readAll(fd: Int32, into buffer: inout [UInt8], deadline: Date) throws {
        var got = 0
        try buffer.withUnsafeMutableBytes { raw in
            while got < raw.count {
                let readCount = read(fd, raw.baseAddress!.advanced(by: got), raw.count - got)
                if readCount > 0 { got += readCount; continue }
                if readCount == 0 { throw DirectE2EError.message("EOF after \(got) bytes") }
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    if Date() > deadline { throw DirectE2EError.message("read timed out after \(got) bytes") }
                    continue
                }
                throw DirectE2EError.message("read failed: \(String(cString: strerror(errno)))")
            }
        }
    }
}

enum DirectE2EError: Error, CustomStringConvertible {
    case message(String)
    case reply(String, [String: Any])

    var description: String {
        switch self {
        case .message(let text): return text
        case .reply(let op, let json): return "\(op) refused: \(json)"
        }
    }
}
#endif
