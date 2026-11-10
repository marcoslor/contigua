// One folder's sync job (ISS-37; docs/design/files.md § Sync integrity,
// FILES-31/33/34/35): the phase the folder is in, the one listing walk that is
// running for it, and the one refresh a phone push may owe.
//
// Before this file the lifecycle was a `building` map, a `walks` map and the
// `confirming`/`visiting`/`refreshing`/`refreshAgain`/`repairing` sets: one
// folder could be visiting and refreshing at once and both passes listed it,
// and a confirmation's phase lived in two places. Here every folder has one
// job; the phases are:
//
//   idle → walking → confirming → idle
//                  ↘ repairing ↗
//   idle → refreshing → walking → …
//
// The transition is pure; the host runs the returned actions (start a walk,
// schedule the confirmation or the refresh, apply the delta) and logs one
// `folder: <from> --<event>--> <to>` line per phase change. The inner FilesWalk
// still owns listing/confirming/done and the deletion guards.

import Foundation

struct FolderJob: Equatable {
    /// Who drives the walk in progress.
    enum Owner: Equatable {
        /// The extension's own enumeration (a Finder read).
        case system
        /// The app: a first/re-watch touch, a phone push, a repair or the
        /// reconnect resync.
        case host
    }

    /// One page walk. `machine` decides whether the walk reports or confirms;
    /// `start` is the record when the first page was asked (FILES-31's
    /// write-racing guard); `pages` is what the phone sent so far.
    struct Walk: Equatable {
        var machine: FilesWalk
        var start: [String: FileItem]
        var pages: [String: FileItem]
        var owner: Owner
        /// The session run this walk belongs to: a drop changes it, and a late
        /// page from the old run changes nothing.
        var token: Int
        /// The next page the system's own enumeration will ask for. A page with
        /// another cursor is another extension process's read: served, not
        /// recorded.
        var cursor: String?

        init(recorded: Int, start: [String: FileItem], owner: Owner, token: Int) {
            self.machine = FilesWalk(recorded: recorded)
            self.start = start
            self.pages = [:]
            self.owner = owner
            self.token = token
            self.cursor = nil
        }
    }

    enum State: Equatable {
        /// No walk, no refresh owed.
        case idle
        /// A listing walk is running. `refreshAfter` records a phone push that
        /// arrived while it ran: one refresh follows it.
        case walking(Walk, refreshAfter: Bool)
        /// The walk would delete too much: the confirmation is waiting for its
        /// delay (`waiting`) or running.
        case confirming(Walk, refreshAfter: Bool, waiting: Bool)
        /// A not-found repair's re-list is running.
        case repairing(Walk, refreshAfter: Bool)
        /// A phone push is settling before its refresh walk; `again` records a
        /// second push during the settle (still one walk).
        case refreshing(again: Bool, token: Int)
    }

    enum Event: Equatable {
        /// A folder's first touch in this session (or since its watch expired).
        case visit(recorded: Int, start: [String: FileItem], token: Int)
        /// The phone said the folder moved.
        case refresh(token: Int)
        /// An app pass that is not a touch or a push: the reconnect resync's
        /// relist.
        case hostStart(recorded: Int, start: [String: FileItem], token: Int)
        /// The extension asked for the folder's first page.
        case systemStart(recorded: Int, start: [String: FileItem], token: Int)
        /// The confirmation's delay is over.
        case confirmDue(token: Int)
        /// The refresh's settle is over.
        case refreshDue(token: Int, recorded: Int, start: [String: FileItem])
        /// A thumbnail, read or stat answered `fs_not_found` for an item.
        case notFound(recorded: Int, start: [String: FileItem], token: Int)
        /// The session ended (or the Files switch went off): abandon every pass.
        case dropped
        /// One page of a walk, not its last.
        case page(token: Int, items: [FileItem], next: String)
        /// The walk's last page: the whole listing and its digest.
        case lastPage(token: Int, items: [FileItem], digest: String?,
                      record: [String: FileItem],
                      uploading: Set<String>, uploadNames: Set<String>)
        /// A page failed (an error or a cancel): the walk is incomplete.
        case failedPage(token: Int, record: [String: FileItem], recordDigest: String?,
                        uploading: Set<String>, uploadNames: Set<String>)
    }

