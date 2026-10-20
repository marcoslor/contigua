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

/// One notification as the phone sent it.
struct PhoneNotification: Equatable {
    var id: String
    var pkg: String
    var when: Date?
    var title: String?
    var text: String?
    var ongoing: Bool = false
    var actions: [NotifyActionInfo] = []
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

    /// The banner shows `[title, body]`; a missing title falls back to the app's
    /// label, and a body only carries the notification's own text.
    static func content(_ n: PhoneNotification,
                        phoneName: String,
                        labelFor: (String) -> String?) -> (title: String, body: String) {
        let label = labelFor(n.pkg)
        let own = cap(n.title)
        let title = Self.title(own ?? label, phoneName: phoneName)
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

    /// Field sizes and counts only — never the text itself (privacy). The
    /// category id is a hash of the shape, so the e2e can see the counts.
    static func record(posted n: PhoneNotification, title: String, body: String,
                       thread: String, code: Bool, category: String) -> String {
        let reply = n.actions.contains { $0.reply } ? 1 : 0
        return "notify post id=\(n.id) pkg=\(n.pkg) titleLen=\(title.count) bodyLen=\(body.count)"
            + " thread=\(thread) actions=\(n.actions.count) reply=\(reply) code=\(code ? 1 : 0)"
            + " ongoing=\(n.ongoing ? 1 : 0) category=\(category)"
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
    static let phoneKind = "pocketdeck.notify.phone"

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

    /// What a banner response or a debug action needs, kept for the ids the
    /// phone issued. Bounded like the wire's own id map.
    private struct Known {
        var click: NotifyClick
        var title: String?
        var text: String?
        var actions: [NotifyActionInfo]
        var code: String?
        var ongoing: Bool
    }

    private var known: [String: Known] = [:]
    private var knownOrder: [String] = []
    private var requestIds: [String: String] = [:]
    private var authorized = false
    private var registering = false

    private static let maxKnown = 200

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
    func post(_ n: PhoneNotification, phoneId: String, phoneName: String, labelFor: (String) -> String?) {
        let (title, body) = NotifyMapping.content(n, phoneName: phoneName, labelFor: labelFor)
        let code = NotifyCode.find(title: n.title, text: n.text)
        remember(PhoneNotification(id: n.id, pkg: n.pkg, when: n.when, title: n.title, text: n.text,
                                   ongoing: n.ongoing, actions: n.actions),
                 click: NotifyClick(id: n.id, pkg: n.pkg, phoneId: phoneId),
                 code: code)
        let shape = NotifyCategories.identifier(
            titles: n.actions.map(\.title),
            reply: n.actions.contains { $0.reply },
            code: code != nil,
        )
        if log != nil {
            record(NotifyMapping.record(posted: n, title: title, body: body, thread: phoneId,
                                        code: code != nil, category: shape))
            return
        }
        let category = categories.category(for: n, hasCode: code != nil)
        let requestId = "pd.\(phoneId).\(n.id)"
        requestIds[n.id] = requestId
        let content = UNMutableNotificationContent()
        content.title = title
        if !body.isEmpty { content.body = body }
        content.threadIdentifier = phoneId
        content.sound = nil
        content.categoryIdentifier = category
        content.userInfo = ["kind": NotificationRouter.phoneKind, "pkg": n.pkg, "id": n.id, "phone": phoneId]
        let request = UNNotificationRequest(identifier: requestId, content: content, trigger: nil)
        postToCenter(request)
    }

    /// The poster's app took the notification away: drop the Mac banner too.
    func remove(id: String) {
        if log != nil { record(NotifyMapping.record(removed: id)) }
        known.removeValue(forKey: id)
        knownOrder.removeAll { $0 == id }
        if let requestId = requestIds.removeValue(forKey: id) {
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [requestId])
        }
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

    private func remember(_ n: PhoneNotification, click: NotifyClick, code: String?) {
        known[n.id] = Known(click: click, title: n.title, text: n.text,
                            actions: n.actions, code: code, ongoing: n.ongoing)
        knownOrder.removeAll { $0 == n.id }
        knownOrder.append(n.id)
        while knownOrder.count > Self.maxKnown {
            let oldest = knownOrder.removeFirst()
            known.removeValue(forKey: oldest)
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
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
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
