// Spotlight for phone apps: the app list of each connected phone is indexed
// into CoreSpotlight so phone apps show up in a Spotlight search. Clicking a
// result continues an NSUserActivity (CSSearchableItemActionType) that names
// the item; we open that app in a new window, connecting first if needed.
//
// The item builder is pure so the unit tests pin identifiers, domain and copy;
// re-indexing is throttled to when the app list or the phone's name changes,
// and a change replaces the phone's whole domain so no stale title survives.

import AppKit
import CoreSpotlight
import os
import UniformTypeIdentifiers

struct SpotlightOpenRequest: Equatable {
    var deviceId: String
    var pkg: String
}

enum SpotlightIndexer {
    /// The phone name for the description line, e.g. "Android app on Pixel".
    static func contentDescription(phoneName: String) -> String { "Android app on \(phoneName)" }

    /// "WhatsApp (Test Phone)": the phone says which of the user's phones has the app.
    static func title(label: String, phoneName: String) -> String { "\(label) (\(phoneName))" }

    /// Lets a search for the app, its package, the phone or "Android" find it.
    static func keywords(app: AppInfo, phoneName: String) -> [String] {
        [app.label, app.pkg, phoneName, "Android"]
    }

    /// "<domainPrefix><deviceId>/<pkg>" — pkg may contain dots but never a slash.
    /// The prefix is the profile's (empty for the default profile).
    static func uniqueIdentifier(deviceId: String, pkg: String, domainPrefix: String = "") -> String {
        "\(domainPrefix)\(deviceId)/\(pkg)"
    }

    /// nil for identifiers that belong to another profile or are malformed.
    static func parse(identifier: String, domainPrefix: String = "") -> SpotlightOpenRequest? {
        guard identifier.hasPrefix(domainPrefix) else { return nil }
        let parts = identifier.dropFirst(domainPrefix.count)
            .split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        return SpotlightOpenRequest(deviceId: String(parts[0]), pkg: String(parts[1]))
    }

    /// Changes whenever anything a user can see about an app changes.
    static func signature(apps: [AppInfo], phoneName: String) -> String {
        (["phone=\(phoneName)"] + apps.map { "\($0.pkg)|\($0.label)|\($0.activity ?? "")" })
            .joined(separator: "\n")
    }

    static func items(apps: [AppInfo], deviceId: String, phoneName: String, domainPrefix: String = "",
                      iconData: (String) -> Data?) -> [CSSearchableItem] {
        apps.map { app in
            let attributes = CSSearchableItemAttributeSet(contentType: .application)
            attributes.title = title(label: app.label, phoneName: phoneName)
            attributes.displayName = attributes.title
            attributes.keywords = keywords(app: app, phoneName: phoneName)
            attributes.contentDescription = contentDescription(phoneName: phoneName)
            attributes.thumbnailData = iconData(app.pkg)
            return CSSearchableItem(uniqueIdentifier: uniqueIdentifier(deviceId: deviceId, pkg: app.pkg,
                                                                       domainPrefix: domainPrefix),
                                    domainIdentifier: domainPrefix + deviceId,
                                    attributeSet: attributes)
        }
    }

    /// Every item carries the phone's name as a keyword, so a query for it
    /// finds the phone's whole app list without naming any app in the query.
    static func keywordQuery(phoneName: String) -> String {
        let escaped = phoneName.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "kMDItemKeywords == \"\(escaped)\""
    }

    /// The Spotlight result the user clicked, if the activity is one of ours.
    static func request(from activity: NSUserActivity, domainPrefix: String = "") -> SpotlightOpenRequest? {
        guard activity.activityType == CSSearchableItemActionType,
              let identifier = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String else { return nil }
        return parse(identifier: identifier, domainPrefix: domainPrefix)
    }
}

/// Seam for tests: `CSSearchableIndex` itself cannot be inspected.
protocol SearchIndexing: AnyObject {
    func indexSearchableItems(_ items: [CSSearchableItem],
                              completionHandler: (@Sendable (Error?) -> Void)?)
    func deleteSearchableItems(withDomainIdentifiers domainIdentifiers: [String],
                               completionHandler: (@Sendable (Error?) -> Void)?)
}

extension CSSearchableIndex: SearchIndexing {}

// MARK: - Index health

// The index is a system service the app does not own: on macOS 27 the daemon
// refuses an ad-hoc-signed build whose bundle id many registered copies claim
// ("cannot rule out a higher-provenance claimant"). The app cannot fix that from
// inside, so it does two things instead: it asks its own index back with a
// CSSearchQuery (the only place those items are visible) and it says the
// sentence a person can act on exactly once per launch, not once per attempt.
//
// `SpotlightIndexState` is that lifecycle as one closed set of states and one
// pure transition; "did we warn already" and "is a query owed" were the two
// flags a fix like this grows into disagreeing.

