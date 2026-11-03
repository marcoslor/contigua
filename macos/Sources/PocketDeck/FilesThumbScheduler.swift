// The extension's thumbnails, and only its thumbnails: every Finder batch is
// handed here, the asks run through one pool, every id gets at most one
// answer, and every batch exactly one completion, after its answers. A
// cancelled batch completes at once with NSUserCancelledError, which covers
// the ids still in flight (the header's rule; docs/specs/files.md FILES-22,
// FILES-25, FILES-26, FILES-29).
//
// The type knows nothing about sockets or File Provider errors: `start` is the
// ask (the extension wraps its bridge connection in it) and `per`/`done` are
// Finder's own handlers. That is the seam the K2 checks drive with a fake
// phone. It is compiled into both the app (K2) and Files.appex (bundle.sh).

import Foundation

final class FilesThumbScheduler {
    /// Starts one item's ask and calls `completion` exactly once. `isCancelled`
    /// is the batch's own flag: an in-flight ask checks it between frames and
    /// stops the way it always has (one `fs.cancel`, then a nil answer).
    typealias Start = (_ item: String,
                       _ isCancelled: @escaping () -> Bool,
                       _ completion: @escaping (_ data: Data?, _ error: Error?) -> Void) -> Void
    typealias PerThumbnail = (_ item: String, _ data: Data?, _ error: Error?) -> Void
    typealias Done = (Error?) -> Void

