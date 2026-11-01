// The window's picture state and its one presentation (docs/specs/app-windows.md
// WIN-39): a live picture, a stall (WIN-17), and the link's two down steps
// (WIN-16). The overlay is what a stalled picture or a dropped link looks like —
// the last frame under one acrylic that reaches over the framed bar, the
// window's icon, the title and "Waiting for <phone>…" — so there are no
// parallel flags: the machine's state is the truth, and the controller runs its
// actions. Time stays outside (the window's 0.25 s tick feeds it), so every
// edge is pinned by a test with a fake clock.

import AppKit

/// The picture's closed set of states.
struct PictureState: Equatable {
    enum State: Equatable {
        case live
        case stalled
        /// The first second of a dropped link: a blip says nothing.
        case linkBlip
        case reconnecting
        case offline
    }

    enum Event: Equatable {
        /// The watchdog's answer: silence long enough to call it, or a frame.
        case stall(Bool)
        case linkDown
        case linkUp
        case tick(TimeInterval)
    }

    /// What the presentation does. The transition performs none of them.
    enum Action: Equatable {
        case present(StallOverlayKind)
        case dismiss
    }

    /// WIN-16: "Reconnecting…" 1 s after the drop, "Phone offline" at 15 s.
    static let reconnectAfter: TimeInterval = 1
    static let offlineAfter: TimeInterval = 15

    private(set) var state: State = .live
    /// When the link dropped, so a late tick lands on the right step instead of
    /// restarting the clock.
    private(set) var downSince: TimeInterval?

    init() {}

    var isStalled: Bool { state == .stalled }

    var isLinkDown: Bool {
        switch state {
        case .linkBlip, .reconnecting, .offline: return true
        case .live, .stalled: return false
        }
    }

    /// What the overlay says, or nil while it is down.
    var overlay: StallOverlayKind? {
        switch state {
        case .stalled: return .stalled
        case .reconnecting: return .reconnecting
        case .offline: return .offline
        case .live, .linkBlip: return nil
        }
    }

    /// The machine's one transition. nil means the event is ignored in this
    /// state (the same state and no actions): the caller then logs nothing.
    mutating func handle(_ event: Event, at now: TimeInterval) -> [Action]? {
        let (next, downSince, actions) = Self.transition(state, event, downSince: downSince, now: now)
        guard next != state || downSince != self.downSince else { return nil }
        state = next
        self.downSince = downSince
        return actions
    }

    static func transition(_ state: State, _ event: Event, downSince: TimeInterval?,
                           now: TimeInterval) -> (State, TimeInterval?, [Action]) {
        switch state {
        case .live:
            switch event {
            case .stall(true):
                return (.stalled, nil, [.present(.stalled)])
            case .stall(false), .linkUp, .tick:
                return (state, downSince, [])
            case .linkDown:
                // Nothing on screen for the first second: a blip is not news.
                return (.linkBlip, now, [])
            }
        case .stalled:
            switch event {
            case .stall(false):
                return (.live, nil, [.dismiss])
            case .stall(true), .tick:
                return (state, downSince, [])
            case .linkDown:
                // The link is the reason now; the stall is not shown again
                // until the link is back.
                return (.linkBlip, now, [.dismiss])
            case .linkUp:
                return (state, downSince, [])
            }
        case .linkBlip:
            switch event {
            case .tick(let time):
                guard let downSince else { return (.reconnecting, now, [.present(.reconnecting)]) }
                if time - downSince >= offlineAfter {
                    return (.offline, downSince, [.present(.offline)])
                }
                if time - downSince >= reconnectAfter {
                    return (.reconnecting, downSince, [.present(.reconnecting)])
                }
                return (state, downSince, [])
            case .linkUp:
                return (.live, nil, [])
            case .linkDown:
                // Already down: the drop's clock does not restart.
                return (state, downSince, [])
            case .stall:
                return (state, downSince, [])
            }
        case .reconnecting:
            switch event {
            case .tick(let time):
                guard let downSince, time - downSince >= offlineAfter else {
                    return (state, downSince, [])
                }
                return (.offline, downSince, [.present(.offline)])
            case .linkUp:
                return (.live, nil, [.dismiss])
            case .stall, .linkDown:
                return (state, downSince, [])
            }
        case .offline:
            switch event {
            case .linkUp:
                return (.live, nil, [.dismiss])
            case .stall, .linkDown, .tick:
                return (state, downSince, [])
            }
        }
    }

