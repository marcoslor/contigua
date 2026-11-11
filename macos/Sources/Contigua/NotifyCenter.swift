// Phone notifications on the Mac (docs/design/notify.md). The connected phone's
// notifications appear in Notification Center, grouped per phone; clicking one
// opens that app's window. Content lives only in the notification and the UN
// banner: the recording hooks write field sizes and package names, never text.
//
// With `--share-log` (the e2e mode ShareIn already uses) nothing is posted;
// posts, clicks and removals are recorded in that file instead, so a check can
// see what would have appeared without putting banners on the person's screen.
//
// Part 2 adds the phone's own actions (buttons and a reply field), a banner
// clear that dismisses on the phone, per-app mute and Copy code. Action titles
// are part of the category hash but are never logged.

import AppKit
import Foundation
import UserNotifications

/// What the Mac accepted as a forwarded notification's picture, for the record
/// and the attachment lifecycle. Never the bytes.
struct NotifyImageInfo: Equatable {
    var mime: String
    var width: Int
    var height: Int
    var size: Int
    var attachment: String = ""

    var record: String {
        "image=\(mime) w=\(width) h=\(height) size=\(size)"
            + (attachment.isEmpty ? "" : " attachment=\(attachment)")
    }
}

/// The Mac's own image caps (docs/design/notify.md): a phone bug or a hostile
/// peer cannot make it hold unbounded data or a wrong format.
enum NotifyImageCaps {
    static let maxBytes = 256 * 1024
    static let maxSide = 1024
    static let mimes: Set<String> = ["image/jpeg", "image/png"]

    static func fileExtension(_ mime: String) -> String {
        mime.lowercased() == "image/png" ? "png" : "jpg"
    }

    static func refusal(mime: String, width: Int, height: Int, decoded: Int) -> String? {
        guard mimes.contains(mime.lowercased()) else { return "mime" }
        guard width > 0, height > 0, width <= maxSide, height <= maxSide else { return "size" }
        guard decoded > 0, decoded <= maxBytes else { return "bytes" }
        return nil
    }
}

/// What a live post did to the store.
enum NotifyLiveOutcome: Equatable {
    /// The first post of this id: banner once and list it.
    case banner
    /// Applied in place (recorded, no banner).
    case updated
    /// Too soon after the last one: the newest state waits for the window.
    case coalesced
}

/// What a post does to the Mac's banner set (NOTIFY-19, docs/specs/
/// notifications.md): Android alerts the first post of a key and an update it
/// did not silence, and never the quiet ones.
enum NotifyPostPlan: Equatable {
    /// No banner exists and the post alerts: present one.
    case banner
    /// No banner exists and the post is quiet: add it to the list, present
    /// nothing (a LOW channel, or a notification first seen mid-life).
    case quietAdd
    /// An alerting update of a delivered banner: present the replacement.
    case replace
    /// A quiet update: replace the delivered banner without presenting it.
    case quietReplace

    /// Nothing is presented: the post only lands in the list.
    var quiet: Bool { self == .quietAdd || self == .quietReplace }
}

enum NotifyPostPolicy {
    static func plan(alert: Bool, delivered: Bool) -> NotifyPostPlan {
        if !delivered { return alert ? .banner : .quietAdd }
        return alert ? .replace : .quietReplace
    }
}

/// A post that supersedes one still in its hold (NOTIFY-19): the earlier post
/// never reached Notification Center, so the newcomer inherits its delivery
/// state, and the delivered post alerts if either of them did. Only a banner
/// already handed to the system can be replaced quietly.
enum NotifyPostMerge {
    static func alert(new: Bool, superseded: Bool?) -> Bool {
        new || (superseded ?? false)
    }

    static func delivered(supersededReplacesDelivered: Bool?, requestIdExists: Bool) -> Bool {
        supersededReplacesDelivered ?? requestIdExists
    }
}

/// What the Mac's record says about one post: the wire's alert decision, the
/// banners it holds for that id, and the running presented/quiet counts.
struct NotifyBannerFacts: Equatable {
    var alert: Bool
    var banners: Int
    var presented: Int
    var quiet: Int

    var record: String {
        "alert=\(alert ? 1 : 0) banners=\(banners) presented=\(presented) quiet=\(quiet)"
    }
}

/// The Live Update rows behind the menu bar's section, with in-place updates and
/// the one-per-second rule (docs/design/notify.md). Pure, so the rules are
/// unit-tested; the caller owns the banner and the recording.
final class NotifyLiveStore {
    let interval: TimeInterval
    private(set) var items: [NotifyLiveItem] = []
    private var lastApplied: [String: Date] = [:]
    private var pending: [String: NotifyLiveItem] = [:]

    init(interval: TimeInterval = 1) {
        self.interval = interval
    }

    func item(_ id: String) -> NotifyLiveItem? { items.first { $0.id == id } }

    /// A live post: the first banners, later ones update the row at most once
    /// per second (the newest state wins; [flush] delivers what waited).
    func post(id: String, pkg: String, label: String?, live: NotifyLive,
              now: Date) -> NotifyLiveOutcome {
        let item = NotifyLiveItem(id: id, pkg: pkg, label: label, chip: live.chip,
                                  progress: live.progress, chrono: live.chrono,
                                  countDown: live.countDown, updated: now)
        guard let index = items.firstIndex(where: { $0.id == id }) else {
            items.append(item)
            lastApplied[id] = now
            pending.removeValue(forKey: id)
            return .banner
        }
        if let last = lastApplied[id], now.timeIntervalSince(last) < interval {
            pending[id] = item
            return .coalesced
        }
        items[index] = item
        lastApplied[id] = now
        pending.removeValue(forKey: id)
        return .updated
    }

