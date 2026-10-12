// Spotlight for phone apps: the app list of each connected phone is indexed
// into CoreSpotlight so phone apps show up in a Spotlight search. Clicking a
// result continues an NSUserActivity (CSSearchableItemActionType) that names
// the item; we open that app in a new window, connecting first if needed.
//
// The item builder is pure so the unit tests pin identifiers, domain and copy;
// re-indexing is throttled to when the app list actually changes.

import AppKit
import CoreSpotlight
import UniformTypeIdentifiers

struct SpotlightOpenRequest: Equatable {
    var deviceId: String
    var pkg: String
}

enum SpotlightIndexer {
    /// The phone name for the description line, e.g. "Android app on Pixel".
    static func contentDescription(phoneName: String) -> String { "Android app on \(phoneName)" }

    /// "<deviceId>/<pkg>" — pkg may contain dots but never a slash.
    static func uniqueIdentifier(deviceId: String, pkg: String) -> String { "\(deviceId)/\(pkg)" }

    static func parse(identifier: String) -> SpotlightOpenRequest? {
        let parts = identifier.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        return SpotlightOpenRequest(deviceId: String(parts[0]), pkg: String(parts[1]))
    }

    /// Changes whenever anything a user can see about an app changes.
    static func signature(apps: [AppInfo], phoneName: String) -> String {
        (["phone=\(phoneName)"] + apps.map { "\($0.pkg)|\($0.label)|\($0.activity ?? "")" })
            .joined(separator: "\n")
    }

    static func items(apps: [AppInfo], deviceId: String, phoneName: String,
                      iconData: (String) -> Data?) -> [CSSearchableItem] {
        apps.map { app in
            let attributes = CSSearchableItemAttributeSet(contentType: .application)
            attributes.title = app.label
            attributes.contentDescription = contentDescription(phoneName: phoneName)
            attributes.thumbnailData = iconData(app.pkg)
            return CSSearchableItem(uniqueIdentifier: uniqueIdentifier(deviceId: deviceId, pkg: app.pkg),
                                    domainIdentifier: deviceId,
                                    attributeSet: attributes)
        }
    }

    /// The Spotlight result the user clicked, if the activity is one of ours.
    static func request(from activity: NSUserActivity) -> SpotlightOpenRequest? {
        guard activity.activityType == CSSearchableItemActionType,
              let identifier = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String else { return nil }
        return parse(identifier: identifier)
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

final class SpotlightIndex {
    private let index: SearchIndexing
    /// Last indexed signature per device id; a reconnect re-sends `apps`.
    private var signatures: [String: String] = [:]

    init(index: SearchIndexing = CSSearchableIndex.default()) { self.index = index }

    func index(apps: [AppInfo], deviceId: String, phoneName: String, iconData: (String) -> Data?) {
        guard !deviceId.isEmpty else { return }
        let signature = SpotlightIndexer.signature(apps: apps, phoneName: phoneName)
        guard signatures[deviceId] != signature else { return }
        signatures[deviceId] = signature

        let items = SpotlightIndexer.items(apps: apps, deviceId: deviceId, phoneName: phoneName, iconData: iconData)
        Log.app.notice("spotlight: indexing \(items.count, privacy: .public) apps for \(deviceId, privacy: .public)")
        index.indexSearchableItems(items) { error in
            if let error {
                Log.app.error("spotlight: index failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// The device is gone (forgotten): its results must go with it.
    func remove(deviceId: String) {
        signatures.removeValue(forKey: deviceId)
        index.deleteSearchableItems(withDomainIdentifiers: [deviceId]) { error in
            if let error {
                Log.app.error("spotlight: delete failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    func continuationRequest(from activity: NSUserActivity) -> SpotlightOpenRequest? {
        SpotlightIndexer.request(from: activity)
    }
}