    /// The state's name for the transition log.
    static func label(_ state: State) -> String {
        switch state {
        case .live: return "live"
        case .stalled: return "stalled"
        case .linkBlip: return "link-down"
        case .reconnecting: return "reconnecting"
        case .offline: return "offline"
        }
    }
}

/// What the overlay says, so the words live in one place.
enum StallOverlayKind: Equatable {
    case stalled
    case reconnecting
    case offline

    var title: String {
        switch self {
        case .stalled: return "Not responding"
        case .reconnecting: return "Reconnecting…"
        case .offline: return "Phone offline"
        }
    }
}

/// The two lines the overlay draws.
struct StallOverlayDisplay: Equatable {
    let title: String
    let secondary: String

    init(kind: StallOverlayKind, phone: String) {
        title = kind.title
        // The person's own name for the phone when it has one.
        secondary = "Waiting for \(phone.isEmpty ? "your phone" : phone)…"
    }
}

/// The overlay's ink and the acrylic it is measured against. The ground is the
/// acrylic's average colour behind the words, measured from the review shots
/// (`.agent/stall-overlay/stall-stalled-{dark,light}.png`) over the fake phone's
/// colour-bar frame; the secondary line must keep WCAG AA 4.5:1 against it.
struct StallOverlayStyle: Equatable {
    let name: String
    /// The black sheet over the blur. S1/S3's 0.38 in dark; the light material
    /// is bright, so light mode dims deeper or no ink can reach 4.5:1 behind
    /// the line (the prototype's 0.38 sheet measured 3.6:1 with pure white).
    let dimAlpha: CGFloat
    let ground: NSColor
    let title: NSColor
    let secondary: NSColor
    let iconTint: NSColor

    static let dark = StallOverlayStyle(
        name: "dark",
        dimAlpha: 0.38,
        ground: NSColor(srgbRed: 0x40 / 255, green: 0x41 / 255, blue: 0x42 / 255, alpha: 1),
        title: NSColor(white: 0.94, alpha: 1),
        secondary: NSColor(white: 0.74, alpha: 1),
        iconTint: NSColor(white: 0.92, alpha: 1))

    /// The light acrylic takes white ink: on the deeper sheet it is the only
    /// ink with the margin AA wants, so the title and the secondary line share
    /// it and the hierarchy is size and weight.
    static let light = StallOverlayStyle(
        name: "light",
        dimAlpha: 0.50,
        ground: NSColor(srgbRed: 0x63 / 255, green: 0x62 / 255, blue: 0x61 / 255, alpha: 1),
        title: NSColor(white: 1, alpha: 1),
        secondary: NSColor(white: 1, alpha: 1),
        iconTint: NSColor(white: 0.92, alpha: 1))

    static func style(for appearance: NSAppearance) -> StallOverlayStyle {
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light
    }