    /// The File Provider headers' word for a cancelled operation
    /// (NSFileProviderReplicatedExtension.h, "Cancellations": the completion
    /// handler takes NSUserCancelledError). It is not a thumbnail failure: it
    /// means nobody is waiting for this picture any more.
    static var cancelledError: Error {
        NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError)
    }

    /// One Finder batch. Reference type: an ask's completion closes over it and
    /// must mutate this batch, not a copy in the scheduler's array.
    private final class Batch {
        let id: Int
        let items: [String]
        let start: Start
        let per: PerThumbnail
        let done: Done
        var next = 0
        var running = 0
        var answered = 0
        var cancelled = false
        var completed = false
        /// Serialises Finder's handlers for this batch: no `per` may follow
        /// `done` (the header: `completionHandler` only after every per
        /// thumbnail block), even when a cancel races a late answer.
        let deliveryLock = NSLock()
        var doneSent = false

        init(id: Int, items: [String], start: @escaping Start,
             per: @escaping PerThumbnail, done: @escaping Done) {
            self.id = id
            self.items = items
            self.start = start
            self.per = per
            self.done = done
        }
    }

    /// Guards one completion against a `start` that calls back twice.
    private final class Once {
        private let lock = NSLock()
        private var fired = false
        func claim() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if fired { return false }
            fired = true
            return true
        }
    }

    private let lock = NSLock()
    private let limit: Int
    private var batches: [Batch] = []
    private var nextID = 1
    private var running = 0
    private var pumping = false
    private var needsPump = false

    init(limit: Int = FilesThumbPolicy.inFlightLimit) {
        self.limit = limit
    }

    /// Accepts one Finder batch and returns its id (for a later cancel). The
    /// batch starts at once if a slot is free; cancelled ids are answered by
    /// `cancel` without ever reaching `start`.
    @discardableResult
    func open(items: [String], start: @escaping Start,
              per: @escaping PerThumbnail, done: @escaping Done) -> Int {
        lock.lock()
        let id = nextID
        nextID += 1
        lock.unlock()
        guard !items.isEmpty else {
            done(nil)
            return id
        }
        let batch = Batch(id: id, items: items, start: start, per: per, done: done)
        lock.lock()
        batches.append(batch)
        lock.unlock()
        pump()
        return id
    }

    /// Finder's progress was cancelled. The header's rule for
    /// `fetchThumbnails` ("Cancellations"): call the completion handler with
    /// `NSUserCancelledError` in the cancellation handler, quickly, and
    /// `completionHandler` only after the per-thumbnail blocks it will get.
    /// So every unstarted id is answered with the cancellation error, then the
    /// batch completes with it at once. An ask still in flight stops at its
    /// next frame (one `fs.cancel`); its late answer frees its slot and is
    /// dropped, because the batch is already complete (FILES-25).
    func cancel(_ id: Int) {
        lock.lock()
        guard let batch = batches.first(where: { $0.id == id }),
              !batch.cancelled, !batch.completed else {
            lock.unlock()
            return
        }
        batch.cancelled = true
        batch.completed = true
        let unstarted = Array(batch.items[batch.next...])
        batch.next = batch.items.count
        batch.answered += unstarted.count
        batches.removeAll { $0 === batch }
        lock.unlock()
        let error = Self.cancelledError
        for item in unstarted {
            deliver(batch, item: item, data: nil, error: error)
        }
        complete(batch, error: error)
    }

    /// The NFR's observation point: asks in flight plus every unstarted id of a
    /// live batch. A cancelled batch leaves the set at once (its unstarted ids
    /// are answered) and only its in-flight asks remain.
    var pendingCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return running + batches.reduce(0) { $0 + ($1.items.count - $1.next) }
    }

    private func isCancelled(_ batch: Batch) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return batch.cancelled || batch.completed
    }

    private func pump() {
        lock.lock()
        if pumping {
            // A completion can free a slot while another thread is between two
            // picks; remember to look again instead of losing that turn.
            needsPump = true
            lock.unlock()
            return
        }
        pumping = true
        lock.unlock()
        while true {
            while let (batch, item) = takeNext() {
                startOne(batch, item: item)
            }
            lock.lock()
            if needsPump {
                needsPump = false
                lock.unlock()
                continue
            }
            pumping = false
            lock.unlock()
            return
        }
    }

    /// The next ask: newest live batch first, index order within it. Nil while
    /// the pool is full or nothing is left.
    private func takeNext() -> (Batch, String)? {
        lock.lock()
        defer { lock.unlock() }
        guard running < limit else { return nil }
        for batch in batches.reversed() where !batch.cancelled && !batch.completed {
            guard batch.next < batch.items.count else { continue }
            let item = batch.items[batch.next]
            batch.next += 1
            batch.running += 1
            running += 1
            return (batch, item)
        }
        return nil
    }

    private func startOne(_ batch: Batch, item: String) {
        let once = Once()
        batch.start(item, { [weak self] in self?.isCancelled(batch) ?? true }) { [weak self] data, error in
            guard once.claim() else { return }
            self?.finish(batch, item: item, data: data, error: error)
        }
    }

    private func finish(_ batch: Batch, item: String, data: Data?, error: Error?) {
        lock.lock()
        // The slot is the pool's whatever became of the batch: a cancelled
        // batch's late answer must still free it.
        batch.running -= 1
        running -= 1
        guard !batch.completed else {
            lock.unlock()
            pump()
            return
        }
        batch.answered += 1
        let complete = batch.answered == batch.items.count
        if complete {
            batch.completed = true
            batches.removeAll { $0 === batch }
        }
        lock.unlock()
        deliver(batch, item: item, data: data, error: error)
        if complete { self.complete(batch, error: nil) }
        pump()
    }

    /// One per-thumbnail answer, unless the batch has already completed.
    private func deliver(_ batch: Batch, item: String, data: Data?, error: Error?) {
        batch.deliveryLock.lock()
        defer { batch.deliveryLock.unlock() }
        guard !batch.doneSent else { return }
        batch.per(item, data, error)
    }

    /// The batch's one completion.
    private func complete(_ batch: Batch, error: Error?) {
        batch.deliveryLock.lock()
        defer { batch.deliveryLock.unlock() }
        guard !batch.doneSent else { return }
        batch.doneSent = true
        batch.done(error)
    }
}
