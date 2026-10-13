// Synthetic data for `--preview STATE` (screenshots of states that cannot be
// staged against a fake phone). Never used on a normal launch.

import AppKit

enum PreviewData {
    private static let names = ["Camera", "Chrome", "Gallery", "Gmail", "Maps", "Messages", "Phone",
                                "Play Store", "Settings", "Spotify", "Telegram", "WhatsApp", "YouTube", "Clock"]

    static let apps: [AppInfo] = names.compactMap {
        AppInfo(json: ["pkg": "preview.\($0.lowercased().replacingOccurrences(of: " ", with: ""))", "label": $0])
    }

    static let icons: [String: NSImage] = {
        var result: [String: NSImage] = [:]
        for (index, app) in apps.enumerated() { result[app.pkg] = icon(letter: app.label.first ?? "?", index: index) }
        return result
    }()

    static let nearby: [DiscoveredPhone] = [
        DiscoveredPhone(serviceName: "Pixel 9", deviceId: "preview", name: "Pixel 9", model: "Pixel 9", version: "1",
                        endpoint: .service(name: "Pixel 9", type: "_pocketdeck._tcp", domain: "local", interface: nil)),
        DiscoveredPhone(serviceName: "Galaxy S25+", deviceId: "preview-2", name: "Galaxy S25+", model: "SM-S936B",
                        version: "1",
                        endpoint: .service(name: "Galaxy S25+", type: "_pocketdeck._tcp", domain: "local", interface: nil)),
    ]

    private static func icon(letter: Character, index: Int) -> NSImage {
        let hues: [CGFloat] = [0.58, 0.08, 0.35, 0.0, 0.3, 0.6, 0.85, 0.75, 0.55, 0.38, 0.5, 0.12, 0.02, 0.68]
        let size = NSSize(width: 96, height: 96)
        return NSImage(size: size, flipped: false) { rect in
            NSColor(hue: hues[index % hues.count], saturation: 0.55, brightness: 0.85, alpha: 1).setFill()
            rect.fill()
            let text = String(letter) as NSString
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 52, weight: .semibold), .foregroundColor: NSColor.white,
            ]
            let textSize = text.size(withAttributes: attributes)
            text.draw(at: NSPoint(x: (rect.width - textSize.width) / 2, y: (rect.height - textSize.height) / 2),
                      withAttributes: attributes)
            return true
        }
    }
}