    /// WCAG 2.1 contrast of two opaque colours (1…21).
    static func contrast(_ a: NSColor, _ b: NSColor) -> Double {
        let la = luminance(a)
        let lb = luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    /// WCAG 2.1 relative luminance of an sRGB colour.
    static func luminance(_ color: NSColor) -> Double {
        guard let rgb = color.usingColorSpace(.sRGB) else { return 0 }
        func channel(_ value: CGFloat) -> Double {
            let c = Double(value)
            return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(rgb.redComponent) + 0.7152 * channel(rgb.greenComponent)
            + 0.0722 * channel(rgb.blueComponent)
    }

    var titleContrast: Double { Self.contrast(title, ground) }
    var secondaryContrast: Double { Self.contrast(secondary, ground) }
}

/// The disconnection screen (WIN-39): the last frame blurred and dimmed by one
/// acrylic that reaches over the framed bar, with the icon, the title and the
/// waiting line centred in the body. It takes every click that is not the bar's
/// and sends nothing to the phone; it offers no buttons.
final class StallOverlayView: NSView {
    private let blur = NSVisualEffectView()
    private let dim = NSView()
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let secondaryLabel = NSTextField(labelWithString: "")
    private(set) var style = StallOverlayStyle.dark
    /// The icon the window passed, not the placeholder: the chrome state and
    /// the tests read whether the app's own icon had arrived.
    private(set) var iconImage: NSImage?
    /// The framed bar's height: the words stay centred in the body, which is
    /// the window less the bar the overlay reaches over.
    var topInset: CGFloat = 0 {
        didSet { if topInset != oldValue { needsLayout = true } }
    }

    var isShowing: Bool { !isHidden }
    var hasIcon: Bool { iconImage != nil }
    var titleText: String { titleLabel.stringValue }
    var secondaryText: String { secondaryLabel.stringValue }
    var secondaryColor: NSColor { secondaryLabel.textColor ?? .clear }

    /// The opening cover's icon metrics: the same picture at the same size.
    static let iconSide: CGFloat = 96
    static let iconCornerRadius: CGFloat = 22
    private static let textInset: CGFloat = 32
    private static let iconGap: CGFloat = 16
    private static let lineGap: CGFloat = 8

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        blur.material = .hudWindow
        blur.blendingMode = .withinWindow
        blur.state = .active
        blur.autoresizingMask = [.width, .height]
        addSubview(blur)
        // A dim over the blur so white text keeps its contrast over any frame.
        dim.wantsLayer = true
        dim.autoresizingMask = [.width, .height]
        addSubview(dim)

        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.wantsLayer = true
        iconView.layer?.cornerRadius = Self.iconCornerRadius
        iconView.layer?.cornerCurve = .continuous
        iconView.layer?.masksToBounds = true
        addSubview(iconView)

        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        titleLabel.alignment = .center
        titleLabel.lineBreakMode = .byTruncatingTail
        addSubview(titleLabel)

        secondaryLabel.font = .systemFont(ofSize: 12.5)
        secondaryLabel.alignment = .center
        secondaryLabel.maximumNumberOfLines = 0
        secondaryLabel.lineBreakMode = .byWordWrapping
        secondaryLabel.cell?.wraps = true
        addSubview(secondaryLabel)

        applyAppearanceStyle()
        // The measured ratio is a design constant: the field log keeps it
        // beside the shots the reviewer checks it against.
        let contrast = style.secondaryContrast
        Log.video.info("stall overlay: secondary contrast \(contrast)")  // log-ok: a design constant, no person's data
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }  // unrecoverable: NSCoder is never used

    override var isOpaque: Bool { false }

    /// Shows the screen for `display`, or takes it away.
    func show(_ display: StallOverlayDisplay, icon: NSImage?) {
        iconImage = icon
        titleLabel.stringValue = display.title
        secondaryLabel.stringValue = display.secondary
        // Before the app's icon has arrived, the same generic app mark the
        // opening cover uses keeps the one large picture.
        iconView.image = icon ?? NSImage(systemSymbolName: "app.dashed", accessibilityDescription: nil)
        isHidden = false
        applyAppearanceStyle()
        needsLayout = true
    }

    func hide() {
        isHidden = true
    }

    /// The acrylic is one sheet in either appearance; the ink follows it.
    func applyAppearanceStyle() {
        style = StallOverlayStyle.style(for: effectiveAppearance)
        dim.layer?.backgroundColor = NSColor.black.withAlphaComponent(style.dimAlpha).cgColor
        titleLabel.textColor = style.title
        secondaryLabel.textColor = style.secondary
        iconView.contentTintColor = style.iconTint
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyAppearanceStyle()
    }

    override func layout() {
        super.layout()
        blur.frame = bounds
        dim.frame = bounds
        let bodyHeight = max(bounds.height - topInset, 0)
        let titleHeight = titleLabel.intrinsicContentSize.height
        let secondaryHeight = ceil(secondaryLabel.cell?.cellSize(
            forBounds: NSRect(x: 0, y: 0, width: bounds.width - Self.textInset * 2, height: 400)).height ?? 16)
        let total = Self.iconSide + Self.iconGap + titleHeight + Self.lineGap + secondaryHeight
        var y = topInset + (bodyHeight + total) / 2
        y -= Self.iconSide
        iconView.frame = NSRect(x: (bounds.width - Self.iconSide) / 2, y: y,
                                width: Self.iconSide, height: Self.iconSide)
        y -= Self.iconGap + titleHeight
        titleLabel.frame = NSRect(x: Self.textInset, y: y, width: bounds.width - Self.textInset * 2,
                                  height: titleHeight)
        y -= Self.lineGap + secondaryHeight
        secondaryLabel.frame = NSRect(x: Self.textInset, y: y, width: bounds.width - Self.textInset * 2,
                                      height: secondaryHeight)
    }

    /// The screen takes every click: the stream is frozen and the phone must
    /// never see a click meant for the overlay.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, let superview else { return nil }
        guard bounds.contains(convert(point, from: superview)) else { return nil }
        return self
    }

    override func mouseDown(with event: NSEvent) {
        // A frozen window: a click on the screen is not a click on the stream.
    }
}