/// One verification: which phone's list, and how many items it should hold.
struct SpotlightVerification: Equatable {
    var deviceId: String
    var phoneName: String
    var expectedCount: Int
}

enum SpotlightIndexState: Equatable {
    case idle
    case verifying(SpotlightVerification)
    case verified(found: Int)
    case unavailable(announced: Bool)

    /// The state's name in the transition log; never the phone's name.
    var state: String {
        switch self {
        case .idle: return "idle"
        case .verifying: return "verifying"
        case .verified: return "verified"
        case .unavailable: return "unavailable"
        }
    }
}

enum SpotlightIndexEvent: Equatable {
    /// A batch went to the index; `verification` is what it should hold after.
    case submitted(SpotlightVerification)
    /// The index call came back with an error.
    case refused
    /// The query back finished with `found` of the expected items.
    case queried(SpotlightVerification, found: Int)

    var kind: String {
        switch self {
        case .submitted(let verification): return "submitted(\(verification.expectedCount))"
        case .refused: return "refused"
        case .queried(_, let found): return "queried(\(found))"
        }
    }
}

enum SpotlightIndexEffect: Equatable {
    case verify(SpotlightVerification)
    case announceVerified(SpotlightVerification, foundCount: Int)
    /// The one hint per launch.
    case announceUnavailable
    case quiet
}

extension SpotlightIndexState {
    /// The whole lifecycle. Every state takes every event, so a new state or
    /// event fails to compile here instead of falling through a `default`.
    func applying(_ event: SpotlightIndexEvent) -> (SpotlightIndexState, [SpotlightIndexEffect]) {
        switch (self, event) {
        case (_, .submitted(let verification)) where verification.expectedCount == 0:
            // Nothing was indexed, so there is nothing to ask back.
            return (self, [.quiet])

        case (.idle, .submitted(let verification)),
             (.verifying, .submitted(let verification)),
             (.verified, .submitted(let verification)),
             (.unavailable, .submitted(let verification)):
            return (.verifying(verification), [.verify(verification)])

        case (.unavailable(announced: true), .refused):
            return (self, [.quiet])
        case (.idle, .refused),
             (.verifying, .refused),
             (.verified, .refused),
             (.unavailable(announced: false), .refused):
            return (.unavailable(announced: true), [.announceUnavailable])

        // The query back only answers the verification it belongs to; an answer
        // for another phone's or another batch's list is not evidence here.
        case (.verifying(let pending), .queried(let answered, let found))
            where pending == answered && found > 0:
            return (.verified(found: found), [.announceVerified(pending, foundCount: found)])
        case (.verifying, .queried(_, 0)):
            return (.unavailable(announced: true), [.announceUnavailable])
        case (.verifying, .queried),
             (.idle, .queried),
             (.verified, .queried),
             (.unavailable, .queried):
            return (self, [.quiet])
        }
    }
}

@MainActor
final class SpotlightIndex {
    /// How many of this launch's items a query returns, settled after at most
    /// `timeout` seconds (0 when the query fails or never answers). A seam
    /// because the unit tests must not talk to the system index.
    typealias ItemCount = @Sendable (_ queryString: String, _ identifierPrefix: String,
                                     _ timeout: TimeInterval) async -> Int

    private let index: SearchIndexing
    private let itemCount: ItemCount
    /// The profile's prefix on every identifier and domain (see `Profile`).
    private let domainPrefix: String
    /// Last indexed signature per device id; a reconnect re-sends `apps`.
    private var signatures: [String: String] = [:]
    /// Index health since launch; the tests read it.
    private(set) var state: SpotlightIndexState = .idle

    init(index: SearchIndexing = CSSearchableIndex.default(), domainPrefix: String = "",
         itemCount: @escaping ItemCount = SpotlightIndex.indexedItemCount) {
        self.index = index
        self.domainPrefix = domainPrefix
        self.itemCount = itemCount
    }

