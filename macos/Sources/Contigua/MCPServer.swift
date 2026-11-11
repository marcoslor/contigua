// The app's end of the automation server (docs/design/mcp.md): a UNIX socket in
// the profile's Application Support folder, newline-delimited requests, at most
// four clients at once, and a peer-uid check before a client is accepted.
//
// The socket and its folder are private: folder 0700, socket 0600, and
// `getpeereid` must report our own uid. A client that disconnects is dropped;
// stopping the server closes every client and unlinks the socket.

import Darwin
import Foundation

@MainActor
final class MCPSocketServer {
    private final class Client {
        let fd: Int32
        let source: DispatchSourceRead
        var buffer = Data()
        var pending: [Data] = []
        var busy = false

        init(fd: Int32, source: DispatchSourceRead) {
            self.fd = fd
            self.source = source
        }
    }

    /// The socket file. Tests pass a temp path; the app uses the profile's.
    let path: String
    private let handler: (Data) async -> Data?

    private let queue = DispatchQueue(label: "app.contigua.mcp.io")
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var clients: [Int32: Client] = [:]
    private var running = false

    /// Called on the main actor whenever the accepted-client count changes.
    var onClientCountChanged: ((Int) -> Void)?

    private(set) var clientCount = 0 {
        didSet { if clientCount != oldValue { onClientCountChanged?(clientCount) } }
    }

    init(path: String, handler: @escaping (Data) async -> Data?) {
        self.path = path
        self.handler = handler
    }

    deinit {
        // Sockets are unlinked and closed by stop(); the owner always calls it
        // on shutdown and in the tests. Nothing is retained past that.
    }

    // MARK: Lifecycle

