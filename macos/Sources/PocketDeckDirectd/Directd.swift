#if POCKETDECK_DIRECT
import Darwin
import Foundation
import PocketDeckDirectCore
import PDLWIP
import SystemConfiguration

// The direct-link helper: one kevent loop over its UNIX socket, its clients,
// one BPF descriptor and the links' socketpair ends (docs/design/direct-link.md
// §2.1–§2.5). One owner of the stack, so there are no locks in the datapath.

/// Set by the SIGTERM handler; the loop notices within one 200 ms tick, prints
/// lwIP's counters and exits, so the VM check gets them without a second run.
private var directTerminateRequested = false

struct DirectConfig {
    var interface: String
    var socketPath: String
    var testMode: Bool
    var sharedAddress: Bool

    static func fromEnvironment() -> DirectConfig {
        let env = ProcessInfo.processInfo.environment
        return DirectConfig(
            interface: env["POCKETDECK_DIRECT_IF"] ?? "nan0",
            socketPath: env["POCKETDECK_DIRECT_SOCK"] ?? "/var/run/pocketdeck-directd.sock",
            testMode: env["POCKETDECK_DIRECT_TEST"] == "1",
            sharedAddress: env["POCKETDECK_DIRECT_LL"] == "shared"
        )
    }
}

enum DaemonError: Error, CustomStringConvertible {
    case noConsoleUser
    case noInterface(String)
    case noBPF(String)
    case noStack
    case pathTooLong(String)
    case socket(Int32)
    case arguments(String)

    var description: String {
        switch self {
        case .noConsoleUser: return "no console user (the helper needs a logged-in session)"
        case .noInterface(let name): return "no interface \(name) or it has no MAC"
        case .noBPF(let name): return "no /dev/bpf* could be bound to \(name)"
        case .noStack: return "lwIP could not start"
        case .pathTooLong(let path): return "socket path too long: \(path)"
        case .socket(let code): return "socket: \(String(cString: strerror(code)))"
        case .arguments(let text): return text
        }
    }
}

final class DirectDaemon {
    let config: DirectConfig
    private let kqueue: Kqueue
    private let listenFD: Int32
    private let bpfFD: Int32
    private let stack: OpaquePointer
    private let ownMAC: [UInt8]
    private let consoleUID: UInt32
    private let consoleGID: UInt32
    private var clients: [Int32: Client] = [:]
    private var links: [String: Link] = [:]
    private var peerSpec: DirectPeerSpec?
    private var peerMAC: [UInt8] = []
    private var peerLL: [UInt8] = []
    private var routeInstalled = false

    private final class Client {
        let fd: Int32
        var framer = DirectLineFramer()
        var out = Data()
        init(fd: Int32) { self.fd = fd }
    }

    enum Event {
        case listen
        case bpf
        case client(Int32)
        case linkRead(String)
        case linkWrite(String)
    }

    // MARK: lifetime

    init(config: DirectConfig) throws {
        self.config = config
        signal(SIGPIPE, SIG_IGN)
        signal(SIGTERM) { _ in directTerminateRequested = true }

        guard let console = DirectDaemon.consoleUser() else {
            throw DaemonError.noConsoleUser
        }
        consoleUID = console.uid
        consoleGID = console.gid

        var mac = [UInt8](repeating: 0, count: 6)
        guard pdl_if_mac(config.interface, &mac) == 0 else {
            throw DaemonError.noInterface(config.interface)
        }
        ownMAC = mac

        let opened = config.interface.withCString { pdl_bpf_open($0) }
        guard opened >= 0 else { throw DaemonError.noBPF(config.interface) }
        bpfFD = opened
        guard let created = pdl_new(bpfFD, ownMAC) else {
            close(opened)
            throw DaemonError.noStack
        }
        stack = created

        let address = DirectDaemon.localAddress(config: config, mac: ownMAC)
        guard pdl_start(stack, address, 1) == 0 else {
            close(opened)
            throw DaemonError.noStack
        }
        DirectLog.line("stack up on \(config.interface) mac \(hex(ownMAC))"
            + " ll \(IPv6Address.format(address))"
            + (config.sharedAddress ? " (shared with the kernel)" : ""))

        kqueue = try Kqueue()
        listenFD = try DirectDaemon.listen(at: config.socketPath, group: consoleGID)
    }

    deinit {
        close(listenFD)
        close(bpfFD)
        for fd in clients.keys { close(fd) }
    }