    func index(apps: [AppInfo], deviceId: String, phoneName: String, iconData: (String) -> Data?) {
        guard !deviceId.isEmpty else { return }
        let signature = SpotlightIndexer.signature(apps: apps, phoneName: phoneName)
        guard signatures[deviceId] != signature else { return }
        let wasIndexed = signatures[deviceId] != nil
        signatures[deviceId] = signature
        if wasIndexed { deleteDomain(deviceId: deviceId) }

        let items = SpotlightIndexer.items(apps: apps, deviceId: deviceId, phoneName: phoneName,
                                           domainPrefix: domainPrefix, iconData: iconData)
        let verification = SpotlightVerification(deviceId: deviceId, phoneName: phoneName,
                                                 expectedCount: items.count)
        Log.app.notice("spotlight: indexing \(items.count, privacy: .public) apps for \(deviceId, privacy: .public)")
        index.indexSearchableItems(items) { [weak self] error in
            if let error {
                let code = Self.errorCode(error)
                Log.app.debug("spotlight: index call failed: \(code, privacy: .public)")
            }
            Task { @MainActor [weak self] in
                self?.settle(error == nil ? .submitted(verification) : .refused)
            }
        }
    }

    /// The device is gone (forgotten): its results must go with it.
    func remove(deviceId: String) {
        signatures.removeValue(forKey: deviceId)
        deleteDomain(deviceId: deviceId)
    }

    private func deleteDomain(deviceId: String) {
        index.deleteSearchableItems(withDomainIdentifiers: [domainPrefix + deviceId]) { error in
            if let error {
                let code = Self.errorCode(error)
                Log.app.debug("spotlight: delete failed: \(code, privacy: .public)")
            }
        }
    }

    func continuationRequest(from activity: NSUserActivity) -> SpotlightOpenRequest? {
        SpotlightIndexer.request(from: activity, domainPrefix: domainPrefix)
    }

    // MARK: Index health

    private func settle(_ event: SpotlightIndexEvent) {
        let from = state
        let (next, effects) = state.applying(event)
        state = next
        Log.app.debug("spotlight state: \(from.state, privacy: .public) --\(event.kind, privacy: .public)--> \(next.state, privacy: .public)")
        for effect in effects { perform(effect) }
    }

    private func perform(_ effect: SpotlightIndexEffect) {
        switch effect {
        case .verify(let verification):
            verify(verification)
        case .announceVerified(let verification, let foundCount):
            Log.app.notice("spotlight: verified \(foundCount, privacy: .public) of \(verification.expectedCount, privacy: .public) apps in the index")
        case .announceUnavailable:
            // One line per launch, with the only step that can fix it: CoreSpotlight
            // weighs the bundle id's LaunchServices claimants, and a Mac that keeps
            // many copies of the app under that id loses the index for all of them.
            Log.app.error("spotlight: unavailable: CoreSpotlight will not index this build; if Spotlight for phone apps stays empty, quit PocketDeck and remove the other copies of PocketDeck.app on this Mac, then launch it again")
        case .quiet:
            Log.app.debug("spotlight: no index change to verify")
        }
    }

    /// Ask the index back for this launch's own items: the identifier prefix is
    /// what separates this batch from the same phone's items an older launch
    /// left behind, which is how a check can be fooled by stale results.
    private func verify(_ verification: SpotlightVerification) {
        let queryString = SpotlightIndexer.keywordQuery(phoneName: verification.phoneName)
        let prefix = domainPrefix + verification.deviceId + "/"
        Task { [itemCount] in
            let found = await itemCount(queryString, prefix, 30)
            self.settle(.queried(verification, found: found))
        }
    }

    /// A failure's domain and code, never its description: the description of
    /// an XPC error can carry a path, and the code is what a person can search.
    nonisolated static func errorCode(_ error: Error) -> String {
        let failure = error as NSError
        return "\(failure.domain) \(failure.code)"
    }

    /// The real query back: `CSSearchQuery` for the phone's keyword, counting
    /// the answered items whose identifier belongs to this phone and profile. A
    /// cancelled query answers with an error, so the timeout settles instead of
    /// waiting forever.
    nonisolated static func indexedItemCount(queryString: String, identifierPrefix: String,
                                             timeout: TimeInterval) async -> Int {
        let context = CSSearchQueryContext()
        context.fetchAttributes = ["title"]
        let search = CSSearchQuery(queryString: queryString, queryContext: context)
        let counted = OSAllocatedUnfairLock(initialState: 0)
        return await withCheckedContinuation { (continuation: CheckedContinuation<Int, Never>) in
            search.foundItemsHandler = { items in
                let mine = items.filter { $0.uniqueIdentifier.hasPrefix(identifierPrefix) }.count
                counted.withLock { $0 += mine }
            }
            search.completionHandler = { error in
                continuation.resume(returning: error == nil ? counted.withLock { $0 } : 0)
            }
            search.start()
            Task {
                try? await Task.sleep(for: .seconds(timeout))
                search.cancel()
            }
        }
    }
}