    enum Action: Equatable {
        /// Ask the phone for the walk's first page.
        case start
        /// The read is answered without recording it in this job.
        case serveOnly
        /// Re-list once after the host's delay.
        case scheduleConfirm
        /// One refresh after the host's settle.
        case scheduleRefresh
        /// Report this delta and store the record; `dropped` identifiers leave
        /// the record without a deletion (an item the id map moved).
        case report(FilesDelta, listing: [FileItem], digest: String?,
                    dropped: Set<String>)
        case none
    }

    /// The folder's identifier (an `ino:` id, never a path).
    let folder: String
    private(set) var state: State = .idle

    init(folder: String) {
        self.folder = folder
    }

    /// The walk in progress, if any.
    var walk: Walk? {
        switch state {
        case .walking(let walk, _), .confirming(let walk, _, _), .repairing(let walk, _):
            return walk
        case .idle, .refreshing:
            return nil
        }
    }

    /// The token of the system's own walk when this page belongs to it. Nil
    /// means the page is another read: answer it without recording.
    func systemPageToken(_ page: String?) -> Int? {
        guard case .walking(let walk, _) = state, walk.owner == .system else { return nil }
        if let page, walk.cursor != page { return nil }
        return walk.token
    }

    mutating func apply(_ event: Event) -> Action {
        switch (state, event) {
        // MARK: A pass starts
        case (.idle, .visit(let recorded, let start, let token)),
             (.idle, .hostStart(let recorded, let start, let token)):
            state = .walking(Walk(recorded: recorded, start: start, owner: .host, token: token),
                             refreshAfter: false)
            return .start
        case (.idle, .systemStart(let recorded, let start, let token)):
            state = .walking(Walk(recorded: recorded, start: start, owner: .system, token: token),
                             refreshAfter: false)
            return .start
        case (.idle, .refresh(let token)):
            state = .refreshing(again: false, token: token)
            return .scheduleRefresh
        case (.idle, .notFound(let recorded, let start, let token)):
            state = .repairing(Walk(recorded: recorded, start: start, owner: .host, token: token),
                               refreshAfter: false)
            return .start

        // MARK: A pass already runs: a touch or a read changes nothing
        case (.walking, .visit), (.confirming, .visit), (.repairing, .visit),
             (.refreshing, .visit):
            return .none
        case (.walking, .systemStart), (.confirming, .systemStart),
             (.repairing, .systemStart), (.refreshing, .systemStart),
             (.walking, .hostStart), (.confirming, .hostStart),
             (.repairing, .hostStart), (.refreshing, .hostStart):
            // A read while a pass runs: answer it, record nothing.
            return .serveOnly

        // MARK: Phone push during a pass: one refresh after it
        case (.walking(let walk, false), .refresh):
            state = .walking(walk, refreshAfter: true)
            return .none
        case (.confirming(let walk, false, let waiting), .refresh):
            state = .confirming(walk, refreshAfter: true, waiting: waiting)
            return .none
        case (.repairing(let walk, false), .refresh):
            state = .repairing(walk, refreshAfter: true)
            return .none
        case (.walking(_, true), .refresh), (.confirming(_, true, _), .refresh),
             (.repairing(_, true), .refresh):
            return .none
        case (.refreshing(_, let token), .refresh):
            state = .refreshing(again: true, token: token)
            return .none

        // MARK: Not-found repair during a pass: one refresh after it
        case (.walking(let walk, false), .notFound):
            state = .walking(walk, refreshAfter: true)
            return .none
        case (.confirming(let walk, false, let waiting), .notFound):
            state = .confirming(walk, refreshAfter: true, waiting: waiting)
            return .none
        case (.repairing, .notFound):
            // The repair already running is this folder's re-list.
            return .none
        case (.walking(_, true), .notFound), (.confirming(_, true, _), .notFound):
            return .none
        case (.refreshing(_, let token), .notFound):
            state = .refreshing(again: true, token: token)
            return .none

        // MARK: The two timers
        case (.confirming(let walk, let after, true), .confirmDue(let token)):
            guard walk.token == token else { return .none }
            state = .confirming(clear(walk), refreshAfter: after, waiting: false)
            return .start
        case (.refreshing(_, let token), .refreshDue(let due, let recorded, let start)):
            guard token == due else { return .none }
            state = .walking(Walk(recorded: recorded, start: start, owner: .host, token: due),
                             refreshAfter: false)
            return .start

        // MARK: Pages
        case (.walking(let walk, let after), .page(let token, let items, let next)):
            guard walk.token == token else { return .none }
            var nextWalk = walk
            merge(items, into: &nextWalk.pages)
            if nextWalk.owner == .system { nextWalk.cursor = next }
            state = .walking(nextWalk, refreshAfter: after)
            return .none
        case (.confirming(let walk, let after, let waiting), .page(let token, let items, _)):
            guard walk.token == token else { return .none }
            var nextWalk = walk
            merge(items, into: &nextWalk.pages)
            state = .confirming(nextWalk, refreshAfter: after, waiting: waiting)
            return .none
        case (.repairing(let walk, let after), .page(let token, let items, _)):
            guard walk.token == token else { return .none }
            var nextWalk = walk
            merge(items, into: &nextWalk.pages)
            state = .repairing(nextWalk, refreshAfter: after)
            return .none

        // MARK: The last page of a walk
        case (.walking(let walk, let after), .lastPage(let token, let items, let digest,
                                                       let record, let uploading, let uploadNames)):
            guard walk.token == token else { return .none }
            return finish(walk, items: items, digest: digest, record: record,
                          uploading: uploading, uploadNames: uploadNames,
                          refreshAfter: after, phase: .walking)
        case (.confirming(let walk, let after, _), .lastPage(let token, let items, let digest,
                                                             let record, let uploading,
                                                             let uploadNames)):
            guard walk.token == token else { return .none }
            return finish(walk, items: items, digest: digest, record: record,
                          uploading: uploading, uploadNames: uploadNames,
                          refreshAfter: after, phase: .confirming)
        case (.repairing(let walk, let after), .lastPage(let token, let items, let digest,
                                                         let record, let uploading,
                                                         let uploadNames)):
            guard walk.token == token else { return .none }
            return finish(walk, items: items, digest: digest, record: record,
                          uploading: uploading, uploadNames: uploadNames,
                          refreshAfter: after, phase: .repairing)

        // MARK: A walk that ends early
        case (.walking(let walk, let after), .failedPage(let token, let record,
                                                         let recordDigest, _, _)):
            guard walk.token == token else { return .none }
            return fail(walk, record: record, recordDigest: recordDigest,
                        refreshAfter: after, phase: .walking)
        case (.confirming(let walk, let after, _), .failedPage(let token, let record,
                                                               let recordDigest, _, _)):
            guard walk.token == token else { return .none }
            return fail(walk, record: record, recordDigest: recordDigest,
                        refreshAfter: after, phase: .confirming)
        case (.repairing(let walk, let after), .failedPage(let token, let record,
                                                           let recordDigest, _, _)):
            guard walk.token == token else { return .none }
            return fail(walk, record: record, recordDigest: recordDigest,
                        refreshAfter: after, phase: .repairing)

        // MARK: The run ends
        case (_, .dropped):
            state = .idle
            return .none

        // MARK: Events this phase cannot mean
        case (.idle, .confirmDue), (.idle, .refreshDue), (.idle, .page),
             (.idle, .lastPage), (.idle, .failedPage),
             (.walking, .confirmDue), (.walking, .refreshDue),
             (.confirming, .confirmDue), (.confirming, .refreshDue),
             (.repairing, .confirmDue), (.repairing, .refreshDue),
             (.refreshing, .confirmDue), (.refreshing, .page),
             (.refreshing, .lastPage), (.refreshing, .failedPage):
            return .none
        }
    }