    /// `shared` puts lwIP on the kernel's own link-local (the experiment §7.1
    /// asks for); the default derives a distinct address from the MAC and
    /// announces it, so the kernel never sees traffic for an address it owns.
    private static func localAddress(config: DirectConfig, mac: [UInt8]) -> [UInt8] {
        if config.sharedAddress {
            var kernel = [UInt8](repeating: 0, count: 16)
            if pdl_if_linklocal(config.interface, &kernel) == 0 {
                return kernel
            }
            DirectLog.line("no kernel link-local on \(config.interface); using the derived one")
        }
        // EUI-64 from the MAC with its last byte moved, so the address cannot
        // equal the kernel's own fe80:: on the same interface.
        return [0xfe, 0x80, 0, 0, 0, 0, 0, 0,
                mac[0] ^ 0x02, mac[1], mac[2], 0xff, 0xfe, mac[3], mac[4], mac[5] ^ 0xa5]
    }

    private static func consoleUser() -> (uid: UInt32, gid: UInt32)? {
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard let name = SCDynamicStoreCopyConsoleUser(nil, &uid, &gid) else {
            return nil
        }
        _ = name
        return (UInt32(uid), UInt32(gid))
    }

    /// The socket is `0660 root:<console user's group>` (§2.1). The daemon
    /// runs as root, so a socket created in a directory without the setgid bit
    /// would otherwise land in root:wheel, and the console user (staff) could
    /// not connect — boot 4 answered every connect() with EACCES.
    private static func listen(at path: String, group: UInt32) throws -> Int32 {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let pathBytes = Array(path.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            throw DaemonError.pathTooLong(path)
        }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: pathBytes)
        }
        // The last daemon may have left its socket; only a socket file is
        // removed, and it is ours by name.
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw DaemonError.socket(errno) }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else {
            close(fd)
            throw DaemonError.socket(errno)
        }
        _ = chown(path, 0, group)
        _ = chmod(path, 0o660)
        guard Darwin.listen(fd, 8) == 0 else {
            close(fd)
            throw DaemonError.socket(errno)
        }
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        DirectLog.line("listening on \(path)")
        return fd
    }

    // MARK: the loop

    /// 200 ms tick for lwIP's timers, then whatever is ready.
    func run() {
        while !directTerminateRequested {
            let wanted = wantedFilters()
            let ready: [Kqueue.Ready]
            do {
                ready = try kqueue.wait(wantReads: wanted.reads, wantWrites: wanted.writes,
                                        timeoutMilliseconds: 200)
            } catch {
                DirectLog.line("kevent: \(error)")
                ready = []
            }
            for one in ready {
                dispatch(fd: one.fd, write: one.write)
            }
            transfer()
            pdl_poll(stack)
            expire()
        }
        pdl_print_stats(stack)
        DirectLog.line("stopping on SIGTERM")
    }

    private func wantedFilters() -> (reads: Set<Int32>, writes: Set<Int32>) {
        var reads: Set<Int32> = [listenFD, bpfFD]
        var writes: Set<Int32> = []
        for (fd, client) in clients {
            reads.insert(fd)
            if !client.out.isEmpty { writes.insert(fd) }
        }
        for link in links.values where link.sock >= 0 {
            if link.reading { reads.insert(link.sock) }
            if !link.toApp.isEmpty { writes.insert(link.sock) }
        }
        return (reads, writes)
    }

    private func dispatch(fd: Int32, write: Bool) {
        if fd == listenFD && !write {
            acceptClients()
            return
        }
        if fd == bpfFD && !write {
            readBPF()
            return
        }
        if clients[fd] != nil {
            serviceClient(fd)
            return
        }
        if let id = links.first(where: { $0.value.sock == fd })?.key, let link = links[id] {
            if write {
                link.flushToApp()
            } else if link.reading {
                linkRead(link)
            }
        }
    }

    /// Pushes whatever became writable while the loop was inside lwIP (the
    /// sent callback covers most of it; this is the tick's safety net).
    private func transfer() {
        for link in links.values {
            link.pumpToStack()
        }
    }

    // MARK: BPF

    private func readBPF() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        _ = pdl_bpf_read(bpfFD, directFrameCallback, context)
    }

    fileprivate func frameReceived(_ frame: UnsafePointer<UInt8>, _ length: Int) {
        guard length >= 14 else { return }
        let destination = frame
        let multicast = destination[0] & 0x01 != 0
        guard multicast || (0..<6).allSatisfy({ destination[$0] == ownMAC[$0] }) else {
            return
        }
        pdl_input(stack, frame, length)
    }

    // MARK: clients

    private func acceptClients() {
        while true {
            let fd = accept(listenFD, nil, nil)
            if fd < 0 { return }
            var uid: uid_t = 0
            var gid: gid_t = 0
            let peerOK = getpeereid(fd, &uid, &gid) == 0
                && directPeerAllowed(peerUID: UInt32(uid), consoleUID: consoleUID)
            guard peerOK else {
                // §2.5: answer, then close without reading a request.
                var reply = DirectReply.error(.notConsoleUser,
                                              message: "not the console user").encoded()
                reply.append(0x0A)
                reply.withUnsafeBytes { raw in
                    _ = write(fd, raw.baseAddress, raw.count)
                }
                close(fd)
                DirectLog.line("client refused: uid mismatch")
                continue
            }
            _ = fcntl(fd, F_SETFL, O_NONBLOCK)
            clients[fd] = Client(fd: fd)
            DirectLog.line("client connected")
        }
    }

    private func serviceClient(_ fd: Int32) {
        guard let client = clients[fd] else { return }
        var buffer = [UInt8](repeating: 0, count: 4096)
        let got = read(fd, &buffer, buffer.count)
        if got == 0 {
            closeClient(fd)
            return
        }
        if got < 0 {
            if errno == EAGAIN { return }
            closeClient(fd)
            return
        }
        let lines: [Data]
        do {
            lines = try client.framer.append(Data(buffer[0..<got]))
        } catch {
            sendReply(.error(.badRequest, message: "request line too long"), to: client)
            closeClient(fd)
            return
        }
        for line in lines {
            handle(line, from: client)
        }
        flush(client)
    }

    private func closeClient(_ fd: Int32) {
        kqueue.forget(fd: fd)
        close(fd)
        clients[fd] = nil
    }

    private func sendReply(_ reply: DirectReply, to client: Client, fd pass: Int32? = nil) {
        var payload = reply.encoded()
        payload.append(0x0A)
        if let pass, !sendWithFD(client.fd, payload: payload, pass: pass) {
            DirectLog.line("sendmsg failed for a dial reply")
        } else if pass == nil {
            client.out.append(payload)
        }
    }

    private func flush(_ client: Client) {
        while !client.out.isEmpty {
            let wrote = client.out.withUnsafeBytes { raw in
                write(client.fd, raw.baseAddress, raw.count)
            }
            if wrote <= 0 { break }
            client.out.removeFirst(wrote)
        }
        if client.out.count > 64 * 1024 {
            DirectLog.line("client is not reading; closing it")
            closeClient(client.fd)
        }
    }

    private func sendWithFD(_ socket: Int32, payload: Data, pass: Int32) -> Bool {
        payload.withUnsafeBytes { raw in
            var iov = iovec(iov_base: UnsafeMutableRawPointer(mutating: raw.baseAddress),
                            iov_len: raw.count)
            let controlSize = MemoryLayout<cmsghdr>.size + MemoryLayout<Int32>.size
            var control = [UInt8](repeating: 0, count: controlSize)
            control.withUnsafeMutableBytes { ctl in
                let header = ctl.baseAddress!.bindMemory(to: cmsghdr.self, capacity: 1)
                header.pointee.cmsg_len = socklen_t(controlSize)
                header.pointee.cmsg_level = SOL_SOCKET
                header.pointee.cmsg_type = SCM_RIGHTS
                UnsafeMutableRawPointer(header)
                    .advanced(by: MemoryLayout<cmsghdr>.size)
                    .storeBytes(of: pass, as: Int32.self)
            }
            var message = msghdr()
            withUnsafeMutablePointer(to: &iov) { pointer in
                message.msg_iov = pointer
            }
            message.msg_iovlen = 1
            return control.withUnsafeMutableBytes { ctl in
                message.msg_control = ctl.baseAddress
                message.msg_controllen = socklen_t(ctl.count)
                return sendmsg(socket, &message, 0) == raw.count
            }
        }
    }

    // MARK: requests

    private func handle(_ line: Data, from client: Client) {
        let request: DirectRequest
        do {
            request = try DirectRequestParser.parse(line)
        } catch let error as DirectRequestError {
            sendReply(.error(error.code, message: error.message), to: client)
            return
        } catch {
            sendReply(.error(.badRequest, message: "malformed request"), to: client)
            return
        }
        switch request {
        case .hello:
            // No NAN toolkit in this round: hello tells the truth about it.
            sendReply(.hello(version: 1, dataLinks: DirectLimits.maxLinks), to: client)
        case .probe:
            sendReply(.probe(ready: false,
                             codes: ["probe_unimplemented"],
                             detail: "the radio probe lands with the NAN session (round 2)"),
                      to: client)
        case .peer(let spec):
            guard config.testMode else {
                sendReply(.error(.notReady, message: "peer is a test-only request"), to: client)
                return
            }
            guard let mac = hexBytes(spec.mac), let ll = IPv6Address.parse(spec.linkLocal) else {
                sendReply(.error(.badRequest, message: "bad peer address"), to: client)
                return
            }
            peerSpec = spec
            peerMAC = mac
            peerLL = ll
            pdl_set_peer(stack, ll, mac)
            DirectLog.line("peer \(spec.interface) mac \(hex(mac)) ll \(IPv6Address.format(ll))")
            sendReply(.ok, to: client)
        case .dial(let port):
            dial(port: port, from: client)
        case .close(let id):
            if let link = links[id] {
                link.closeByApp()
                sendReply(.ok, to: client)
            } else {
                sendReply(.error(.linkUnknown, message: "no such link"), to: client)
            }
        case .links:
            let reports = links.values
                .sorted { $0.createdAt < $1.createdAt }
                .map { DirectLinkReport(link: $0.id, peer: $0.peer,
                                        state: $0.state.rawValue) }
            sendReply(.links(reports), to: client)
        case .stats:
            guard config.testMode else {
                sendReply(.error(.notReady, message: "stats is a test-only request"), to: client)
                return
            }
            pdl_print_stats(stack)
            sendReply(.ok, to: client)
        }
    }

    private func dial(port: UInt16, from client: Client) {
        guard let spec = peerSpec, peerLL.count == 16, peerMAC.count == 6 else {
            sendReply(.error(.notReady, message: "no peer set"), to: client)
            return
        }
        guard links.count < DirectLimits.maxLinks else {
            sendReply(.error(.tooManyLinks, message: "too many links"), to: client)
            return
        }
        ensureRoute()
        var pair: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else {
            sendReply(.error(.busy, message: "socketpair failed"), to: client)
            return
        }
        let appEnd = pair[0]
        let helperEnd = pair[1]
        _ = fcntl(helperEnd, F_SETFL, O_NONBLOCK)
        _ = setsockopt(helperEnd, SOL_SOCKET, SO_NOSIGPIPE, [1], 4)
        let id = DirectDaemon.randomLinkID()
        let link = Link(id: id, peer: hex(peerMAC), sock: helperEnd,
                        port: port, remote: spec.linkLocal)
        links[id] = link
        DirectLog.line("link \(id) dialing \(spec.linkLocal) port \(port)")

        // Exactly one answer, and only when lwIP has completed the handshake.
        // `tcp_connect` returning means the SYN is queued, not that the link
        // is up; boot 5 answered success 0 ms after the request.
        var answered = false
        link.onUp = { [weak self] in
            guard !answered else { return }
            answered = true
            guard let self, self.clients[client.fd] === client else {
                close(appEnd)
                link.closeByApp()
                return
            }
            self.sendReply(.dial(link: id, mtu: Int(pdl_mtu())), to: client, fd: appEnd)
            close(appEnd)
        }
        link.onDown = { [weak self] in
            if !answered {
                answered = true
                if let self, self.clients[client.fd] === client {
                    self.sendReply(.error(.connectFailed,
                                          message: "the peer did not complete the TCP handshake"),
                                   to: client)
                }
                close(appEnd)
            }
            self?.linkWentDown()
        }
        let connection = withExtendedLifetime(link) {
            pdl_connect(stack, peerLL, port, Unmanaged.passUnretained(link).toOpaque(),
                        directConnectedCallback, directRecvCallback, directSentCallback,
                        directErrorCallback)
        }
        guard let connection else {
            // pdl_connect may already have run the error callback; fail() is
            // idempotent once the link is down.
            link.fail(.connectFailed)
            link.releaseConnection()
            links[id] = nil
            close(helperEnd)
            if !answered {
                close(appEnd)
                sendReply(.error(.ndpRefused, message: "no TCP control block"), to: client)
            }
            return
        }
        link.attach(connection)
    }

    private static func randomLinkID() -> String {
        var bytes = [UInt8](repeating: 0, count: 8)
        arc4random_buf(&bytes, bytes.count)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: links

    fileprivate func linkRead(_ link: Link) {
        var buffer = [UInt8](repeating: 0, count: DirectLimits.readChunkBytes)
        let got = read(link.sock, &buffer, buffer.count)
        if got == 0 {
            DirectLog.line("link \(link.id) app closed")
            link.closeByApp()
            return
        }
        if got < 0 {
            if errno == EAGAIN { return }
            DirectLog.line("link \(link.id) app read error \(errno)")
            link.closeByApp()
            return
        }
        let accepted = buffer[0..<got].withUnsafeBufferPointer { link.appendFromApp($0) }
        guard accepted else {
            DirectLog.line("link \(link.id) app outran the stack; closing")
            link.fail(.appClosed)
            return
        }
        link.pumpToStack()
    }

    fileprivate func linkWentDown() {
        if routeInstalled && !links.values.contains(where: { $0.state == .up }) {
            dropRoute()
        }
    }

    /// Removes links that ended long enough ago for `links` to have shown the
    /// state, and keeps the down records for 30 s (§7.2's 5 s bound is about
    /// seeing `down`, not about forgetting it at once).
    private func expire() {
        for (id, link) in links {
            if link.expired() {
                link.timeOut()
            }
            guard link.state == .down else { continue }
            link.releaseConnection()
            if let since = link.downSince, Date().timeIntervalSince(since) > 30 {
                if link.sock >= 0 {
                    kqueue.forget(fd: link.sock)
                }
                links[id] = nil
            }
        }
    }

    // MARK: the per-peer route (§2.4)

    private func ensureRoute() {
        guard !routeInstalled, peerLL.count == 16 else { return }
        routeInstalled = runRoute("add")
    }

    private func dropRoute() {
        guard routeInstalled else { return }
        _ = runRoute("delete")
        routeInstalled = false
    }

    private func runRoute(_ action: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/sbin/route")
        process.arguments = ["-n", action, "-inet6", IPv6Address.format(peerLL),
                             "-interface", config.interface]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            DirectLog.line("route \(action) could not run")
            return false
        }
        let ok = process.terminationStatus == 0
        DirectLog.line("route \(action) \(IPv6Address.format(peerLL)) \(ok ? "ok" : "failed")")
        return ok
    }
}

