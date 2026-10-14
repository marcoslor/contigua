// Links Mac → phone (docs/design/links.md): which URLs may be sent, how the
// `pocketdeck://open` scheme and the Services/drag inputs map to a request, and
// which phone a request goes to.

import AppKit

enum LinkPolicy {
    static let allowedSchemes: Set<String> = ["http", "https", "geo", "tel", "mailto"]
    /// UTF-8 bytes; the phone applies the same limit.
    static let maxBytes = 8 * 1024

    /// The trimmed URL when the phone may open it, else nil. Mirrors the
    /// phone's `LinkPolicy` (the phone re-checks; it never trusts the Mac).
    static func validate(_ raw: String?) -> String? {
        guard let url = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !url.isEmpty, url.utf8.count <= maxBytes else { return nil }
        if url.unicodeScalars.contains(where: {
            CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0)
        }) { return nil }
        guard let colon = url.firstIndex(of: ":"), colon > url.startIndex else { return nil }
        let scheme = url[..<colon]
        guard let first = scheme.unicodeScalars.first, first.isASCIILetter,
              scheme.unicodeScalars.allSatisfy({ $0.isASCIILetter || $0.isASCIIDigit || "+-.".unicodeScalars.contains($0) })
        else { return nil }
        let lower = scheme.lowercased()
        guard allowedSchemes.contains(lower) else { return nil }
        let rest = url[url.index(after: colon)...]
        if lower == "http" || lower == "https" {
            guard rest.hasPrefix("//") else { return nil }
            var host = rest.dropFirst(2).prefix { $0 != "/" && $0 != "?" && $0 != "#" }
            if let at = host.lastIndex(of: "@") { host = host[host.index(after: at)...] }
            if let port = host.firstIndex(of: ":") { host = host[..<port] }
            guard !host.isEmpty else { return nil }
        } else if rest.isEmpty {
            return nil
        }
        return url
    }
}

private extension Unicode.Scalar {
    var isASCIILetter: Bool { ("a"..."z").contains(self) || ("A"..."Z").contains(self) }
    var isASCIIDigit: Bool { ("0"..."9").contains(self) }
}

/// One link to open, optionally on a named phone.
struct OpenLinkRequest: Equatable {
    var url: String
    var deviceId: String?

    static let scheme = "pocketdeck"

    /// `pocketdeck://open?url=<encoded>[&phone=<deviceId>]`.
    static func parse(schemeURL: URL) -> OpenLinkRequest? {
        guard let components = URLComponents(url: schemeURL, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == scheme, components.host?.lowercased() == "open"
        else { return nil }
        let items = components.queryItems ?? []
        guard let url = LinkPolicy.validate(items.first { $0.name == "url" }?.value) else { return nil }
        let phone = items.first { $0.name == "phone" }?.value.flatMap { $0.isEmpty ? nil : $0 }
        return OpenLinkRequest(url: url, deviceId: phone)
    }

    /// The scheme URL for a link (used by tests and anything that forwards links to the app).
    static func schemeURL(for url: String, deviceId: String? = nil) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "open"
        components.queryItems = [URLQueryItem(name: "url", value: url)]
            + (deviceId.map { [URLQueryItem(name: "phone", value: $0)] } ?? [])
        return components.url
    }

    /// A link from a pasteboard (Services, drag): a URL item, else text holding one URL.
    static func from(pasteboard: NSPasteboard) -> OpenLinkRequest? {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] {
            for url in urls {
                if url.isFileURL, let webloc = webloc(at: url) { return OpenLinkRequest(url: webloc) }
                if let valid = LinkPolicy.validate(url.absoluteString) { return OpenLinkRequest(url: valid) }
            }
        }
        if let text = pasteboard.string(forType: .string), let valid = LinkPolicy.validate(text) {
            return OpenLinkRequest(url: valid)
        }
        return nil
    }

    /// The link inside a `.webloc` file (Safari drags a link out as one).
    static func webloc(at file: URL) -> String? {
        guard file.pathExtension.lowercased() == "webloc",
              let data = try? Data(contentsOf: file),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        return LinkPolicy.validate(plist["URL"] as? String)
    }
}

/// Which phone a link goes to.
enum LinkRoute: Equatable {
    /// Open on this phone (switching to it first when it isn't the connected one).
    case open(deviceId: String)
    /// Several phones and none named: ask, the connected one first.
    case pick([String])
    /// No paired phone: keep the link until a phone becomes ready.
    case wait

    static func route(requested: String?, remembered: [String], online: String?) -> LinkRoute {
        if let requested, remembered.contains(requested) { return .open(deviceId: requested) }
        switch remembered.count {
        case 0: return .wait
        case 1: return .open(deviceId: remembered[0])
        default:
            guard let online, remembered.contains(online) else { return .pick(remembered) }
            return .pick([online] + remembered.filter { $0 != online })
        }
    }
}

/// "Open on which phone?": a small modal with the remembered phones, the first preselected.
enum PhonePicker {
    @MainActor
    static func choose(_ phones: [RememberedPhone], title: String, detail: String) -> String? {
        guard !phones.isEmpty else { return nil }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 260, height: 26), pullsDown: false)
        popup.addItems(withTitles: phones.map(\.name))
        alert.accessoryView = popup
        alert.addButton(withTitle: "Open")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return phones[popup.indexOfSelectedItem].id
    }
}

/// The "Open on Phone" Services entry (`NSServices` in Info.plist: `openOnPhone`).
final class LinkService: NSObject {
    static let shared = LinkService()

    @MainActor @objc
    func openOnPhone(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        guard let request = OpenLinkRequest.from(pasteboard: pasteboard) else {
            error.pointee = "Only http, https, geo, tel and mailto links can be opened on the phone." as NSString
            return
        }
        AppEnvironment.shared.controller.openLink(request)
    }
}