    // MARK: The report

    private mutating func finish(_ walk: Walk, items: [FileItem], digest: String?,
                                 record: [String: FileItem], uploading: Set<String>,
                                 uploadNames: Set<String>, refreshAfter: Bool,
                                 phase: Phase) -> Action {
        var finished = walk
        merge(items, into: &finished.pages)
        let listing = Array(finished.pages.values)
        var delta = FilesDiff.delta(old: record, new: listing)
        delta.deleted = delta.deleted.filter { identifier in
            guard let now = record[identifier], let then = walk.start[identifier] else {
                return false
            }
            // A Mac write during the walk already told the system; the listing
            // that was asked before it cannot delete the item.
            if now != then { return false }
            if uploading.contains(identifier) { return false }
            if uploadNames.contains(now.name) { return false }
            return true
        }
        let event: FilesWalk.Event = finished.machine.isConfirming
            ? .confirmed(delta: delta, listing: listing)
            : .finished(delta: delta, listing: listing)
        return report(finished.machine.apply(event), walk: finished,
                      digest: digest, refreshAfter: refreshAfter, phase: phase)
    }

    private mutating func fail(_ walk: Walk, record: [String: FileItem],
                               recordDigest: String?, refreshAfter: Bool,
                               phase: Phase) -> Action {
        // An incomplete walk reports additions and changes only; the record
        // keeps every item the walk never saw.
        var merged = record
        for (identifier, item) in walk.pages { merged[identifier] = item }
        let listing = Array(merged.values)
        var delta = FilesDiff.delta(old: record, new: listing)
        delta.deleted = []
        let event: FilesWalk.Event = walk.machine.isConfirming
            ? .confirmFailed(delta: delta, listing: listing)
            : .failed(delta: delta, listing: listing)
        var next = walk
        return report(next.machine.apply(event), walk: next,
                      digest: recordDigest, refreshAfter: refreshAfter, phase: phase)
    }