// MARK: - C callbacks (same thread, inside the loop)

private func directFrameCallback(_ context: UnsafeMutableRawPointer?,
                                 _ frame: UnsafePointer<UInt8>?,
                                 _ length: Int) {
    guard let context, let frame else { return }
    Unmanaged<DirectDaemon>.fromOpaque(context).takeUnretainedValue()
        .frameReceived(frame, length)
}

private func directConnectedCallback(_ context: UnsafeMutableRawPointer?) {
    guard let context else { return }
    Unmanaged<Link>.fromOpaque(context).takeUnretainedValue().connected()
}

private func directRecvCallback(_ context: UnsafeMutableRawPointer?,
                                _ data: UnsafePointer<UInt8>?,
                                _ length: UInt16) -> UInt16 {
    guard let context, let data else { return 0 }
    return Unmanaged<Link>.fromOpaque(context).takeUnretainedValue()
        .receivedFromStack(data, Int(length))
}

private func directSentCallback(_ context: UnsafeMutableRawPointer?, _ free: UInt16) {
    guard let context else { return }
    Unmanaged<Link>.fromOpaque(context).takeUnretainedValue().sentToStack(free: free)
}

private func directErrorCallback(_ context: UnsafeMutableRawPointer?, _ code: Int32) {
    guard let context else { return }
    Unmanaged<Link>.fromOpaque(context).takeUnretainedValue().connectionFailed(code: code)
}

private func hex(_ bytes: [UInt8]) -> String {
    bytes.map { String(format: "%02x", $0) }.joined()
}

private func hexBytes(_ text: String) -> [UInt8]? {
    let parts = text.split(separator: ":")
    guard parts.count == 6 else { return nil }
    var out: [UInt8] = []
    for part in parts {
        guard part.count == 2, let value = UInt8(part, radix: 16) else { return nil }
        out.append(value)
    }
    return out
}
#endif
