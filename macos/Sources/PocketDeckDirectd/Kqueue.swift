#if POCKETDECK_DIRECT
import Darwin
import Foundation

/// `kevent` is both the C struct and the syscall; the alias keeps the struct
/// usable in type position.
typealias KEvent = kevent

/// The syscall; inside this file `kevent` alone is ambiguous with the struct.
private func sysKevent(_ kq: Int32, _ changes: UnsafePointer<KEvent>?, _ count: Int32,
                       _ events: UnsafeMutablePointer<KEvent>?, _ capacity: Int32,
                       _ timeout: UnsafePointer<timespec>?) -> Int32 {
    kevent(kq, changes, count, events, capacity, timeout)
}

/// A small level-triggered kqueue wrapper. The daemon rebuilds the wanted
/// filter set every turn and this diffs it, so a filter that no longer
/// applies is removed instead of firing forever.
final class Kqueue {
    private let handle: Int32
    private var reads: Set<Int32> = []
    private var writes: Set<Int32> = []

    init() throws {
        handle = kqueue()
        guard handle >= 0 else { throw POSIXError(.ENOMEM) }
    }

    deinit {
        close(handle)
    }

    /// One ready fd. `write` says which filter fired.
    struct Ready {
        let fd: Int32
        let write: Bool
    }

    func wait(wantReads: Set<Int32>, wantWrites: Set<Int32>,
              timeoutMilliseconds: Int) throws -> [Ready] {
        var changes: [KEvent] = []
        for fd in wantReads where !reads.contains(fd) {
            changes.append(makeChange(fd: fd, filter: Int16(EVFILT_READ),
                                      flags: UInt16(EV_ADD | EV_ENABLE)))
            reads.insert(fd)
        }
        for fd in reads where !wantReads.contains(fd) {
            changes.append(makeChange(fd: fd, filter: Int16(EVFILT_READ),
                                      flags: UInt16(EV_DELETE)))
        }
        reads = wantReads
        for fd in wantWrites where !writes.contains(fd) {
            // One-shot: a writable socket stays writable, so a persistent
            // EVFILT_WRITE would spin. The next turn re-adds it if needed.
            changes.append(makeChange(fd: fd, filter: Int16(EVFILT_WRITE),
                                      flags: UInt16(EV_ADD | EV_ENABLE | EV_ONESHOT)))
        }
        for fd in writes where !wantWrites.contains(fd) {
            changes.append(makeChange(fd: fd, filter: Int16(EVFILT_WRITE),
                                      flags: UInt16(EV_DELETE)))
        }
        writes = wantWrites

        var events = [KEvent](repeating: KEvent(ident: 0, filter: 0, flags: 0,
                                                fflags: 0, data: 0, udata: nil),
                              count: 64)
        var timeout = timespec(tv_sec: timeoutMilliseconds / 1000,
                               tv_nsec: (timeoutMilliseconds % 1000) * 1_000_000)
        let raw = changes.withUnsafeBufferPointer { buffer -> Int32 in
            events.withUnsafeMutableBufferPointer { output -> Int32 in
                sysKevent(handle, buffer.baseAddress, Int32(buffer.count),
                          output.baseAddress, Int32(output.count), &timeout)
            }
        }
        let count = Int(raw)
        if count < 0 {
            // ENOENT: a fd closed since the last turn took its filters with
            // it. Forget the bookkeeping and let the next turn rebuild.
            if errno == ENOENT {
                reads = []
                writes = []
                return []
            }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        var ready: [Ready] = []
        for index in 0..<count {
            let event = events[index]
            let isWrite = event.filter == Int16(EVFILT_WRITE)
            // A one-shot write filter went with the event: forget it so the
            // next turn can re-add it while data is still pending.
            if isWrite { writes.remove(Int32(event.ident)) }
            ready.append(Ready(fd: Int32(event.ident), write: isWrite))
        }
        return ready
    }

    /// A fd this loop closed: its filters are gone with it.
    func forget(fd: Int32) {
        reads.remove(fd)
        writes.remove(fd)
    }

    private func makeChange(fd: Int32, filter: Int16, flags: UInt16) -> KEvent {
        KEvent(ident: UInt(fd), filter: filter, flags: flags,
               fflags: 0, data: 0, udata: nil)
    }
}
#endif