    private mutating func report(_ action: FilesWalk.Action, walk: Walk,
                                 digest: String?, refreshAfter: Bool,
                                 phase: Phase) -> Action {
        switch action {
        case .confirm:
            state = .confirming(walk, refreshAfter: refreshAfter, waiting: true)
            return .scheduleConfirm
        case .report(let delta, let listing):
            state = refreshAfter ? .refreshing(again: true, token: walk.token) : .idle
            return .report(delta, listing: listing, digest: digest, dropped: [])
        case .none:
            state = phase.state(for: walk, refreshAfter: refreshAfter)
            return .none
        }
    }

    /// A walk that started a confirm walk: the same walk, its pages cleared.
    private func clear(_ walk: Walk) -> Walk {
        var cleared = walk
        cleared.pages = [:]
        return cleared
    }

    /// The phase a walk belongs to, for an action that changed nothing.
    private enum Phase {
        case walking, confirming, repairing

        func state(for walk: Walk, refreshAfter: Bool) -> State {
            switch self {
            case .walking:
                return .walking(walk, refreshAfter: refreshAfter)
            case .confirming:
                return .confirming(walk, refreshAfter: refreshAfter, waiting: false)
            case .repairing:
                return .repairing(walk, refreshAfter: refreshAfter)
            }
        }
    }

    private func merge(_ items: [FileItem], into pages: inout [String: FileItem]) {
        for item in items { pages[item.identifier] = item }
    }
}

extension FolderJob.State {
    /// The log's closed-set token: one line per phase change.
    var token: String {
        switch self {
        case .idle: return "idle"
        case .walking: return "walking"
        case .confirming: return "confirming"
        case .repairing: return "repairing"
        case .refreshing(let again, _): return again ? "refreshing-again" : "refreshing"
        }
    }
}

extension FolderJob.Event {
    /// The log's closed-set token for the event that moved the phase.
    var token: String {
        switch self {
        case .visit: return "visit"
        case .refresh: return "refresh"
        case .hostStart: return "host-start"
        case .systemStart: return "system-start"
        case .confirmDue: return "confirm-due"
        case .refreshDue: return "refresh-due"
        case .notFound: return "not-found"
        case .dropped: return "dropped"
        case .page: return "page"
        case .lastPage: return "last-page"
        case .failedPage: return "page-failed"
        }
    }
}
