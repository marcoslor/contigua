#if POCKETDECK_DIRECT
import Darwin
import Foundation

/// One connection to the helper's UNIX socket: line JSON in, line JSON plus an
/// optional descriptor out (docs/design/direct-link.md §2.5). The fd arrives
/// with `SCM_RIGHTS` on the same `recvmsg` as the `dial` reply.
final class HelperClient {
    private let fd: Int32
    private var buffer = Data()
    private var pendingFD: Int32?

    init(path: String) throws {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            throw DirectE2EError.message("helper socket path too long")
        }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        let socketFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard socketFD >= 0 else {
            throw DirectE2EError.message("socket: \(String(cString: strerror(errno)))")
        }
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(socketFD, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            let code = errno
            close(socketFD)
            throw DirectE2EError.message("connect \(path): \(String(cString: strerror(code)))")
        }
        var timeout = timeval(tv_sec: 30, tv_usec: 0)
        _ = setsockopt(socketFD, SOL_SOCKET, SO_RCVTIMEO, &timeout,
                       socklen_t(MemoryLayout<timeval>.size))
        fd = socketFD
    }

    deinit {
        close(fd)
    }

    func takeReceivedFD() -> Int32? {
        defer { pendingFD = nil }
        return pendingFD
    }

    func call(_ object: [String: Any]) throws -> [String: Any] {
        let payload = try JSONSerialization.data(withJSONObject: object)
        var line = payload
        line.append(0x0A)
        var sent = 0
        try line.withUnsafeBytes { raw in
            while sent < raw.count {
                let wrote = write(fd, raw.baseAddress!.advanced(by: sent), raw.count - sent)
                if wrote > 0 { sent += wrote; continue }
                if wrote < 0 && errno == EINTR { continue }
                throw DirectE2EError.message("helper write: \(String(cString: strerror(errno)))")
            }
        }
        let reply = try receiveLine()
        guard let json = try? JSONSerialization.jsonObject(with: reply) as? [String: Any] else {
            throw DirectE2EError.message("helper reply is not JSON")
        }
        return json
    }

    private func receiveLine() throws -> Data {
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<newline]
                buffer = buffer[buffer.index(after: newline)...]
                return Data(line)
            }
            var chunk = [UInt8](repeating: 0, count: 4096)
            var control = [UInt8](repeating: 0, count: 256)
            var received = -1
            var failure: Int32 = 0
            var captured: Int32?
            chunk.withUnsafeMutableBytes { chunkRaw in
                control.withUnsafeMutableBytes { controlRaw in
                    var iov = iovec(iov_base: chunkRaw.baseAddress, iov_len: chunkRaw.count)
                    var message = msghdr()
                    withUnsafeMutablePointer(to: &iov) { message.msg_iov = $0 }
                    message.msg_iovlen = 1
                    message.msg_control = controlRaw.baseAddress
                    message.msg_controllen = socklen_t(controlRaw.count)
                    received = recvmsg(fd, &message, 0)
                    failure = errno
                    guard received > 0 else { return }
                    var offset = 0
                    while offset + MemoryLayout<cmsghdr>.size <= Int(message.msg_controllen) {
                        let base = controlRaw.baseAddress!.advanced(by: offset)
                        let header: cmsghdr = base.loadUnaligned(as: cmsghdr.self)
                        if header.cmsg_level == SOL_SOCKET && header.cmsg_type == SCM_RIGHTS,
                           offset + MemoryLayout<cmsghdr>.size + MemoryLayout<Int32>.size
                            <= Int(message.msg_controllen) {
                            captured = base.advanced(by: MemoryLayout<cmsghdr>.size)
                                .loadUnaligned(as: Int32.self)
                        }
                        let step = (Int(header.cmsg_len) + 3) & ~3
                        if step <= 0 { break }
                        offset += step
                    }
                }
            }
            if received == 0 { throw DirectE2EError.message("helper closed the connection") }
            if received < 0 {
                if failure == EINTR { continue }
                throw DirectE2EError.message("helper read: \(String(cString: strerror(failure)))")
            }
            if let captured {
                if pendingFD != nil { close(pendingFD!) }
                pendingFD = captured
            }
            buffer.append(contentsOf: chunk[0..<received])
        }
    }
}

/// Drives the close-mid-transfer step: write until the peer's close reaches
/// the app, and say how it ended.
struct LinkProbe {
    enum Result: String {
        case broken
        case timedOut
    }

    let fd: Int32

    func writeUntilBroken(deadline: Date) -> Result {
        let chunk = [UInt8](repeating: 0x5a, count: 64 * 1024)
        while Date() < deadline {
            let wrote = write(fd, chunk, chunk.count)
            if wrote > 0 { continue }
            if wrote < 0 && errno == EINTR { continue }
            if wrote < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) { continue }
            return .broken
        }
        return .timedOut
    }
}
#endif
