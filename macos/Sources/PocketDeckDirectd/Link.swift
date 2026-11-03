#if POCKETDECK_DIRECT
import Darwin
import Foundation
import PocketDeckDirectCore
import PDLWIP

/// One bridged TCP connection: the app's socketpair end on one side, one lwIP
/// `tcp_pcb` to the peer's link-local on the other
/// (docs/design/direct-link.md §2.5, item 3 of this round).
///
/// Backpressure both ways, with the same cap in each direction
/// (`DirectLimits.linkBufferBytes`, 512 KiB):
/// - app -> stack: the read filter is dropped once `toStack` passes half the
///   cap, so the app's own socket buffer fills next; nothing grows without
///   bound.
/// - stack -> app: a byte is acknowledged to lwIP (`tcp_recved`) only once it
///   has left `toApp` for the socket, so a slow app closes lwIP's window.
final class Link {
    let id: String
    let peer: String
    let port: UInt16
    let remote: String
    let createdAt = Date()
    private(set) var state: DirectLinkState = .connecting
    private(set) var downSince: Date?
    private(set) var sock: Int32
    private(set) var conn: OpaquePointer?
    private(set) var toStack = Data()
    private(set) var toApp = Data()
    private(set) var reading = true
    private let dialDeadline = Date().addingTimeInterval(TimeInterval(DirectLimits.dialTimeoutSeconds))
    private var released = false
    /// The dial reply is held until lwIP reports the handshake complete.
    var onUp: (() -> Void)?
    var onDown: (() -> Void)?

    init(id: String, peer: String, sock: Int32, port: UInt16, remote: String) {
        self.id = id
        self.peer = peer
        self.sock = sock
        self.port = port
        self.remote = remote
    }

    // MARK: app -> stack

    /// Queues bytes the app wrote. False means the cap was reached; the caller
    /// closes the link rather than buffering without bound.
    func appendFromApp(_ bytes: UnsafeBufferPointer<UInt8>) -> Bool {
        guard toStack.count + bytes.count <= DirectLimits.linkBufferBytes else { return false }
        toStack.append(contentsOf: bytes)
        return true
    }

    func pumpToStack() {
        guard state == .up, let conn, !toStack.isEmpty else {
            updateReading()
            return
        }
        while !toStack.isEmpty {
            let room = Int(pdl_sndbuf(conn))
            if room <= 0 { break }
            let count = min(room, toStack.count, DirectLimits.writeChunkBytes)
            var accepted = 0
            let result = toStack.withUnsafeBytes { raw -> Int32 in
                pdl_write(conn, raw.baseAddress!.assumingMemoryBound(to: UInt8.self),
                          count, &accepted)
            }
            if result < 0 {
                fail(.peerClosed)
                return
            }
            if accepted == 0 { break }
            toStack.removeFirst(accepted)
        }
        pdl_output(conn)
        updateReading()
    }

    private func updateReading() {
        if toStack.count >= DirectLimits.linkBufferBytes / 2 {
            reading = false
        } else if toStack.count < DirectLimits.readChunkBytes * 2 {
            reading = true
        }
    }

    // MARK: stack -> app

    /// Called from lwIP's receive callback. Returns the bytes the socket took;
    /// the rest waits in `toApp` and stays unacknowledged until it moves.
    func receivedFromStack(_ data: UnsafePointer<UInt8>, _ length: Int) -> UInt16 {
        guard state != .down, sock >= 0 else { return 0 }
        // Once anything waits in toApp, every later segment queues behind it.
        // Writing a newer segment straight to the socket would reorder the
        // stream (boot 7's 1 MiB echo read back a block out of place).
        if !toApp.isEmpty {
            guard toApp.count + length <= DirectLimits.linkBufferBytes else {
                DirectLog.line("link \(id) app stopped reading; closing")
                fail(.peerClosed)
                return 0
            }
            toApp.append(Data(bytes: data, count: length))
            return 0
        }
        var sent = 0
        while sent < length {
            let wrote = write(sock, data + sent, length - sent)
            if wrote > 0 {
                sent += wrote
                continue
            }
            if wrote < 0 && errno == EAGAIN { break }
            let error = errno
            DirectLog.line("link \(id) socket write error \(error)")
            fail(.peerClosed)
            return UInt16(min(sent, Int(UInt16.max)))
        }
        if sent < length {
            let rest = length - sent
            if toApp.count + rest > DirectLimits.linkBufferBytes {
                DirectLog.line("link \(id) app stopped reading; closing")
                fail(.peerClosed)
                return UInt16(min(sent, Int(UInt16.max)))
            }
            toApp.append(Data(bytes: data + sent, count: rest))
        }
        return UInt16(min(sent, Int(UInt16.max)))
    }

    /// The socket is writable (or a tick): move queued bytes to the app and
    /// acknowledge exactly those to lwIP.
    func flushToApp() {
        guard sock >= 0 else { return }
        var moved = 0
        while !toApp.isEmpty {
            let wrote = toApp.withUnsafeBytes { raw in
                write(sock, raw.baseAddress, raw.count)
            }
            if wrote <= 0 { break }
            toApp.removeFirst(wrote)
            moved += wrote
        }
        guard moved > 0, let conn else { return }
        var left = moved
        while left > 0 {
            let chunk = min(left, Int(UInt16.max))
            pdl_rx_done(conn, UInt16(chunk))
            left -= chunk
        }
    }

    // MARK: events

    /// Stores the C connection pdl_connect returned. Without this the link can
    /// hand out its fd and answer "up" while every pump sees `conn == nil`.
    func attach(_ connection: OpaquePointer) {
        conn = connection
    }

    func connected() {
        guard state == .connecting else {
            transition(.connected)
            return
        }
        transition(.connected)
        DirectLog.line("link \(id) connected in \(Int(Date().timeIntervalSince(createdAt) * 1000)) ms")
        onUp?()
        pumpToStack()
    }

    func sentToStack(free: UInt16) {
        _ = free
        pumpToStack()
    }

    func connectionFailed(code: Int32) {
        DirectLog.line("link \(id) connect failed (\(code))")
        fail(.connectFailed)
    }

    func closeByApp() {
        guard state != .down else { return }
        if let conn {
            pdl_close(conn)
        }
        transition(.appClosed)
        DirectLog.line("link \(id) closed by the app")
        pumpToStack()
    }

    func fail(_ event: DirectLinkEvent) {
        transition(event)
    }

    /// Dial timeout, checked from the daemon's 200 ms tick.
    func expired() -> Bool {
        state == .connecting && Date() > dialDeadline
    }

    func timeOut() {
        guard state == .connecting else { return }
        if let conn {
            pdl_close(conn)
        }
        transition(.connectFailed)
        DirectLog.line("link \(id) dial timed out after \(DirectLimits.dialTimeoutSeconds) s")
    }

    /// Frees the C record once the daemon is outside any lwIP callback.
    func releaseConnection() {
        guard let conn, !released else { return }
        released = true
        pdl_release(conn)
        self.conn = nil
    }

    private func transition(_ event: DirectLinkEvent) {
        let (next, actions) = DirectLinkMachine.step(state, event)
        DirectLog.line(DirectLinkMachine.describe(state, event, next))
        state = next
        if next == .down {
            downSince = downSince ?? Date()
        }
        for action in actions {
            switch action {
            case .closeAppSocket:
                if sock >= 0 {
                    shutdown(sock, SHUT_RDWR)
                    close(sock)
                    sock = -1
                }
            case .stopReadingApp:
                reading = false
            }
        }
        if next == .down {
            onDown?()
        }
    }
}
#endif
