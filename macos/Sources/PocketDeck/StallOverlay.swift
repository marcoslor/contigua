// The window's picture state and its one presentation (docs/specs/app-windows.md
// WIN-39): a live picture, a stall (WIN-17), and the link's two down steps
// (WIN-16). The overlay is what a stalled picture or a dropped link looks like —
// the shared frosted cover (WIN-65) over the last frame, the window's icon, the
// title and "Waiting for <phone>…" — so there are no parallel flags: the
// machine's state is the truth, and the controller runs its actions. Time stays
// outside (the window's 0.25 s tick feeds it), so every edge is pinned by a test
// with a fake clock.

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
/// The shared cover's ink against the dimmed picture. Both appearances use
/// white ink over the 0.55 black dim: over a white frame the ground is 0.45
/// white (4.86:1) and over black it is black.
struct StallOverlayStyle: Equatable {
    let name: String
    let dimAlpha: CGFloat
    let ground: NSColor
    let title: NSColor
    let secondary: NSColor
    let iconTint: NSColor

    static let dark = StallOverlayStyle(
        name: "dark",
        dimAlpha: FrostedCoverStyle.dimAlpha,
        ground: NSColor(white: 1 - FrostedCoverStyle.dimAlpha, alpha: 1),
        title: .white,
        secondary: .white,
        iconTint: NSColor(white: 0.92, alpha: 1))

    static let light = StallOverlayStyle(
        name: "light",
        dimAlpha: FrostedCoverStyle.dimAlpha,
        ground: NSColor(white: 1 - FrostedCoverStyle.dimAlpha, alpha: 1),
        title: .white,
        secondary: .white,
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

/// The disconnection screen (WIN-39) drawn by the shared cover: the last frame
/// blurred and darkened, the window's icon, the title and the waiting line. It
/// takes every click that is not the bar's and sends nothing to the phone; it
/// offers no buttons.
final class StallOverlayView: FrostedCoverView {
    private(set) var style = StallOverlayStyle.dark
    /// The icon the window passed, not the placeholder: the chrome state and
    /// the tests read whether the app's own icon had arrived.
    private(set) var iconImage: NSImage?

    var secondaryText: String { lineText }
    var secondaryColor: NSColor { .white }
    override var hasIcon: Bool { iconImage != nil }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        applyAppearanceStyle()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }  // unrecoverable: NSCoder is never used

    /// Shows the screen for `display`, or takes it away.
    func show(_ display: StallOverlayDisplay, icon: NSImage?, heldFrame: CVPixelBuffer? = nil) {
        iconImage = icon
        // Before the app's icon has arrived, the same generic app mark the
        // opening cover uses keeps the one large picture.
        super.show(FrostedCoverContent(title: display.title, line: display.secondary,
                                       icon: icon, showsIcon: true, topInset: topInset),
                   heldFrame: heldFrame)
    }

    func hide() {
        super.show(nil)
    }

    /// The shared cover's ink is white in both appearances; the style's ground
    /// is the white-frame worst case the contrast test measures.
    func applyAppearanceStyle() {
        style = StallOverlayStyle.style(for: effectiveAppearance)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyAppearanceStyle()
    }
}
