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

/// The glass tile's pure geometry and the variant a grid icon renders
/// (docs/DESIGN.md "The app grid"). The tile is a continuous squircle at
/// 22.5 % of its side; a layered (adaptive) icon is cropped to the central
/// 2/3 of its 216 px canvas (the 72 dp visible area of the 108 dp canvas)
/// and laid over the glass; a flat icon sits inset at 78 % of the side.
enum GlassIcon {
    static let tileSide: CGFloat = 56
    static let cornerFraction: CGFloat = 0.225
    static let flatInsetFraction: CGFloat = 0.78

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

    static var flatSide: CGFloat { tileSide * flatInsetFraction }

    /// What the grid draws for one app cell, in order of what the phone sent
    /// and the setting's state.
    enum Variant: Equatable {
        /// The glass tile, tinted with the cropped `bg` under the material
        /// and the cropped `fg` on top.
        case adaptiveTile(AppIconLayers)
        /// The glass tile, the flat image inset at 78 %, no tint.
        case flatTile(NSImage)
        /// Setting off: today's flat look.
        case bare(NSImage)
        /// Quietly waiting for the phone's answer.
        case placeholder
        /// The phone said the icon does not exist.
        case fallback
    }

    static func variant(layers: AppIconLayers?, image: NSImage?,
                        isMissing: Bool, glassOn: Bool) -> Variant {
        guard let image else { return isMissing ? .fallback : .placeholder }
        if glassOn { return layers.map { .adaptiveTile($0) } ?? .flatTile(image) }
        return .bare(image)
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

/// One grid icon. With the setting on: a Liquid Glass tile (docs/DESIGN.md
/// "The app grid") — an adaptive icon tints the glass with its cropped
/// `bg` layer and its `fg` sits on top; a flat icon is centred at 78 % of
/// the tile. With it off: today's look exactly (the flat image, the
/// generated tile or the quiet placeholder).
struct AppIconView: View {
    let app: AppInfo
    let image: NSImage?
    private(set) var layers: AppIconLayers?
    /// The phone is not going to send one (it said so, or the link is down).
    private(set) var isMissing: Bool
    private(set) var glassOn: Bool
    /// The pointer is over the cell: the tile responds to it.
    private(set) var hovering = false

    init(app: AppInfo, image: NSImage?, layers: AppIconLayers? = nil,
         isMissing: Bool = false, glassOn: Bool = true, hovering: Bool = false) {
        self.app = app
        self.image = image
        self.layers = layers
        self.isMissing = isMissing
        self.glassOn = glassOn
        self.hovering = hovering
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: GlassIcon.cornerRadius, style: .continuous)
    }

    var body: some View {
        switch GlassIcon.variant(layers: layers, image: image, isMissing: isMissing, glassOn: glassOn) {
        case .adaptiveTile(let layers):
            ZStack {
                cropped(layers.bg).opacity(0.35)
                cropped(layers.fg)
            }
            .frame(width: GlassIcon.tileSide, height: GlassIcon.tileSide)
            .clipShape(shape)
            .glassEffect(hovering ? .regular.interactive() : .regular, in: shape)
        case .flatTile(let image):
            Image(nsImage: image).resizable().interpolation(.high)
                .frame(width: GlassIcon.flatSide, height: GlassIcon.flatSide)
                .frame(width: GlassIcon.tileSide, height: GlassIcon.tileSide)
                .glassEffect(hovering ? .regular.interactive() : .regular, in: shape)
        case .bare(let image):
            Image(nsImage: image).resizable().interpolation(.high)
                .clipShape(.rect(cornerRadius: 13, style: .continuous))
        case .placeholder:
            RoundedRectangle(cornerRadius: 13, style: .continuous).fill(.quaternary)
        case .fallback:
            FallbackAppIcon(label: app.label, pkg: app.pkg)
        }
    }

    /// A 108 dp layer drawn so its central 2/3 (the 72 dp visible area of the
    /// 216 px canvas) covers the tile: the layer is scaled up once and a half
    /// and centred, and the squircle above clips whatever reaches past it.
    private func cropped(_ layer: NSImage) -> some View {
        Image(nsImage: layer)
            .resizable().interpolation(.high)
            .frame(width: GlassIcon.tileSide * GlassIcon.zoomFactor,
                   height: GlassIcon.tileSide * GlassIcon.zoomFactor)
    }
}