    /// The rows whose window opened; empty when nothing waited.
    func flush(now: Date) -> [NotifyLiveItem] {
        var applied: [NotifyLiveItem] = []
        for (id, item) in pending {
            guard let last = lastApplied[id], now.timeIntervalSince(last) >= interval else { continue }
            guard let index = items.firstIndex(where: { $0.id == id }) else {
                pending.removeValue(forKey: id)
                continue
            }
            var fresh = item
            fresh.updated = now
            items[index] = fresh
            lastApplied[id] = now
            pending.removeValue(forKey: id)
            applied.append(fresh)
        }
        return applied
    }

    /// The activity ended (the phone removed it): the row goes away.
    @discardableResult
    func end(_ id: String) -> Bool {
        pending.removeValue(forKey: id)
        lastApplied.removeValue(forKey: id)
        guard let index = items.firstIndex(where: { $0.id == id }) else { return false }
        items.remove(at: index)
        return true
    }

    func clear() {
        items.removeAll()
        pending.removeAll()
        lastApplied.removeAll()
    }

    /// True while an update waits for its window to open.
    var hasPending: Bool { !pending.isEmpty }
}

/// How a live row reads in the menu bar: label, chip or running chronometer, and
/// a ten-cell text progress bar (a menu item cannot draw a control).
enum NotifyLiveText {    static let cells = 10

    static func progressBar(_ progress: Double) -> String {
        let filled = Int((min(1, max(0, progress)) * Double(cells)).rounded())
        return String(repeating: "▮", count: filled) + String(repeating: "▯", count: cells - filled)
    }

    /// "1:05" / "1:02:03": a chronometer's distance from now, in its direction.
    static func clock(_ chrono: Date, countDown: Bool, now: Date) -> String {
        let seconds = max(0, Int((countDown ? chrono.timeIntervalSince(now) : now.timeIntervalSince(chrono)).rounded()))
        let h = seconds / 3600, m = (seconds % 3600) / 60, s = seconds % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    /// The row's title: app label (else package), then the live detail.
    static func menuTitle(_ item: NotifyLiveItem, now: Date) -> String {
        let name = item.label ?? item.pkg
        var parts: [String] = []
        if let chip = item.chip, !chip.isEmpty { parts.append(chip) }
        else if let chrono = item.chrono { parts.append(clock(chrono, countDown: item.countDown, now: now)) }
        if let progress = item.progress { parts.append(progressBar(progress)) }
        return parts.isEmpty ? name : "\(name) — \(parts.joined(separator: " "))"
    }
}

/// The menu bar's live section as JSON (DebugInput's `livedump` verb), so the
/// e2e can assert on it without opening a menu or moving the pointer.
enum NotifyLiveDump {
    static func json(_ items: [NotifyLiveItem], now: Date = Date()) throws -> Data {
        let rows: [[String: Any]] = items.map { item in
            [
                "id": item.id,
                "pkg": item.pkg,
                "label": item.label ?? "",
                "chipLen": item.chip?.count ?? 0,
                "progress": item.progress ?? -1,
                "chrono": item.chrono != nil,
                "countDown": item.countDown,
                "title": NotifyLiveText.menuTitle(item, now: now),
            ]
        }
        return try JSONSerialization.data(withJSONObject: ["live": rows],
                                          options: [.prettyPrinted, .sortedKeys])
    }

    static func write(_ items: [NotifyLiveItem], to path: String) throws {
        try json(items).write(to: URL(fileURLWithPath: path), options: .atomic)
    }
}

/// One action the phone advertised in `notify.post` (docs/PROTOCOL.md).
struct NotifyActionInfo: Equatable {
    var i: Int
    var title: String
    var reply: Bool

    init(i: Int, title: String, reply: Bool = false) {
        self.i = i
        self.title = title
        self.reply = reply
    }

    /// A wire entry; nil when it broke the caps (title, index) the phone promised.
    init?(json: [String: Any]) {
        guard let i = (json["i"] as? NSNumber)?.intValue, (0...64).contains(i) else { return nil }
        guard let raw = json["title"] as? String else { return nil }
        let title = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }
        self.i = i
        self.title = title.count > 64 ? String(title.prefix(64)) : title
        self.reply = json["reply"] as? Bool ?? false
    }
}

/// An Android 16 Live Update's own fields (docs/design/notify.md). Every field
/// is optional; an empty object still marks the notification as live.
struct NotifyLive: Equatable {
    var progress: Double?
    var chip: String?
    var chrono: Date?
    var countDown: Bool = false

    init(progress: Double? = nil, chip: String? = nil, chrono: Date? = nil, countDown: Bool = false) {
        self.progress = progress
        self.chip = chip
        self.chrono = chrono
        self.countDown = countDown
    }

    /// The wire's `live` object; nil when the field is absent or not an object.
    init?(json: Any?) {
        guard let json = json as? [String: Any] else { return nil }
        let rawProgress = (json["progress"] as? NSNumber)?.doubleValue
        var chip = (json["chip"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        if chip?.isEmpty == true { chip = nil }
        if let text = chip, text.count > 16 { chip = String(text.prefix(16)) }
        let chronoMs = (json["chrono"] as? NSNumber)?.doubleValue
        self.progress = rawProgress.map { min(1, max(0, $0)) }
        self.chip = chip
        self.chrono = chronoMs.flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0 / 1000) : nil }
        self.countDown = json["countDown"] as? Bool ?? false
    }
}

/// One notification as the phone sent it.
struct PhoneNotification: Equatable {
    var id: String
    var pkg: String
    var when: Date?
    var title: String?
    var text: String?
    var ongoing: Bool = false
    var actions: [NotifyActionInfo] = []
    var live: NotifyLive? = nil
    /// Whether Android would alert for this post (NOTIFY-19): the first post of
    /// a key, or an update the app did not silence. Required on the wire.
    var alert: Bool = true
    /// `notify.post`'s `group`: a 64-bit hash of the phone's group key
    /// (NOTIFY-20). Never the key itself; absent when the notification has none.
    var group: String? = nil
}

