// The automation server's socket lifecycle: private files, one request/response
// per line, client counting, and a stop that removes the socket and drops
// clients (docs/design/mcp.md).

import Darwin
import XCTest
@testable import Contigua

final class MCPServerTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pd-mcp-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: UNIX socket helpers

    private func connect(to path: String) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw MCPServerError.socket("socket: \(errno)") }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            destination.copyBytes(from: Array(path.utf8))
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let length = socklen_t(MemoryLayout<sockaddr_un>.size)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, length)
            }
        }
        guard result == 0 else {
            let code = errno
            close(fd)
            throw MCPServerError.socket("connect: \(code)")
        }
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        return fd
    }

    private func send(_ text: String, to fd: Int32) throws {
        let data = Data(text.utf8)
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let written = write(fd, base.advanced(by: offset), raw.count - offset)
                guard written > 0 else { throw MCPServerError.socket("write: \(errno)") }
                offset += written
            }
        }
    }

    /// Blocking read off the main actor: the server answers on the main actor.
    private func readLine(from fd: Int32) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                var data = Data()
                var byte: UInt8 = 0
                while true {
                    let count = recv(fd, &byte, 1, 0)
                    if count <= 0 {
                        continuation.resume(returning: data)
                        return
                    }
                    data.append(byte)
                    if byte == 0x0A { break }
                }
                continuation.resume(returning: data)
            }
        }
    }

    private func waitFor(_ condition: @escaping @MainActor () -> Bool) async {
        for _ in 0..<100 {
            if await condition() { return }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("condition did not become true")
    }

    // MARK: Tests

    @MainActor
    func testStartCreatesAPrivateSocketAndAnswersALine() async throws {
        let socketPath = directory.appendingPathComponent("mcp.sock").path
        let server = MCPSocketServer(path: socketPath) { line in
            XCTAssertEqual(String(data: line.prefix(1), encoding: .utf8), "{")
            return await MCPDispatcher.handle(
                line: line,
                perform: { call in
                    XCTAssertEqual(call, .phoneStatus)
                    return .text(#"{"connected":true}"#)
                })
        }
        try server.start()
        defer { server.stop() }

        XCTAssertTrue(FileManager.default.fileExists(atPath: socketPath))
        let directoryMode = (try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber)?.intValue ?? 0
        XCTAssertEqual(directoryMode & 0o777, 0o700)
        let socketMode = (try FileManager.default.attributesOfItem(atPath: socketPath)[.posixPermissions] as? NSNumber)?.intValue ?? 0
        XCTAssertEqual(socketMode & 0o777, 0o600)

        let fd = try connect(to: socketPath)
        defer { close(fd) }
        await waitFor { server.clientCount == 1 }

        try send(#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"phone_status","arguments":{}}}"# + "\n", to: fd)
        let reply = try await readLine(from: fd)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: reply) as? [String: Any])
        XCTAssertEqual(object["id"] as? Int, 1)
        let result = try XCTUnwrap(object["result"] as? [String: Any])
        XCTAssertNil(result["isError"])
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        XCTAssertEqual(content.first?["text"] as? String, #"{"connected":true}"#)
    }

    @MainActor
    func testStopRemovesTheSocketAndDropsClients() async throws {
        let socketPath = directory.appendingPathComponent("mcp.sock").path
        let server = MCPSocketServer(path: socketPath) { line in
            await MCPDispatcher.handle(line: line, perform: { _ in .text("ok") })
        }
        try server.start()
        let fd = try connect(to: socketPath)
        defer { close(fd) }
        await waitFor { server.clientCount == 1 }

        server.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: socketPath))
        await waitFor { server.clientCount == 0 }

        // The accepted socket is closed by the server: the client sees EOF.
        let trailing = try await readLine(from: fd)
        XCTAssertTrue(trailing.isEmpty)
    }

    @MainActor
    func testTwoClientsAreCountedSeparately() async throws {
        let socketPath = directory.appendingPathComponent("mcp.sock").path
        let server = MCPSocketServer(path: socketPath) { line in
            await MCPDispatcher.handle(line: line, perform: { _ in .text("ok") })
        }
        try server.start()
        defer { server.stop() }
        let first = try connect(to: socketPath)
        let second = try connect(to: socketPath)
        defer { close(first); close(second) }

        await waitFor { server.clientCount == 2 }
        try send(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"# + "\n", to: first)
        try send(#"{"jsonrpc":"2.0","id":2,"method":"ping"}"# + "\n", to: second)
        let firstReply = try await readLine(from: first)
        let secondReply = try await readLine(from: second)
        let firstObject = try XCTUnwrap(JSONSerialization.jsonObject(with: firstReply) as? [String: Any])
        let secondObject = try XCTUnwrap(JSONSerialization.jsonObject(with: secondReply) as? [String: Any])
        XCTAssertEqual(firstObject["id"] as? Int, 1)
        XCTAssertEqual(secondObject["id"] as? Int, 2)

        close(first)
        await waitFor { server.clientCount == 1 }
    }

    @MainActor
    func testStartingTwiceKeepsOneSocket() throws {
        let socketPath = directory.appendingPathComponent("mcp.sock").path
        let server = MCPSocketServer(path: socketPath) { line in
            await MCPDispatcher.handle(line: line, perform: { _ in .text("ok") })
        }
        try server.start()
        defer { server.stop() }
        try server.start()
        XCTAssertTrue(FileManager.default.fileExists(atPath: socketPath))
    }

    // MARK: MCP-2 (the peer-uid check) and MCP-10 (a client's read EOF)

    @MainActor
    func testAForeignUidIsClosed() async throws {
        let socketPath = directory.appendingPathComponent("mcp.sock").path
        let server = MCPSocketServer(path: socketPath,
            handler: { line in
                await MCPDispatcher.handle(line: line, perform: { _ in .text("ok") })
            },
            peerIsOurs: { _ in false })
        try server.start()
        defer { server.stop() }

        // A foreign uid is closed at once: the client reads EOF with no byte,
        // and is never counted as an accepted client.
        let fd = try connect(to: socketPath)
        defer { close(fd) }
        let data = try await readLine(from: fd)
        XCTAssertTrue(data.isEmpty)
        XCTAssertEqual(server.clientCount, 0)
    }

    @MainActor
    func testEOFAfterARequestStillGetsTheReply() async throws {
        let socketPath = directory.appendingPathComponent("mcp.sock").path
        let server = MCPSocketServer(path: socketPath) { line in
            await MCPDispatcher.handle(line: line, perform: { _ in .text("ok") })
        }
        try server.start()
        defer { server.stop() }
        let fd = try connect(to: socketPath)
        defer { close(fd) }
        await waitFor { server.clientCount == 1 }

        try send(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"# + "\n", to: fd)
        shutdown(fd, SHUT_WR)

        // The reply arrives before the connection closes.
        let reply = try await readLine(from: fd)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: reply) as? [String: Any])
        XCTAssertEqual(object["id"] as? Int, 1)
        let result = try XCTUnwrap(object["result"] as? [String: Any])
        XCTAssertTrue(result.isEmpty)

        let trailing = try await readLine(from: fd)
        XCTAssertTrue(trailing.isEmpty, "the connection closes only after the reply is written")
    }

    @MainActor
    func testEOFWithASlowCallWritesItsReplyFirst() async throws {
        let socketPath = directory.appendingPathComponent("mcp.sock").path
        let server = MCPSocketServer(path: socketPath) { line in
            try? await Task.sleep(nanoseconds: 300_000_000)  // real-time: a slow tool call
            return await MCPDispatcher.handle(line: line, perform: { _ in .text("ok") })
        }
        try server.start()
        defer { server.stop() }
        let fd = try connect(to: socketPath)
        defer { close(fd) }
        await waitFor { server.clientCount == 1 }

        try send(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"# + "\n", to: fd)
        shutdown(fd, SHUT_WR)

        let reply = try await readLine(from: fd)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: reply) as? [String: Any])
        XCTAssertEqual(object["id"] as? Int, 1, "the slow call's reply arrives before EOF")
        let trailing = try await readLine(from: fd)
        XCTAssertTrue(trailing.isEmpty)
    }

    @MainActor
    func testDisconnectStillClosesAtOnce() async throws {
        let socketPath = directory.appendingPathComponent("mcp.sock").path
        let server = MCPSocketServer(path: socketPath) { line in
            try? await Task.sleep(nanoseconds: 300_000_000)  // real-time: a slow tool call
            return await MCPDispatcher.handle(line: line, perform: { _ in .text("ok") })
        }
        try server.start()
        defer { server.stop() }
        let fd = try connect(to: socketPath)
        defer { close(fd) }
        await waitFor { server.clientCount == 1 }

        try send(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"# + "\n", to: fd)
        try? await Task.sleep(nanoseconds: 50_000_000)  // real-time: let the slow call start

        server.disconnectClients()
        let data = try await readLine(from: fd)
        XCTAssertTrue(data.isEmpty, "disconnect closes at once with no reply, not after the slow call")
        await waitFor { server.clientCount == 0 }
    }
}
