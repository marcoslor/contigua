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

/// The tile's pure geometry and the variant a grid icon renders
/// (docs/DESIGN.md "The app grid"). Every tile draws the shared renderer's
/// output (docs/design/dock.md §Icons): the macOS squircle, the adaptive
/// layers at full opacity or the flat icon drawn by its own shape. Until that
/// render lands, the tile shows the placeholder or the generated fallback —
/// never the bare flat image.
enum GlassIcon {
    static let tileSide: CGFloat = 56
    static let cornerFraction: CGFloat = 0.225

    static var cornerRadius: CGFloat { tileSide * cornerFraction }

    /// The central 2/3 of a square canvas. An adaptive icon draws its whole
    /// 108 dp layer on a 216 px canvas; only the central 72 dp are meant to
    /// show.
    static func cropRect(canvas: CGFloat) -> CGRect {
        let inset = canvas / 6
        return CGRect(x: inset, y: inset, width: canvas - 2 * inset, height: canvas - 2 * inset)
    }

    /// The crop as a scale: the whole 108 dp layer is drawn at 1.5x the tile,
    /// so its central 2/3 covers the tile.
    static let zoomFactor: CGFloat = 3 / 2

    /// What the grid draws for one app cell. The phone's flat reply is never a
    /// variant by itself: the tile draws only the renderer's image.
    enum Variant: Equatable {
        /// The shared renderer's icon (macOS shape, the phone's colours).
        case rendered(NSImage)
        /// Quietly waiting for the phone's answer or the render.
        case placeholder
        /// The phone said the icon does not exist.
        case fallback
    }

    static func variant(rendered: NSImage?, isMissing: Bool) -> Variant {
        guard let rendered else { return isMissing ? .fallback : .placeholder }
        return .rendered(rendered)
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
    var side: CGFloat = GlassIcon.tileSide
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
            .frame(width: side, height: side)
    }
}

/// One grid icon: the shared renderer's image (docs/design/dock.md §Icons),
/// already shaped, so the tile only scales it — no material over the colours,
/// a small lift on hover. Until it lands: the quiet placeholder, or the
/// generated tile when the phone has none.
struct AppIconView: View {
    let app: AppInfo
    /// The renderer's output at the tile's size (`ConnectionController.deckIcons`).
    private(set) var rendered: NSImage?
    /// The phone is not going to send one (it said so, or the link is down).
    private(set) var isMissing: Bool
    /// The pointer is over the cell: the tile responds to it.
    private(set) var hovering = false
    /// The tile's side in points (the grid's 64 pt at 100 %, scaled by zoom).
    private(set) var side = GlassIcon.tileSide

    init(app: AppInfo, rendered: NSImage? = nil,
         isMissing: Bool = false, hovering: Bool = false,
         side: CGFloat = GlassIcon.tileSide) {
        self.app = app
        self.rendered = rendered
        self.isMissing = isMissing
        self.hovering = hovering
        self.side = side
    }

    var body: some View {
        Group {
            switch GlassIcon.variant(rendered: rendered, isMissing: isMissing) {
            case .rendered(let rendered):
                Image(nsImage: rendered).resizable().interpolation(.high)
                    .scaleEffect(hovering ? 1.04 : 1)
            case .placeholder:
                RoundedRectangle(cornerRadius: 13, style: .continuous).fill(.quaternary)
            case .fallback:
                FallbackAppIcon(label: app.label, pkg: app.pkg, side: side)
            }
        }
        .frame(width: side, height: side)
    }
}
