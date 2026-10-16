// What the Deck's app grid shows for an icon: the phone's own, a calm
// placeholder while it is on its way, or a generated tile when the phone has
// none. Never pixel art: the fallback is a rounded square with the app's
// initial on a colour that depends only on the package name, so an app looks
// the same every time.

import SwiftUI

/// The adaptive icon layers a phone sent (`icon` message, docs/PROTOCOL.md):
/// the flat PNG stays for every other icon use.
struct AppIconLayers: Equatable {
    var fg: NSImage
    var bg: NSImage
    var mono: NSImage?

    init?(fg: NSImage?, bg: NSImage?, mono: NSImage?) {
        guard let fg, let bg else { return nil }
        self.fg = fg
        self.bg = bg
        self.mono = mono
    }

    static func == (lhs: AppIconLayers, rhs: AppIconLayers) -> Bool {
        lhs.fg == rhs.fg && lhs.bg == rhs.bg && lhs.mono == rhs.mono
    }
}

enum FallbackIcon {
    /// First letter or digit of the label (the package's last part if there is none).
    static func initial(label: String, pkg: String) -> String {
        let source = label.first(where: { $0.isLetter || $0.isNumber }) != nil
            ? label : (pkg.split(separator: ".").last.map(String.init) ?? pkg)
        guard let first = source.first(where: { $0.isLetter || $0.isNumber }) else { return "?" }
        return String(first).uppercased()
    }

    /// 0...1, stable across launches (`hashValue` is seeded per process).
    static func hue(for pkg: String) -> Double {
        var hash: UInt32 = 2_166_136_261 // FNV-1a
        for byte in pkg.utf8 { hash = (hash ^ UInt32(byte)) &* 16_777_619 }
        return Double(hash % 360) / 360
    }
}

struct FallbackAppIcon: View {
    let label: String
    let pkg: String
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let hue = FallbackIcon.hue(for: pkg)
        RoundedRectangle(cornerRadius: 13, style: .continuous)
            .fill(LinearGradient(colors: [Color(hue: hue, saturation: 0.55, brightness: scheme == .dark ? 0.62 : 0.80),
                                          Color(hue: hue, saturation: 0.65, brightness: scheme == .dark ? 0.48 : 0.66)],
                                 startPoint: .top, endPoint: .bottom))
            .overlay {
                Text(FallbackIcon.initial(label: label, pkg: pkg))
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
            }
            .frame(width: 56, height: 56)
    }
}

/// One grid icon: the image, else a quiet placeholder while the phone has not
/// answered yet, else the generated tile.
struct AppIconView: View {
    let app: AppInfo
    let image: NSImage?
    /// The phone is not going to send one (it said so, or the link is down).
    let isMissing: Bool

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().interpolation(.high)
                    .clipShape(.rect(cornerRadius: 13, style: .continuous))
            } else if isMissing {
                FallbackAppIcon(label: app.label, pkg: app.pkg)
            } else {
                RoundedRectangle(cornerRadius: 13, style: .continuous).fill(.quaternary)
            }
        }
        .frame(width: 56, height: 56)
    }
}
