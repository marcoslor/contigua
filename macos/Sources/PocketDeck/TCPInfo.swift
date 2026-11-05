// X0: what the stream socket's own TCP stack saw. On the Mac the video is one
// TLS-over-TCP connection; a lost segment holds every later byte until its
// resend arrives, and an out-of-order byte is the receiver's trace of such a
// hole. `TCP_CONNECTION_INFO` is a getsockopt on the NIO channel, read here on
// a timer so the 5 s stats line never waits on the channel's event loop.

import Darwin
import Foundation
import NIOCore
import NIOPosix

/// The receiver's TCP state that matters for a hole: smoothed RTT, its
/// variance and the cumulative bytes that arrived after a missing segment.
struct TCPConnectionInfo: Equatable, Sendable {
    var srttMs: Int
    var rttvar: Int
    var rxOutOfOrderBytes: UInt64

    init(srttMs: Int, rttvar: Int, rxOutOfOrderBytes: UInt64) {
        self.srttMs = srttMs
        self.rttvar = rttvar
        self.rxOutOfOrderBytes = rxOutOfOrderBytes
    }

    init(raw: tcp_connection_info) {
        self.init(srttMs: Int(raw.tcpi_srtt), rttvar: Int(raw.tcpi_rttvar),
                  rxOutOfOrderBytes: raw.tcpi_rxoutoforderbytes)
    }
}

/// One session path's reader. It samples every 2 s in a task: a failed read
/// (a closed socket, a refused option) is no measurement, never a crash and
/// never a log line per failure.
final class TCPInfoReader: @unchecked Sendable {
    private static let interval: Duration = .seconds(2)

    private let channel: Channel
    private let lock = NSLock()
    private var latest: TCPConnectionInfo?
    private var sampler: Task<Void, Never>?

    init(channel: Channel) {
        self.channel = channel
        Task { [weak self] in await self?.sample() }
        sampler = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.interval)
                guard let self else { return }
                await self.sample()
            }
        }
    }

    deinit {
        sampler?.cancel()
    }

    /// The latest reading, nil until one succeeded.
    func current() -> TCPConnectionInfo? {
        lock.lock()
        defer { lock.unlock() }
        return latest
    }

    func stop() {
        sampler?.cancel()
        sampler = nil
    }

    private func sample() async {
        guard let provider = channel as? SocketOptionProvider else { return }
        do {
            let raw: tcp_connection_info = try await provider
                .unsafeGetSocketOption(level: IPPROTO_TCP, name: TCP_CONNECTION_INFO)
                .get()
            let info = TCPConnectionInfo(raw: raw)
            lock.lock()
            latest = info
            lock.unlock()
        } catch {
            // The line prints `-` when this path has no reading.
        }
    }
}