    func start() throws {
        guard !running else { return }
        let directory = URL(fileURLWithPath: path).deletingLastPathComponent()
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
        // The profile folder may predate this server; the socket must still sit
        // in a folder only this user can traverse.
        try? manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        unlink(path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw MCPServerError.socket("socket: \(errno)") }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let nameBytes = Array(path.utf8)
        guard nameBytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            close(fd)
            throw MCPServerError.pathTooLong(path)
        }
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            destination.copyBytes(from: nameBytes)
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let length = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, length)
            }
        }
        guard bound == 0 else {
            let code = errno
            close(fd)
            throw MCPServerError.socket("bind \(path): \(code)")
        }
        chmod(path, 0o600)
        guard listen(fd, 8) == 0 else {
            let code = errno
            close(fd)
            unlink(path)
            throw MCPServerError.socket("listen: \(code)")
        }
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        Self.setNoSIGPIPE(fd)
        listenFD = fd

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptConnections(on: fd) }
        source.setCancelHandler { close(fd) }
        acceptSource = source
        source.resume()
        running = true
    }

    func stop() {
        guard running else { return }
        running = false
        acceptSource?.cancel()
        acceptSource = nil
        listenFD = -1
        for client in clients.values { client.source.cancel() }
        clients.removeAll()
        clientCount = 0
        unlink(path)
    }

    /// The menu bar's "Disconnect agent": close every accepted client but keep
    /// the listener (and the socket) in place for later clients.
    func disconnectClients() {
        for client in clients.values { client.source.cancel() }
        clients.removeAll()
        clientCount = 0
    }

    /// The socket left by a crash is not a server: remove it when the setting
    /// is off, so no client mistakes it for one that is merely busy.
    static func removeStaleSocket(at path: String) {
        unlink(path)
    }

    // MARK: Accepting

    private nonisolated func acceptConnections(on listenFD: Int32) {
        while true {
            let fd = accept(listenFD, nil, nil)
            guard fd >= 0 else { return } // EAGAIN when the backlog is empty
            let ours = MCPSocketServer.peerIsOurs(fd)
            if !ours {
                close(fd)
                continue
            }
            Self.setNoSIGPIPE(fd)
            _ = fcntl(fd, F_SETFL, O_NONBLOCK)
            Task { @MainActor [weak self] in self?.adopt(fd) }
        }
    }

    private nonisolated static func peerIsOurs(_ fd: Int32) -> Bool {
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0 else { return false }
        return uid == getuid()
    }

    private func adopt(_ fd: Int32) {
        guard running, clients.count < 4 else {
            close(fd)
            return
        }
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        let client = Client(fd: fd, source: source)
        source.setEventHandler { [weak self] in self?.read(client: fd) }
        source.setCancelHandler { close(fd) }
        clients[fd] = client
        source.resume()
        clientCount = clients.count
    }

    // MARK: Reading

    private nonisolated func read(client fd: Int32) {
        var bytes = [UInt8](repeating: 0, count: 65536)
        let count = Darwin.read(fd, &bytes, bytes.count)
        guard count > 0 else {
            Task { @MainActor [weak self] in self?.drop(fd) }
            return
        }
        let chunk = Data(bytes: bytes, count: count)
        Task { @MainActor [weak self] in self?.receive(chunk, from: fd) }
    }

    private func receive(_ chunk: Data, from fd: Int32) {
        guard let client = clients[fd] else { return }
        client.buffer.append(chunk)
        while let newline = client.buffer.firstIndex(of: 0x0A) {
            var line = Data(client.buffer[client.buffer.startIndex..<newline])
            client.buffer.removeSubrange(client.buffer.startIndex...newline)
            if line.last == 0x0D { line.removeLast() }
            guard !line.isEmpty else { continue }
            guard line.count <= MCPProtocol.maxLineBytes else {
                refuseOversizedLine(client)
                return
            }
            client.pending.append(line)
        }
        if client.buffer.count > MCPProtocol.maxLineBytes {
            refuseOversizedLine(client)
            return
        }
        drain(client)
    }

    private func refuseOversizedLine(_ client: Client) {
        let error = Data(#"{"jsonrpc":"2.0","id":null,"error":{"code":-32600,"message":"Request line is longer than 1 MiB"}}"#.utf8) + Data("\n".utf8)
        send(error, to: client.fd)
        client.pending.removeAll()
        client.buffer.removeAll()
        drop(client.fd)
    }

    private func drain(_ client: Client) {
        guard !client.busy, !client.pending.isEmpty else { return }
        let line = client.pending.removeFirst()
        client.busy = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            let reply = await self.handler(line)
            if let reply, self.clients[client.fd] === client {
                self.send(reply, to: client.fd)
            }
            client.busy = false
            self.drain(client)
        }
    }

    // MARK: Writing and closing

    private func send(_ data: Data, to fd: Int32) {
        queue.async { [weak self] in
            let ok = MCPSocketServer.writeAll(fd, data)
            if !ok {
                Task { @MainActor [weak self] in self?.drop(fd) }
            }
        }
    }

    private func drop(_ fd: Int32) {
        guard let client = clients.removeValue(forKey: fd) else { return }
        client.source.cancel()
        clientCount = clients.count
    }

    private nonisolated static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return true }
            var offset = 0
            while offset < raw.count {
                let written = Darwin.write(fd, base.advanced(by: offset), raw.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    if errno == EAGAIN || errno == EWOULDBLOCK {
                        // A screenshot response can be well over a megabyte and
                        // the accepted socket is non-blocking. Wait for room
                        // instead of truncating the line.
                        var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                        if poll(&descriptor, 1, 5000) > 0 { continue }
                    }
                    return false
                }
                guard written > 0 else { return false }
                offset += written
            }
            return true
        }
    }

    private nonisolated static func setNoSIGPIPE(_ fd: Int32) {
        var one: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    }
}

enum MCPServerError: Error, Equatable, LocalizedError {
    case socket(String)
    case pathTooLong(String)

    var errorDescription: String? {
        switch self {
        case .socket(let message): return message
        case .pathTooLong(let path): return "socket path is too long: \(path)"
        }
    }
}
