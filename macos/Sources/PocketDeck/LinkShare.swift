// Link code shared by the app, its Share extension (Extensions/Share) and the e2e
// share driver: Foundation/AppKit only, no app state. See docs/design/links.md.

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


/// The link in what a person shared: the first web/geo/tel/mailto URL item, else
/// text that is a URL or contains exactly one.
enum ShareInput {
    /// `values` are what the share sheet's item providers loaded (URL, String,
    /// NSAttributedString or UTF-8 Data), in order.
    static func link(from values: [Any]) -> String? {
        let urls = values.compactMap { value -> URL? in
            switch value {
            case let url as URL: return url
            case let url as NSURL: return url as URL
            default: return nil
            }
        }
        for url in urls where !url.isFileURL {
            if let valid = LinkPolicy.validate(url.absoluteString) { return valid }
        }
        for value in values {
            if let text = text(value), let link = link(inText: text) { return link }
        }
        return nil
    }

    private static func text(_ value: Any) -> String? {
        switch value {
        case let string as String: return string
        case let attributed as NSAttributedString: return attributed.string
        case let data as Data: return String(data: data, encoding: .utf8)
        default: return nil
        }
    }

    /// The whole text when it is a link, else the single link a data detector finds in it.
    static func link(inText text: String) -> String? {
        if let whole = LinkPolicy.validate(text) { return whole }
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        let found = detector.matches(in: text, range: range).compactMap { match in
            match.url.flatMap { $0.isFileURL ? nil : LinkPolicy.validate($0.absoluteString) }
        }
        return found.count == 1 ? found[0] : nil
    }
}

/// Extension → app: `pocketdeck://open?url=…` opened *with the containing app*,
/// so LaunchServices cannot hand it to another PocketDeck copy.
enum ShareHandoff {
    static func schemeURL(for url: String, deviceId: String? = nil) -> URL? {
        var components = URLComponents()
        components.scheme = "pocketdeck"
        components.host = "open"
        components.queryItems = [URLQueryItem(name: "url", value: url)]
            + (deviceId.map { [URLQueryItem(name: "phone", value: $0)] } ?? [])
        return components.url
    }

    /// The app bundle around an extension: `X.app/Contents/PlugIns/Y.appex` → `X.app`.
    static func containingApp(ofExtension bundle: URL) -> URL {
        bundle.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    static func send(_ link: String, toApp app: URL, completion: @escaping @Sendable (Error?) -> Void) {
        guard let url = schemeURL(for: link) else { completion(CocoaError(.fileReadInvalidFileName)); return }
        let configuration = NSWorkspace.OpenConfiguration()
        // Plumbing, not a person's window: bringing PocketDeck forward would
        // pull the person out of the app they were sharing from (the link opens
        // on the phone). The app's own link path decides what to show.
        configuration.activates = false
        NSWorkspace.shared.open([url], withApplicationAt: app, configuration: configuration) { _, error in
            completion(error)
        }
    }
}