/// One row of the menu bar's "Live on <phone>" section, updated in place.
struct NotifyLiveItem: Identifiable, Equatable {
    var id: String
    var pkg: String
    var label: String?
    var chip: String?
    var progress: Double?
    var chrono: Date?
    var countDown: Bool
    var updated: Date
}


/// What a banner click stands for: the forwarded id (the phone resolves it),
/// the package and the phone whose setting decides where it runs.
struct NotifyClick: Equatable {
    var id: String
    var pkg: String
    var phoneId: String
}

/// Pure rules: the macOS title/body and the recording line. Unit-tested.
enum NotifyMapping {

    static let maxChars = 8_192

    /// The banner title: the notification's own title (else the app's label)
    /// with the phone's name as a suffix — the name the Deck shows for that
    /// phone (nickname, else its own name), like the window titles. A title
    /// that is empty (or only whitespace) becomes just the phone name.
    static func title(_ base: String?, phoneName: String) -> String {
        let text = cap(base)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty else { return phoneName }
        guard !phoneName.isEmpty else { return text }
        return "\(text) (\(phoneName))"
    }

    /// [NOTIFY-4] The phone's name in a banner title only while the Mac has
    /// two or more phones paired: with one phone the app's own words place the
    /// banner, and the name is noise on every post.
    static func titlePhoneName(_ phoneName: String, phonesPaired: Int) -> String {
        phonesPaired >= 2 ? phoneName : ""
    }

    /// The banner shows `[title, body]`; a missing title falls back to the app's
    /// label (else the package), and a body only carries the notification's own
    /// text.
    static func content(_ n: PhoneNotification,
                        phoneName: String,
                        phonesPaired: Int,
                        labelFor: (String) -> String?) -> (title: String, body: String) {
        let label = labelFor(n.pkg)
        let own = cap(n.title)
        let name = titlePhoneName(phoneName, phonesPaired: phonesPaired)
        let title: String
        if let base = own ?? label {
            title = Self.title(base, phoneName: name)
        } else {
            // A banner always has a title: with one phone the package is the
            // only honest one, since the phone's name is not part of it.
            title = name.isEmpty ? n.pkg : name
        }
        var body = ""
        if let text = cap(n.text), !text.isEmpty {
            body = text
        } else if label == nil, own != nil {
            // No label for the package: name the source under its own title, so
            // the banner still says where the notification came from.
            body = n.pkg
        }
        return (title, body)
    }

    /// The banner's thread (NOTIFY-4, NOTIFY-20): the phone's id alone, or the
    /// phone and the notification's group hash when it has one, so a group's
    /// messages stack together and never with the rest of the phone. Only the
    /// wire's 16 lowercase hex characters are accepted as a group.
    static func thread(phoneId: String, group: String?) -> String {
        guard let group, isValidGroup(group) else { return phoneId }
        return "\(phoneId).\(group)"
    }

    static func isValidGroup(_ group: String) -> Bool {
        group.count == 16 && group.allSatisfy { "0123456789abcdef".contains($0) }
    }

    /// Field sizes and counts only — never the text itself (privacy). The
    /// category id is a hash of the shape, so the e2e can see the counts.
    static func record(posted n: PhoneNotification, title: String, body: String,
                       thread: String, code: Bool, category: String,
                       composed: String? = nil, facts: NotifyBannerFacts,
                       image: NotifyImageInfo? = nil) -> String {
        let reply = n.actions.contains { $0.reply } ? 1 : 0
        var line = "notify post id=\(n.id) pkg=\(n.pkg) titleLen=\(title.count) bodyLen=\(body.count)"
            + " thread=\(thread) actions=\(n.actions.count) reply=\(reply) code=\(code ? 1 : 0)"
            + " ongoing=\(n.ongoing ? 1 : 0) category=\(category)"
        if let composed { line += " " + composed }
        line += " " + facts.record
        if n.live != nil { line += " live=1" }
        if let image { line += " " + image.record }
        return line
    }

    /// The attachment line: the picture's own facts, never its bytes.
    static func record(image id: String, info: NotifyImageInfo) -> String {
        "notify image id=\(id) \(info.record)"
    }

    static func record(imageRefused id: String, reason: String) -> String {
        "notify image id=\(id) refused=\(reason)"
    }

    static func record(imageLate id: String) -> String { "notify image id=\(id) late" }

    /// An in-place Live Update. The progress is a 0–10 bucket, never a value.
    /// `at` is when it was applied (ms), so a check can see the one-per-second rule.
    static func record(live id: String, progress: Double?, chip: String?,
                       chrono: Bool, countDown: Bool, at: Date = Date()) -> String {
        let bucket = progress.map { String(Int(($0 * 10).rounded())) } ?? "-"
        return "notify live id=\(id) progress=\(bucket) chip=\(chip?.count ?? 0)"
            + " chrono=\(chrono ? 1 : 0) countDown=\(countDown ? 1 : 0)"
            + " at=\(Int((at.timeIntervalSince1970 * 1000).rounded()))"
    }

    static func record(liveEnded id: String) -> String { "notify live id=\(id) end" }

    /// A snapshot dropped an id the phone's active set no longer holds
    /// (NOTIFY-1). The summary names counts only.
    static func record(snapshotEnded id: String) -> String { "notify snapshot end id=\(id)" }

    /// The active set itself: its size and how many ids left.
    static func record(snapshot count: Int, ended: Int) -> String {
        "notify snapshot ids=\(count) ended=\(ended)"
    }

    static func record(removed id: String) -> String { "notify remove id=\(id)" }

    static func record(opened: String, id: String) -> String { "notify click id=\(id) pkg=\(opened)" }

    static func record(action id: String, index: Int, textLen: Int) -> String {
        "notify action id=\(id) i=\(index) textLen=\(textLen)"
    }

    static func record(actionUnknown id: String, index: Int) -> String {
        "notify action id=\(id) i=\(index) unknown"
    }

