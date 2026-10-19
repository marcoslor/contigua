// Phone notifications on the Mac (docs/design/notify.md). The connected phone's
// notifications appear in Notification Center, grouped per phone; clicking one
// opens that app's window. Content lives only in the notification and the UN
// banner: the recording hooks write field sizes and package names, never text.
//
// With `--share-log` (the e2e mode ShareIn already uses) nothing is posted;
// posts, clicks and removals are recorded in that file instead, so a check can
// see what would have appeared without putting banners on the person's screen.

import AppKit
import Foundation
import UserNotifications

/// One notification as the phone sent it.
struct PhoneNotification: Equatable {
    var id: String
    var pkg: String
    var when: Date?
    var title: String?
    var text: String?
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

    /// Field sizes only — never the text itself (privacy).
    static func record(posted n: PhoneNotification, title: String, body: String, thread: String) -> String {
        "notify post id=\(n.id) pkg=\(n.pkg) titleLen=\(title.count) bodyLen=\(body.count) thread=\(thread)"
    }

    static func record(removed id: String) -> String { "notify remove id=\(id)" }

    static func record(opened: String, id: String) -> String { "notify click id=\(id) pkg=\(opened)" }

    private static func cap(_ s: String?) -> String? {
        guard let s, !s.isEmpty else { return nil }
        return s.count > maxChars ? String(s.prefix(maxChars)) : s
    }
}

/// Posts phone notifications and owns the UN delegate. Share notifications keep
/// their own recording/clicks; this router delegates to the share handler when a
/// share notification comes in, and routes phone-notification clicks to the
/// caller. One delegate for the whole app (macOS keeps the last one set).
final class NotificationRouter: NSObject, UNUserNotificationCenterDelegate {
    static let phoneKind = "pocketdeck.notify.phone"

    /// Share actions' response handling (registered by ConnectionController).
    weak var shareActions: SystemShareActions?
    /// A phone notification was clicked (default action).
    var onOpen: ((String) -> Void)?

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let content = response.notification.request.content
        if content.categoryIdentifier == SystemShareActions.category
            || content.userInfo["file"] is String {
            DispatchQueue.main.async { [weak self] in
                self?.shareActions?.handleShareResponse(response)
            }
        } else if content.userInfo["kind"] as? String == Self.phoneKind,
                  let pkg = content.userInfo["pkg"] as? String,
                  response.actionIdentifier == UNNotificationDefaultActionIdentifier {
            let open = onOpen ?? { _ in }
            DispatchQueue.main.async { open(pkg) }
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
    /// The phone notifications belong to one phone; clicking opens its app window.
    var onOpen: ((String) -> Void)?

    var router = NotificationRouter()

    /// Posted ids -> their package and their UN request identifier, so a click
    /// and a removal can both find them back.
    private var openableIds: [String: String] = [:]
    private var requestIds: [String: String] = [:]
    private var authorized = false
    private var registering = false

    /// Installing the delegate must happen before any notification from either
    /// side; with a log there is nothing to show, so neither happens.
    func install() {
        guard log == nil else { return }
        UNUserNotificationCenter.current().delegate = router
        registerCategories()
    }

    private func registerCategories() {
        let center = UNUserNotificationCenter.current()
        let show = UNNotificationAction(identifier: SystemShareActions.showAction, title: "Show in Finder")
        center.setNotificationCategories([
            UNNotificationCategory(identifier: SystemShareActions.category, actions: [show], intentIdentifiers: []),
        ])
    }

    /// Posts one phone notification; the thread groups them under the phone's id.
    func post(_ n: PhoneNotification, phoneId: String, phoneName: String, labelFor: (String) -> String?) {
        let (title, body) = NotifyMapping.content(n, phoneName: phoneName, labelFor: labelFor)
        openableIds[n.id] = n.pkg
        let requestId = "pd.\(phoneId).\(n.id)"
        requestIds[n.id] = requestId
        if log != nil {
            record(NotifyMapping.record(posted: n, title: title, body: body, thread: phoneId))
            return
        }
        let content = UNMutableNotificationContent()
        content.title = title
        if !body.isEmpty { content.body = body }
        content.threadIdentifier = phoneId
        content.sound = nil
        content.userInfo = ["kind": NotificationRouter.phoneKind, "pkg": n.pkg]
        let request = UNNotificationRequest(identifier: requestId, content: content, trigger: nil)
        postToCenter(request)
    }

    /// The poster's app took the notification away: drop the Mac banner too.
    func remove(id: String) {
        if log != nil { record(NotifyMapping.record(removed: id)) }
        if let requestId = requestIds.removeValue(forKey: id) {
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [requestId])
        }
    }

    /// A banner click (and the `notifyclick` debug action): opens the package's
    /// window through the same routing the UN delegate uses. False when no such
    /// notification is known (yet).
    @discardableResult
    func performOpen(id: String) -> Bool {
        guard let pkg = openableIds[id] else { return false }
        if log != nil { record(NotifyMapping.record(opened: pkg, id: id)) }
        onOpen?(pkg)
        return true
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