    static func record(actionRefused id: String, index: Int) -> String {
        "notify action id=\(id) i=\(index) refused=not-reply"
    }

    static func record(dismissed id: String) -> String { "notify dismiss id=\(id)" }

    static func record(dismissRefused id: String) -> String { "notify dismiss id=\(id) refused=ongoing" }

    static func record(copied id: String, len: Int) -> String { "notify copy id=\(id) len=\(len)" }

    static func record(muted pkg: String, phone: String) -> String {
        "notify muted pkg=\(pkg) phone=\(phone)"
    }

    private static func cap(_ s: String?) -> String? {
        guard let s, !s.isEmpty else { return nil }
        return s.count > maxChars ? String(s.prefix(maxChars)) : s
    }
}

/// What a banner response stands for, parsed from the UN action identifier.
enum NotifyBannerAction: Equatable {
    case open
    case dismiss
    case copyCode
    case button(Int)
    case reply(Int, String?)

    static func parse(identifier: String, text: String?) -> NotifyBannerAction? {
        if identifier == UNNotificationDefaultActionIdentifier { return .open }
        if identifier == UNNotificationDismissActionIdentifier { return .dismiss }
        if identifier == NotifyCategoryRegistry.copyCodeAction { return .copyCode }
        if identifier.hasPrefix(NotifyCategoryRegistry.buttonPrefix),
           let index = Int(identifier.dropFirst(NotifyCategoryRegistry.buttonPrefix.count)) {
            return .button(index)
        }
        if identifier.hasPrefix(NotifyCategoryRegistry.replyPrefix),
           let index = Int(identifier.dropFirst(NotifyCategoryRegistry.replyPrefix.count)) {
            return .reply(index, text)
        }
        return nil
    }
}

/// The category id is a hash of the notification's shape (button titles, reply,
/// code), never of its text; the registered set is a bounded LRU.
enum NotifyCategories {
    static let maxRegistered = 64

    static func identifier(titles: [String], reply: Bool, code: Bool) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for field in titles + [reply ? "r" : "-", code ? "c" : "-"] {
            for byte in field.utf8 {
                hash ^= UInt64(byte)
                hash = hash &* 0x0000_0100_0000_01b3
            }
            hash ^= 0x1f
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return "pd.n." + String(format: "%016llx", hash)
    }
}

/// Builds and bounds the phone notification categories (docs/design/notify.md).
final class NotifyCategoryRegistry {
    static let copyCodeAction = "pd.copy"
    static let buttonPrefix = "pd.a."
    static let replyPrefix = "pd.r."

    private var order: [String] = []
    private var categories: [String: UNNotificationCategory] = [:]

    /// Called with the new set whenever a shape is added or one is evicted.
    var onUpdate: (([UNNotificationCategory]) -> Void)?

    var count: Int { categories.count }

    /// The identifier for this notification's shape, registering it when new.
    func category(for notification: PhoneNotification, hasCode: Bool) -> String {
        let identifier = NotifyCategories.identifier(
            titles: notification.actions.map(\.title),
            reply: notification.actions.contains { $0.reply },
            code: hasCode,
        )
        if categories[identifier] != nil {
            if let index = order.firstIndex(of: identifier) {
                order.remove(at: index)
                order.append(identifier)
            }
            return identifier
        }
        categories[identifier] = build(identifier: identifier,
                                       actions: notification.actions,
                                       hasCode: hasCode)
        order.append(identifier)
        while order.count > NotifyCategories.maxRegistered {
            let oldest = order.removeFirst()
            categories.removeValue(forKey: oldest)
        }
        onUpdate?(all())
        return identifier
    }

    func all() -> [UNNotificationCategory] {
        order.compactMap { categories[$0] }
    }

    private func build(identifier: String, actions: [NotifyActionInfo], hasCode: Bool) -> UNNotificationCategory {
        var unActions: [UNNotificationAction] = actions.map { action in
            if action.reply {
                return UNTextInputNotificationAction(
                    identifier: Self.replyPrefix + String(action.i),
                    title: action.title,
                    options: [],
                    textInputButtonTitle: "Send",
                    textInputPlaceholder: "Message",
                )
            }
            return UNNotificationAction(
                identifier: Self.buttonPrefix + String(action.i),
                title: action.title,
                options: [],
            )
        }
        if hasCode {
            unActions.append(UNNotificationAction(identifier: Self.copyCodeAction,
                                                  title: "Copy code", options: []))
        }
        // `.customDismissAction` makes a banner clear reach didReceive.
        return UNNotificationCategory(identifier: identifier,
                                      actions: unActions,
                                      intentIdentifiers: [],
                                      options: [.customDismissAction])
    }
}

/// Posts phone notifications and owns the UN delegate. Share notifications keep
/// their own recording/clicks; this router delegates to the share handler when a
/// share notification comes in, and routes phone-notification responses to the
/// caller. One delegate for the whole app (macOS keeps the last one set).
final class NotificationRouter: NSObject, UNUserNotificationCenterDelegate {
    static let phoneKind = "contigua.notify.phone"

    /// Share actions' response handling (registered by ConnectionController).
    weak var shareActions: SystemShareActions?
    /// A phone notification was clicked (default action).
    var onOpen: ((NotifyClick) -> Void)?
    /// A phone notification's banner was cleared.
    var onDismiss: ((NotifyClick) -> Void)?
    /// A button or reply action; nil text for a button.
    var onAction: ((NotifyClick, Int, String?) -> Void)?
    /// Copy code was pressed (the id names the notification).
    var onCopy: ((String) -> Void)?

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let content = response.notification.request.content
        if content.categoryIdentifier == SystemShareActions.category
            || content.userInfo["file"] is String
            || content.userInfo["url"] is String {
            DispatchQueue.main.async { [weak self] in
                self?.shareActions?.handleShareResponse(response)
            }
        } else if content.userInfo["kind"] as? String == Self.phoneKind,
                  let pkg = content.userInfo["pkg"] as? String,
                  let id = content.userInfo["id"] as? String {
            let phoneId = content.userInfo["phone"] as? String ?? content.threadIdentifier
            let click = NotifyClick(id: id, pkg: pkg, phoneId: phoneId)
            let text = (response as? UNTextInputNotificationResponse)?.userText
            switch NotifyBannerAction.parse(identifier: response.actionIdentifier, text: text) {
            case .open:
                let open = onOpen ?? { _ in }
                DispatchQueue.main.async { open(click) }
            case .dismiss:
                let dismiss = onDismiss ?? { _ in }
                DispatchQueue.main.async { dismiss(click) }
            case .copyCode:
                let copy = onCopy ?? { _ in }
                DispatchQueue.main.async { copy(id) }
            case .button(let index):
                let action = onAction ?? { _, _, _ in }
                DispatchQueue.main.async { action(click, index, nil) }
            case .reply(let index, let reply):
                let action = onAction ?? { _, _, _ in }
                DispatchQueue.main.async { action(click, index, reply) }
            case nil:
                break
            }
        }
        completionHandler()
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner])
    }
}

/// The phone notifications half. The router must be installed before either
/// side posts (ShareIn also used to set the delegate; the router owns it now).
/// What macOS says about this app's notification permission, in the three
/// states the page can act on.
enum NotificationAuthorization: String, Equatable {
    case notDetermined
    case denied
    case authorized
}

@MainActor
final class NotifyCenter {
    /// `--share-log`: record posts/clicks/removals (sizes and ids only) instead
    /// of posting them; nothing reaches Notification Center in this mode.
    var log: URL?
    /// The phone notifications belong to one phone; a click routes through the
    /// per-phone "When I click a phone notification" choice.
    var onOpen: ((NotifyClick) -> Void)?
    /// `notify.action` (button or reply) and `notify.dismiss` reach the session.
    var onAction: ((NotifyClick, Int, String?) -> Void)?
    var onDismiss: ((NotifyClick) -> Void)?

    var router = NotificationRouter()
    let categories = NotifyCategoryRegistry()
    /// Replaceable in tests so no private pasteboard is touched.
    var copyService = CodeCopy(pasteboard: SystemCodePasteboard())
    /// The menu bar's live rows, updated in place (docs/design/notify.md).
    private(set) var liveStore = NotifyLiveStore()
    /// Called whenever the live rows change, so the controller can publish them.
    var onLiveChange: (([NotifyLiveItem]) -> Void)?

    /// How long a post waits for the `notify.image` that follows it. 0 in tests
    /// and in `--share-log` mode (nothing reaches Notification Center there, so
    /// there is nothing to attach to).
    var hold: TimeInterval = 0.3

    /// The post package's icon for the attachment (NOTIFY-22). `nil` leaves
    /// every picture as a plain circle with no badge. Replaceable so tests draw
    /// a fixture and never read the person's cache.
    var iconFor: ((_ pkg: String, _ deviceId: String) -> NotifyAttachmentComposer.Icon?)?

    /// Where attachment temp files are written. Tests point it at a temp folder;
    /// nil means the profile's caches.
    var attachmentRoot: URL?

    /// What a banner response or a debug action needs, kept for the ids the
    /// phone issued. Bounded like the wire's own id map.
    private struct Known {
        var click: NotifyClick
        var title: String?
        var text: String?
        var actions: [NotifyActionInfo]
        var code: String?
        var ongoing: Bool
        var live: NotifyLive?
        var requestId: String?
    }

    /// A post that has not reached Notification Center yet: the `hold` window
    /// is when its picture can still join it.
    private struct PendingPost {
        var notification: PhoneNotification
        var phoneId: String
        var phoneName: String
        var title: String
        var body: String
        var category: String
        var image: (info: NotifyImageInfo, data: Data)?
        var work: DispatchWorkItem
        /// A banner for this id already existed when the post arrived.
        var replacesDelivered: Bool
    }

    private var known: [String: Known] = [:]
    private var knownOrder: [String] = []
    private var requestIds: [String: String] = [:]
    /// Per id: how many posts presented and how many replaced quietly (NOTIFY-19).
    private var postCounts: [String: (presented: Int, quiet: Int)] = [:]
    private var pending: [String: PendingPost] = [:]
    /// The id → temp attachment path; deleted with the banner or a disconnect.
    private var attachments: [String: URL] = [:]
    private var liveFlush: DispatchWorkItem?
    private var authorized = false
    private var registering = false
    /// The e2e's stand-in for the system's answer (`--debug-notify-denied`).
    var debugAuthorization: NotificationAuthorization?

    private static let maxKnown = 200

    /// Where a profile's attachment temp files live: caches, not Documents.
    private static var profileAttachmentDirectory: URL? {
        guard let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            return nil
        }
        return base.appendingPathComponent(Profile.active.supportDirectoryName, isDirectory: true)
            .appendingPathComponent("notify", isDirectory: true)
    }

    private var attachmentDirectory: URL? { attachmentRoot ?? Self.profileAttachmentDirectory }

    /// The post package's cached icon in the composer's form (NOTIFY-22): the
    /// Deck's slot first, then the Dock's, so the first source that fits the
    /// attachment's size is the one drawn.
    nonisolated static func cachedIcon(pkg: String, deviceId: String) -> NotifyAttachmentComposer.Icon? {
        var candidates: [NotifyAttachmentComposer.IconCandidate] = []
        for sizeClass in IconSizeClass.allCases {
            let layers = IconCache.shared.loadLayerData(pkg: pkg, deviceId: deviceId, sizeClass: sizeClass)
            let flat = IconCache.shared.loadData(pkg: pkg, deviceId: deviceId, sizeClass: sizeClass)
            if let layers, let fg = NotifyAttachmentComposer.decode(layers.fg),
               let bg = NotifyAttachmentComposer.decode(layers.bg) {
                candidates.append(NotifyAttachmentComposer.IconCandidate(
                    layers: (fg, bg), flat: nil, sizeClass: sizeClass))
            } else if let flat, let image = NotifyAttachmentComposer.decode(flat) {
                candidates.append(NotifyAttachmentComposer.IconCandidate(
                    layers: nil, flat: image, sizeClass: sizeClass))
            }
        }
        return candidates.isEmpty ? nil : NotifyAttachmentComposer.Icon(candidates: candidates)
    }

    /// The whole set of live rows (the menu bar reads this).
    var liveItems: [NotifyLiveItem] { liveStore.items }

    /// Installing the delegate must happen before any notification from either
    /// side; with a log there is nothing to show, so neither happens.
    func install() {
        guard log == nil else { return }
        // The real banner responses go through the same routing as the debug
        // actions; the delegate is installed once, before any notification.
        router.onOpen = { [weak self] click in self?.onOpen?(click) }
        router.onDismiss = { [weak self] click in self?.onDismiss?(click) }
        router.onAction = { [weak self] click, index, text in self?.onAction?(click, index, text) }
        router.onCopy = { [weak self] id in _ = self?.performCopy(id: id) }
        categories.onUpdate = { [weak self] phoneCategories in self?.register(phoneCategories) }
        UNUserNotificationCenter.current().delegate = router
        register([])
    }

    private func register(_ phoneCategories: [UNNotificationCategory]) {
        let show = UNNotificationAction(identifier: SystemShareActions.showAction, title: "Show in Finder")
        let share = UNNotificationCategory(identifier: SystemShareActions.category,
                                           actions: [show], intentIdentifiers: [])
        UNUserNotificationCenter.current().setNotificationCategories(
            Set(phoneCategories + [share]),
        )
    }

    /// Posts one phone notification; the thread groups them under the phone's id.
    func post(_ n: PhoneNotification, phoneId: String, phoneName: String, phonesPaired: Int,
              labelFor: (String) -> String?) {
        let (title, body) = NotifyMapping.content(n, phoneName: phoneName, phonesPaired: phonesPaired,
                                                  labelFor: labelFor)
        let code = NotifyCode.find(title: n.title, text: n.text)
        // A Live Update: the first post banners, later ones update the row in
        // place and never banner again (docs/design/notify.md).
        var outcome: NotifyLiveOutcome?
        if let live = n.live {
            outcome = liveStore.post(id: n.id, pkg: n.pkg, label: labelFor(n.pkg), live: live, now: Date())
            publishLive()
            if outcome == .updated, let item = liveStore.item(n.id) {
                record(NotifyMapping.record(live: n.id, progress: item.progress, chip: item.chip,
                                            chrono: item.chrono != nil, countDown: item.countDown))
                return
            }
            if outcome == .coalesced {
                scheduleLiveFlush()
                return
            }
        }
        remember(PhoneNotification(id: n.id, pkg: n.pkg, when: n.when, title: n.title, text: n.text,
                                   ongoing: n.ongoing, actions: n.actions, live: n.live),
                 click: NotifyClick(id: n.id, pkg: n.pkg, phoneId: phoneId),
                 code: code,
                 requestId: requestId(phoneId: phoneId, id: n.id))
        let shape = NotifyCategories.identifier(
            titles: n.actions.map(\.title),
            reply: n.actions.contains { $0.reply },
            code: code != nil,
        )
        // Nothing reaches Notification Center in share-log mode, but the post
        // still waits its hold so the line can carry the picture that follows.
        let category = log == nil ? categories.category(for: n, hasCode: code != nil) : shape
        let requestId = requestId(phoneId: phoneId, id: n.id)
        // A post inside the hold of one still waiting supersedes it (NOTIFY-19):
        // it inherits that post's delivery state and alerts if either did, so a
        // quiet re-post can never swallow the first banner. Only a banner
        // already handed to Notification Center can be replaced quietly.
        let superseded = pending[n.id]
        var delivered = n
        delivered.alert = NotifyPostMerge.alert(new: n.alert, superseded: superseded?.notification.alert)
        let replacesDelivered = NotifyPostMerge.delivered(
            supersededReplacesDelivered: superseded?.replacesDelivered,
            requestIdExists: requestIds[n.id] != nil,
        )
        requestIds[n.id] = requestId
        // A cancellation of an earlier post for the same id ends its wait too.
        pending.removeValue(forKey: n.id)?.work.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.deliver(id: n.id)
        }
        pending[n.id] = PendingPost(notification: delivered, phoneId: phoneId, phoneName: phoneName,
                                    title: title, body: body, category: category,
                                    image: nil, work: work, replacesDelivered: replacesDelivered)
        if hold > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + hold, execute: work)
        } else {
            deliver(id: n.id)
        }
    }

    /// `notify.image` (docs/design/notify.md): the picture that follows a post.
    /// Refused when it breaks the Mac's caps, dropped when the post is already
    /// out (a second banner is worse than a missing thumbnail).
    func image(id: String, mime: String, width: Int, height: Int, data: Data) {
        let reason = NotifyImageCaps.refusal(mime: mime, width: width, height: height,
                                             decoded: data.count)
        if let reason {
            record(NotifyMapping.record(imageRefused: id, reason: reason))
            return
        }
        guard pending[id] != nil else {
            if known[id] != nil {
                record(NotifyMapping.record(imageLate: id))
            } else {
                record(NotifyMapping.record(imageRefused: id, reason: "unknown"))
            }
            return
        }
        let info = NotifyImageInfo(mime: mime.lowercased(), width: width, height: height, size: data.count)
        pending[id]?.image = (info, data)
    }

    /// The post's wait is over: write its attachment (if any) and submit it.
    private func deliver(id: String) {
        guard let post = pending.removeValue(forKey: id) else { return }
        let plan = NotifyPostPolicy.plan(alert: post.notification.alert,
                                        delivered: post.replacesDelivered)
        // NOTIFY-19: a quiet update replaces the delivered banner without
        // presenting it. `.passive` is the level that adds to the list without
        // lighting the screen (UNNotificationContent.h, docs/design/notify.md).
        var counts = postCounts[id] ?? (presented: 0, quiet: 0)
        if plan.quiet { counts.quiet += 1 } else { counts.presented += 1 }
        postCounts[id] = counts
        let thread = NotifyMapping.thread(phoneId: post.phoneId, group: post.notification.group)
        var info = post.image?.info
        var url: URL?
        // NOTIFY-22: the picture is cut to a circle with the sending app's
        // badge, and with no picture the app's icon alone is the attachment.
        let picture = post.image.flatMap { NotifyAttachmentComposer.decode($0.data) }
        let composition: NotifyAttachmentComposer.Outcome
        if post.image != nil, picture == nil {
            // Undecodable bytes never become "no picture": keep them as sent.
            composition = NotifyAttachmentComposer.Outcome(attachment: nil, fallback: .render)
        } else {
            composition = NotifyAttachmentComposer.compose(
                picture: picture,
                icon: iconFor?(post.notification.pkg, post.phoneId),
            )
        }
        if let composed = composition.attachment {
            let composedInfo = NotifyImageInfo(mime: composed.mime, width: composed.side,
                                               height: composed.side, size: composed.data.count)
            info = composedInfo
            if let written = writeAttachment(phoneId: post.phoneId, id: id, info: composedInfo,
                                             data: composed.data) {
                url = written
                info?.attachment = written.path
                attachments[id] = written
            }
        } else if let image = post.image, let written = writeAttachment(phoneId: post.phoneId, id: id,
                                                                         info: image.info, data: image.data) {
            // The composition could not meet the caps: today's picture.
            url = written
            info?.attachment = written.path
            attachments[id] = written
        }
        record(NotifyMapping.record(posted: post.notification, title: post.title, body: post.body,
                                    thread: thread, code: NotifyCode.find(title: post.notification.title,
                                                                                 text: post.notification.text) != nil,
                                    category: post.category, composed: composition.record,
                                    facts: NotifyBannerFacts(alert: post.notification.alert,
                                                             banners: requestIds[id] == nil ? 0 : 1,
                                                             presented: counts.presented,
                                                             quiet: counts.quiet),
                                    image: info))
        guard log == nil else { return }
        let content = UNMutableNotificationContent()
        content.title = post.title
        if !post.body.isEmpty { content.body = post.body }
        content.threadIdentifier = thread
        content.sound = nil
        if plan.quiet { content.interruptionLevel = .passive }
        content.categoryIdentifier = post.category
        content.userInfo = ["kind": NotificationRouter.phoneKind, "pkg": post.notification.pkg,
                            "id": id, "phone": post.phoneId]
        if let url, let attachment = try? UNNotificationAttachment(
            identifier: "pd.img.\(id)", url: url, options: nil,
        ) {
            content.attachments = [attachment]
        }
        let request = UNNotificationRequest(identifier: requestId(phoneId: post.phoneId, id: id),
                                            content: content, trigger: nil)
        postToCenter(request)
    }

    /// Writes the temp file 0600 in a 0700 directory; nil when it cannot.
    private func writeAttachment(phoneId: String, id: String, info: NotifyImageInfo, data: Data) -> URL? {
        guard let directory = attachmentDirectory else { return nil }
        let manager = FileManager.default
        do {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
            let name = requestId(phoneId: phoneId, id: id).replacingOccurrences(of: "..", with: "_")
                + "." + NotifyImageCaps.fileExtension(info.mime)
            let url = directory.appendingPathComponent(name)
            try data.write(to: url, options: [.atomic])
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return url
        } catch {
            return nil
        }
    }

    /// Deletes one id's temp file (banner removed, phone ended it).
    private func dropAttachment(_ id: String) {
        guard let url = attachments.removeValue(forKey: id) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// Disconnect: no banner, no attachment and no live row outlives the phone.
    func clearAll() {
        for (_, post) in pending { post.work.cancel() }
        pending.removeAll()
        liveFlush?.cancel()
        liveFlush = nil
        liveStore.clear()
        publishLive()
        for (_, url) in attachments { try? FileManager.default.removeItem(at: url) }
        attachments.removeAll()
        if let directory = attachmentDirectory {
            try? FileManager.default.removeItem(at: directory)
        }
        requestIds.values.forEach {
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [$0])
        }
        known.removeAll()
        knownOrder.removeAll()
        requestIds.removeAll()
        postCounts.removeAll()
    }

    private func scheduleLiveFlush() {
        guard liveFlush == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.liveFlush = nil
            let applied = self.liveStore.flush(now: Date())
            for item in applied {
                self.record(NotifyMapping.record(live: item.id, progress: item.progress,
                                                 chip: item.chip, chrono: item.chrono != nil,
                                                 countDown: item.countDown))
            }
            if !applied.isEmpty { self.publishLive() }
            if self.liveStore.hasPending { self.scheduleLiveFlush() }
        }
        liveFlush = work
        DispatchQueue.main.asyncAfter(deadline: .now() + liveStore.interval, execute: work)
    }

    /// A picture was refused, dropped as late, or a live item updated/ended.
    private func publishLive() { onLiveChange?(liveStore.items) }

    private func requestId(phoneId: String, id: String) -> String {
        phoneId.isEmpty ? "pd.\(id)" : "pd.\(phoneId).\(id)"
    }

    /// The poster's app took the notification away: drop the Mac banner too.
    func remove(id: String) {
        // A post still inside its hold is delivered first, so the phone's own
        // post → remove order survives (the banner is then taken away at once).
        if pending[id] != nil { deliver(id: id) }
        if log != nil { record(NotifyMapping.record(removed: id)) }
        pending.removeValue(forKey: id)?.work.cancel()
        if liveStore.end(id) {
            record(NotifyMapping.record(liveEnded: id))
            publishLive()
        }
        dropAttachment(id)
        known.removeValue(forKey: id)
        knownOrder.removeAll { $0 == id }
        postCounts.removeValue(forKey: id)
        if let requestId = requestIds.removeValue(forKey: id) {
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [requestId])
        }
    }

    /// `notify.snapshot` (NOTIFY-1): the phone's complete active set after a
    /// rejoin. A banner, a live row or a post still waiting that the set no
    /// longer holds leaves; the quiet posts before the marker already updated
    /// the rest in place, so nothing here presents a banner.
    func snapshot(ids: [String]) {
        let keep = Set(ids)
        var going = liveStore.items.map(\.id)
        for id in knownOrder where !going.contains(id) { going.append(id) }
        for id in pending.keys where !going.contains(id) { going.append(id) }
        var ended = 0
        for id in going where !keep.contains(id) {
            if liveStore.end(id) {
                record(NotifyMapping.record(liveEnded: id))
                publishLive()
            }
            pending.removeValue(forKey: id)?.work.cancel()
            dropAttachment(id)
            known.removeValue(forKey: id)
            postCounts.removeValue(forKey: id)
            if let requestId = requestIds.removeValue(forKey: id), log == nil {
                UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [requestId])
            }
            record(NotifyMapping.record(snapshotEnded: id))
            ended += 1
        }
        knownOrder.removeAll { !keep.contains($0) }
        record(NotifyMapping.record(snapshot: ids.count, ended: ended))
    }

    /// A banner click (and the `notifyclick` debug action): opens the package's
    /// window through the same routing the UN delegate uses. False when no such
    /// notification is known (yet).
    @discardableResult
    func performOpen(id: String) -> Bool {
        guard let known = known[id] else { return false }
        if log != nil { record(NotifyMapping.record(opened: known.click.pkg, id: id)) }
        onOpen?(known.click)
        return true
    }

    /// `notifyaction` and a real button/reply response. False when the id or the
    /// advertised index is unknown, or the text came on a non-reply action.
    @discardableResult
    func performAction(id: String, index: Int, text: String?) -> Bool {
        guard let known = known[id] else {
            record(NotifyMapping.record(actionUnknown: id, index: index))
            return false
        }
        guard let action = known.actions.first(where: { $0.i == index }) else {
            record(NotifyMapping.record(actionUnknown: id, index: index))
            return false
        }
        let replyText = text.flatMap { $0.isEmpty ? nil : String($0.prefix(4 * 1024)) }
        if replyText != nil, !action.reply {
            record(NotifyMapping.record(actionRefused: id, index: index))
            return false
        }
        record(NotifyMapping.record(action: id, index: index, textLen: replyText?.count ?? 0))
        onAction?(known.click, index, replyText)
        return true
    }

    /// `notifydismiss` and a real banner clear. Ongoing notifications are the
    /// phone's own chrome and are refused here as well.
    @discardableResult
    func performDismiss(id: String) -> Bool {
        guard let known = known[id] else { return false }
        if known.ongoing {
            // Handled (and refused): the driver/UI needs no retry.
            record(NotifyMapping.record(dismissRefused: id))
            return true
        }
        record(NotifyMapping.record(dismissed: id))
        onDismiss?(known.click)
        return true
    }

    /// `notifycopy` and a real Copy code press: only then is the pasteboard written.
    @discardableResult
    func performCopy(id: String) -> Bool {
        guard let known = known[id], let code = known.code else { return false }
        let len = copyService.copy(code)
        record(NotifyMapping.record(copied: id, len: len))
        return true
    }

    /// The per-app mute dropped a post before it was shown.
    func recordMuted(pkg: String, phoneId: String) {
        record(NotifyMapping.record(muted: pkg, phone: phoneId))
    }

    private func remember(_ n: PhoneNotification, click: NotifyClick, code: String?, requestId: String) {
        known[n.id] = Known(click: click, title: n.title, text: n.text,
                            actions: n.actions, code: code, ongoing: n.ongoing,
                            live: n.live, requestId: requestId)
        knownOrder.removeAll { $0 == n.id }
        knownOrder.append(n.id)
        while knownOrder.count > Self.maxKnown {
            let oldest = knownOrder.removeFirst()
            known.removeValue(forKey: oldest)
            postCounts.removeValue(forKey: oldest)
            // The id is going away: its temp file must not outlive it.
            if let url = attachments.removeValue(forKey: oldest) {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    /// The system's permission, read without posting anything: the phone
    /// page's line and its Check Again (NOTIFY-4/17, CONV-MAC-24).
    func authorizationStatus() async -> NotificationAuthorization {
        if let debugAuthorization { return debugAuthorization }
        // A unit-test process (or a bare binary) has no app bundle for
        // UserNotifications to answer for; the permission is not known there.
        guard Bundle.main.bundleURL.pathExtension == "app" else { return .notDetermined }
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral: return .authorized
        case .denied: return .denied
        case .notDetermined: return .notDetermined
        @unknown default: return .notDetermined
        }
    }

    private func postToCenter(_ request: UNNotificationRequest) {
        let center = UNUserNotificationCenter.current()
        if authorized {
            center.add(request)
            return
        }
        guard !registering else { return }
        registering = true
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            // The e2e (and a person reading the log) needs to know whether the
            // system will show anything at all; no content is involved.
            Log.app.notice("notify authorization granted=\(granted, privacy: .public) error=\(error != nil, privacy: .public)")
            DispatchQueue.main.async {
                self.authorized = true
                self.registering = false
                guard granted else { return }
                center.add(request)
            }
        }
    }

    private func record(_ line: String) {
        guard let log else { return }
        let data = Data((line + "\n").utf8)
        if let handle = try? FileHandle(forWritingTo: log) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: log)
        }
    }
}
