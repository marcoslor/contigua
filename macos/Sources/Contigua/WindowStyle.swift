// The three window styles a stream window can wear, and the rules behind them.
//
// Framed (the default): a real frame on all four sides — 38 pt above the
// picture and 5 pt on the other three, a system material, a hairline, a lighter
// rim and the picture's own 12 pt corners. Compact: a permanent 28 pt bar
// above the stream — the stream's own top 28 pt, which an
// NSBackgroundExtensionView mirrors into the bar under a progressive blur —
// holding the traffic lights and the picture's name. Immersive: the borderless
// style — no bar and no borders, the picture fills the window, and the traffic
// lights and our controls live on a clear-glass pill that fades in at the
// picture's top-left corner after a rest (DwellPill).
// The person's names, 2026-11-13: the frame is "Framed" and the default, the
// bar style is "Compact", the pill style is "Immersive".
//
// Everything in this file is pure: the views (StreamChrome.swift) and the unit
// tests read the same numbers, and time is always passed in.

import AppKit

/// A style's stored value (`rawValue`) names its geometry, never its label: the
/// labels are the person's words and may change again, the stored values may
/// not, because there is no migration (issue #90). Every value an older build
/// wrote is therefore left unused on purpose, and reads as unknown, which
/// opens the default, Framed:
/// - "immersive" was the bar style's value on main before the rename (and the
///   pill style's before that). Reusing it for either style would silently
///   turn somebody's stored bar into the borderless pill, or the reverse.
/// - "framed" was the bar style's value before the frame existed.
/// - "minimal" was the pill style's value on the unmerged three-style branch.
/// Framed keeps "mat", its value on main since the frame shipped.
/// A rename is the `label` switch below (and the debug verbs read from it);
/// a stored value changes only with a new, never-used string.
enum WindowStyle: String, CaseIterable {
    case framed = "mat"
    case compact = "bar"
    case immersive = "pill"

    /// An app with no stored choice, or an unknown one, opens Framed.
    static let standard = WindowStyle.framed

    /// The smallest stream a window may hold; the window adds the style's chrome.
    static let minimumStream = CGSize(width: 320, height: 240)

    /// The name the View menu shows, top to bottom in this order. The one
    /// place a style is named: the menus, the chrome state's `style=` and the
    /// debug verb (`debugName`) all read it.
    var label: String {
        switch self {
        case .framed: return "Framed"
        case .compact: return "Compact"
        case .immersive: return "Immersive"
        }
    }

    /// The debug verb and the chrome state's token: the label in lower case.
    var debugName: String { label.lowercased() }

    /// The style a debug verb names, nil for anything else.
    init?(debugName: String) {
        guard let style = Self.allCases.first(where: { $0.debugName == debugName }) else { return nil }
        self = style
    }

    /// The padding the style adds around the stream. Full screen never has
    /// windowed chrome in any style.
    func insets(fullScreen: Bool) -> NSEdgeInsets {
        guard !fullScreen else { return NSEdgeInsets() }
        switch self {
        case .compact:
            return NSEdgeInsets(top: ChromeBar.height, left: 0, bottom: 0, right: 0)
        case .framed:
            return NSEdgeInsets(top: FramedChrome.topInset, left: FramedChrome.sideInset,
                                bottom: FramedChrome.bottomInset, right: FramedChrome.sideInset)
        case .immersive:
            return NSEdgeInsets()
        }
    }

    /// The window that holds a stream `stream` big.
    func windowSize(stream: CGSize, fullScreen: Bool = false) -> CGSize {
        let pad = insets(fullScreen: fullScreen)
        return CGSize(width: stream.width + pad.left + pad.right, height: stream.height + pad.top + pad.bottom)
    }

    /// The stream inside a window `window` big.
    func streamSize(window: CGSize, fullScreen: Bool = false) -> CGSize {
        let pad = insets(fullScreen: fullScreen)
        return CGSize(width: max(window.width - pad.left - pad.right, 0),
                      height: max(window.height - pad.top - pad.bottom, 0))
    }

    /// The frame a window takes when it changes from this style to `next`: the
    /// window grows or shrinks by the difference in the styles' insets so the
    /// stream keeps its place on screen; if the larger frame would then poke
    /// above the screen's visible area, the window moves down just enough for
    /// it to fit.
    func frame(switchedTo next: WindowStyle, current: NSRect, visible: NSRect, fullScreen: Bool = false) -> NSRect {
        let old = insets(fullScreen: fullScreen)
        let new = next.insets(fullScreen: fullScreen)
        var frame = current
        frame.origin.x += old.left - new.left
        frame.origin.y += old.bottom - new.bottom
        frame.size.width += (new.left + new.right) - (old.left + old.right)
        frame.size.height += (new.top + new.bottom) - (old.top + old.bottom)
        if frame.maxY > visible.maxY { frame.origin.y -= frame.maxY - visible.maxY }
        return frame
    }
}

/// The Framed style's own geometry, in points (ISS-45, WIN-71), measured off
/// the system Quick Look window's 2× capture: a 5 pt grey material margin on
/// the left, right and bottom (10 px at 2×), a 38 pt bar above the picture
/// (76 px), a 21 pt window radius (42 px) and a 12 pt picture radius (24 px,
/// deliberately not concentric: 21 - 5 is 16), with a 0.5 pt outer hairline,
/// a 1 pt inner rim and a white top highlight fading over the first 10 pt.
/// The reference is docs/DESIGN.md; the side-by-side comparison was made by eye.
enum FramedChrome {
    static let topInset: CGFloat = 38
    static let sideInset: CGFloat = 5
    static let bottomInset: CGFloat = 5
    static let outerRadius: CGFloat = 21
    /// The picture's own radius; deliberately not `outerRadius - sideInset`.
    static let contentRadius: CGFloat = 12
    static let hairline: CGFloat = 0.5
    static let rim: CGFloat = 1
    static let highlightHeight: CGFloat = 10
    /// The title's ink: the system label colour; the material and the window's
    /// appearance own the contrast, so Framed needs no tone machine (WIN-71).
    static let titleColor: NSColor = .labelColor

    /// The traffic lights in the taller bar: 14 pt square, 12.25 pt in from the
    /// window's left and top edges, centred on the 38 pt bar's line.
    static let lightInset: CGFloat = (topInset - ChromeBar.trafficLightButtonSide) / 2

    /// The right end of the bar's controls mirrors the lights' inset: the
    /// Compact bar's 7 pt plus this style's 5 pt frame.
    static let controlsRightInset: CGFloat = sideInset + ChromeBar.trafficLightInset

    /// The picture's rect in the chrome's coordinates (AppKit's bottom-left
    /// origin; the view is not flipped).
    static func contentRect(in bounds: NSRect) -> NSRect {
        NSRect(x: bounds.minX + sideInset,
               y: bounds.minY + bottomInset,
               width: max(bounds.width - sideInset * 2, 0),
               height: max(bounds.height - topInset - bottomInset, 0))
    }

    /// The picture's rounded rect, for the clip and the click mapping.
    static func contentPath(in bounds: NSRect) -> CGPath {
        CGPath(roundedRect: contentRect(in: bounds), cornerWidth: contentRadius,
               cornerHeight: contentRadius, transform: nil)
    }

    /// Whether `point` (the view's coordinates) is on the picture, rounded
    /// corners included. Everything else is the window's chrome.
    static func contentContains(_ point: NSPoint, in bounds: NSRect) -> Bool {
        contentPath(in: bounds).contains(point)
    }
}

/// The window's titlebar and traffic lights in a given state. Windowed, the
/// chrome owns the lights and hides the system's title: the Compact bar, the
/// Framed frame and the Immersive pill all place them themselves. Full screen in
/// Framed or Compact is the acrylic bar's (WIN-73); full screen in Immersive is
/// as it was before the three-style merge: the system's own title bar slides in
/// with the window's title and standard lights (ChromeConfig).
struct ChromeConfig: Equatable {
    let titleVisible: Bool
    let titlebarTransparent: Bool
    /// true: AppKit places the standard buttons; false: the chrome does.
    let lightsManagedByAppKit: Bool

    static func forState(style: WindowStyle, fullScreen: Bool) -> ChromeConfig {
        if fullScreen, style == .immersive {
            return ChromeConfig(titleVisible: true, titlebarTransparent: false, lightsManagedByAppKit: true)
        }
        return ChromeConfig(titleVisible: false, titlebarTransparent: true, lightsManagedByAppKit: false)
    }
}

/// The Compact bar and the full-screen bar: the numbers both share.
enum ChromeBar {
    /// The permanent bar above the stream.
    static let height = BarGeometry.barHeight
    /// The stream's own corners, as the window's in the Compact style.
    static let cornerRadius: CGFloat = 16
    /// Traffic lights: `trafficLightInset` in from the window's left edge and
    /// from the bar's top and bottom, `trafficLightButtonSide` square,
    /// `trafficLightSpacing` apart.
    static let trafficLightInset = BarGeometry.lightInset
    static let trafficLightButtonSide = BarGeometry.lightSide
    static let trafficLightSpacing = BarGeometry.lightSpacing

    /// The white haze at the window's top edge; it fades to clear at the
    /// seam (WIN-40). `dark` is the window appearance.
    static func hazeTopAlpha(dark: Bool) -> CGFloat { dark ? 0.14 : 0.30 }
}

/// The Immersive style's hot zone, the dwell that brings the lights in and the
/// pill they sit in. Restored from the pre-merge pill style: no bar, no
/// borders, the picture fills the window and this clear-glass pill is the only
/// chrome.
enum DwellChrome {
    /// At the stream's top-left.
    static let hotZone = CGSize(width: 72, height: 32)
    /// The pill is as tall as the Compact bar, at the stream's top-left
    /// corner; its width follows what is in it.
    static var pillHeight: CGFloat { ChromeBar.height }
    static let pillCornerRadius: CGFloat = 8
    /// The dwell has to rest this long, without drifting more than
    /// `tolerance` pt, before the pill fades in over `fadeIn`.
    static let dwell: TimeInterval = 0.35
    static let tolerance: CGFloat = 3
    static let fadeIn: TimeInterval = 0.12
    /// And it fades out this long after the pointer leaves the pill.
    static let hideDelay: TimeInterval = 0.6
    /// The pill sits this far in from the stream's top-left corner.
    static let pillInset: CGFloat = 6
    /// The lights ride the pill in from its edge, on the pill's centre line,
    /// the same spacing as the bar's, with the bar's left inset mirrored.
    static var pillLightInset: CGFloat { pillInset + ChromeBar.trafficLightInset }
    static var pillLightSpacing: CGFloat { ChromeBar.trafficLightSpacing }
    // The row inside the pill, in the pill's own coordinates (x from its
    // left edge), with the bar's spacing: the lights `lightInset` in, the
    // first capsule `barGap` after the zoom light, `capsuleGap` between
    // capsules, and `rightInset` after Live Text. The window-coordinate
    // `pillLightInset` adds the pill's own inset once, for the lights only:
    // adding it to the row too left 14–20 pt after the lights and pushed an
    // app window's Live Text 4 pt past the pill's end (#45).

    /// The window kind's actions: `barGap` right of the zoom light's slot.
    static var pillActionsX: CGFloat {
        ChromeBar.trafficLightInset + 2 * pillLightSpacing + ChromeBar.trafficLightButtonSide
            + HeaderBar.barGap
    }
    /// The Live Text capsule: after the actions and a gap, or in their place.
    static func pillLiveTextX(actions: [HeaderAction]) -> CGFloat {
        actions.isEmpty ? pillActionsX
            : pillActionsX + HeaderBar.rowWidth(actions) + HeaderBar.capsuleGap
    }
    /// The pill is as tall as the Compact bar and as wide as its contents:
    /// the traffic lights, the window kind's action capsules, then Live Text's
    /// capsule, then the bar's right inset.
    static func pillWidth(actions: [HeaderAction]) -> CGFloat {
        pillLiveTextX(actions: actions) + HeaderBar.liveTextSide + HeaderBar.rightInset
    }
}

/// The Immersive chrome's rule. Normally the traffic lights and the bar's
/// capsules hide at rest and the dwell pill brings them in; with Always
/// Visible there is no hot zone and no hiding — they stay over the stream,
/// which still fills the window.
enum ImmersiveChrome {
    static func alwaysVisible(_ delay: RevealDelay) -> Bool {
        delay.keepsChromeVisible
    }

    /// The dwell's hot zone exists only while the chrome can hide.
    static func usesDwell(alwaysVisible: Bool) -> Bool { !alwaysVisible }

    /// The pill (the lights and the capsules) is up: always, or because the
    /// dwell brought it in.
    static func showsPill(alwaysVisible: Bool, dwellShown: Bool) -> Bool {
        alwaysVisible || dwellShown
    }
}

/// The full-screen bar Framed and Compact wear: one 28 pt acrylic bar across the
/// screen's top, hidden until the pointer reaches the top edge and revealed by
/// FullScreenBarMachine. No mirror, no frame: the system material frosts the
/// stream behind it.
enum FullScreenBar {
    static let height = ChromeBar.height
    /// The band at the very top edge a pointer has to reach while the bar is
    /// hidden. Once it is showing, its own height keeps it alive.
    static let edgeHeight: CGFloat = 8
    /// The default rest before the bar slides in, from RevealDelay.short.
    static let revealDelay: TimeInterval = 0.35
    /// How long the pointer may leave the bar before it slides away.
    static let hideDelay: TimeInterval = 0.6
    /// The slide's own times: down like the system's full-screen titlebar, and
    /// away a little faster.
    static let revealDuration: TimeInterval = 0.18
    static let hideDuration: TimeInterval = 0.15
    /// The bar's own background: the system's full-screen material, blended
    /// within the window so it frosts the stream, not the desktop.
    static let material: NSVisualEffectView.Material = .fullScreenUI
    /// The centred title's ink: the system label colour; the material and the
    /// window's appearance own the contrast.
    static let titleColor: NSColor = .labelColor
}

/// The full-screen bar's four states (WIN-8). One explicit machine: no
/// booleans elsewhere stand for a phase. `pending` records which timer the
/// current state asked for, so a late or duplicated `delayElapsed` can be
/// ignored and a pointer returning cancels the right one.
enum FullScreenBarMode: String, CaseIterable {
    case hidden
    case revealing
    case shown
    case hiding
}

enum FullScreenBarEvent: Equatable {
    /// The system entered full screen: the bar starts hidden.
    case enterFullScreen
    /// The system left full screen: the bar goes and no timer survives.
    case exitFullScreen
    /// The pointer reached the top edge (the top band while hidden, the bar
    /// while it shows) and is resting there.
    case pointerAtTopEdge
    /// The pointer left the top edge and the bar.
    case pointerLeaves
    /// The reveal rest or the hide grace expired.
    case delayElapsed
    /// The slide in or out finished.
    case animationFinished
    /// A menu began or ended tracking: the bar stays while one is open.
    case menuTracking(Bool)
    /// View ▸ Hide Controls or Settings picked another reveal choice.
    case configurationChanged(RevealDelay)
}

/// What the window has to do for one transition. Effects run in the
/// controller; the machine only names them.
enum FullScreenBarAction: Equatable {
    case scheduleReveal(TimeInterval)
    case scheduleHide(TimeInterval)
    case cancelTimer
    case reveal(animated: Bool)
    case hide(animated: Bool)
}

/// The full-screen bar's transition table. Pure: time, pointer and menu events
/// are passed in and the caller runs the returned actions.
struct FullScreenBarMachine: Equatable {
    enum Pending: Equatable {
        case reveal
        case hide
    }

    private(set) var mode: FullScreenBarMode = .hidden
    private(set) var reveal: RevealDelay
    private(set) var pointerAtTop = false
    private(set) var menuIsTracking = false
    private(set) var pending: Pending?

    init(reveal: RevealDelay = .short) {
        self.reveal = reveal
    }

    private var alwaysVisible: Bool { reveal.keepsChromeVisible }

    /// Folds one event in and returns the effects to run, in order.
    mutating func handle(_ event: FullScreenBarEvent) -> [FullScreenBarAction] {
        switch event {
        case .enterFullScreen, .exitFullScreen:
            mode = .hidden
            pointerAtTop = false
            menuIsTracking = false
            pending = nil
            return [.cancelTimer, .hide(animated: false)]

        case .pointerAtTopEdge:
            pointerAtTop = true
            if alwaysVisible {
                pending = nil
                guard mode != .shown else { return [] }
                mode = .revealing
                return [.cancelTimer, .reveal(animated: true)]
            }
            switch mode {
            case .hidden:
                pending = .reveal
                return [.cancelTimer, .scheduleReveal(reveal.seconds)]
            case .revealing, .shown:
                guard pending == .hide else { return [] }
                pending = nil
                return [.cancelTimer]
            case .hiding:
                pending = nil
                mode = .revealing
                return [.cancelTimer, .reveal(animated: true)]
            }

        case .pointerLeaves:
            pointerAtTop = false
            if alwaysVisible || menuIsTracking { return [] }
            switch mode {
            case .hidden:
                guard pending == .reveal else { return [] }
                pending = nil
                return [.cancelTimer]
            case .revealing:
                pending = nil
                mode = .hiding
                return [.hide(animated: true)]
            case .shown:
                pending = .hide
                return [.cancelTimer, .scheduleHide(FullScreenBar.hideDelay)]
            case .hiding:
                return []
            }

        case .delayElapsed:
            switch (mode, pending) {
            case (.hidden, .reveal):
                pending = nil
                mode = alwaysVisible ? .shown : .revealing
                return [.reveal(animated: true)]
            case (.shown, .hide):
                pending = nil
                guard !alwaysVisible, !menuIsTracking, !pointerAtTop else { return [] }
                mode = .hiding
                return [.hide(animated: true)]
            default:
                return []
            }

        case .animationFinished:
            switch mode {
            case .revealing:
                mode = .shown
                guard !alwaysVisible, !menuIsTracking, !pointerAtTop else { return [] }
                pending = .hide
                return [.scheduleHide(FullScreenBar.hideDelay)]
            case .hiding:
                mode = .hidden
                return []
            case .hidden, .shown:
                return []
            }

        case .menuTracking(let tracking):
            menuIsTracking = tracking
            if tracking {
                pending = nil
                guard mode != .shown else { return [.cancelTimer] }
                mode = .revealing
                return [.cancelTimer, .reveal(animated: true)]
            }
            guard !alwaysVisible, !pointerAtTop, mode == .shown else { return [] }
            pending = .hide
            return [.scheduleHide(FullScreenBar.hideDelay)]

        case .configurationChanged(let choice):
            let wasAlwaysVisible = alwaysVisible
            reveal = choice
            if alwaysVisible {
                pending = nil
                guard mode != .shown else { return [.cancelTimer] }
                mode = .revealing
                return [.cancelTimer, .reveal(animated: true)]
            }
            if wasAlwaysVisible {
                pending = nil
                if pointerAtTop || menuIsTracking {
                    guard mode == .hidden else { return [.cancelTimer] }
                    pending = .reveal
                    return [.cancelTimer, .scheduleReveal(choice.seconds)]
                }
                guard mode == .shown || mode == .revealing else { return [.cancelTimer] }
                mode = .hiding
                return [.cancelTimer, .hide(animated: true)]
            }
            guard pending == .reveal, mode == .hidden else { return [] }
            return [.cancelTimer, .scheduleReveal(choice.seconds)]
        }
    }
}

/// Settings → General "Reveal controls after" and View ▸ Hide Controls: how
/// long the pointer rests at the top edge in full screen before the bar shows,
/// or "Always Visible", which keeps it up; in Immersive it is the dwell that
/// brings the pill in. Short is the 350 ms default; the value lives in the
/// profile's defaults and applies to open windows at once.
enum RevealDelay: String, CaseIterable {
    case instantly
    case short
    case long
    /// The full-screen bar stays shown: no rest, no hiding.
    case alwaysVisible

    static let key = "immersive.revealDelay"

    var label: String {
        switch self {
        case .instantly: return "Instantly"
        case .short: return "Short"
        case .long: return "Long"
        case .alwaysVisible: return "Always Visible"
        }
    }

    /// Instantly (0), the default 350 ms, or twice that. Unused when the bar
    /// is always visible.
    var seconds: TimeInterval {
        switch self {
        case .instantly, .alwaysVisible: return 0
        case .short: return FullScreenBar.revealDelay
        case .long: return FullScreenBar.revealDelay * 2
        }
    }

    /// The full-screen bar never hides for this choice.
    var keepsChromeVisible: Bool { self == .alwaysVisible }

    /// Unset or unreadable values are Short, the default.
    static func stored(in defaults: UserDefaults) -> RevealDelay {
        guard let raw = defaults.string(forKey: key), let value = RevealDelay(rawValue: raw) else { return .short }
        return value
    }
}

/// The edge of a phone window's frame a person is dragging. The edge decides
/// which dimension leads the phone's aspect rule (ISS-64); a resize that is not
/// a mouse drag keeps today's larger-area rule (the v104 fix).
enum PhoneWindowEdge: Equatable {
    case none
    case left
    case right
    case top
    case bottom
    case topLeft
    case topRight
    case bottomLeft
    case bottomRight

    /// The edge or corner under `point` (frame coordinates): an edge within
    /// `tolerance` points of the pointer, a corner where two edges meet there.
    static func at(point: CGPoint, in frame: NSRect, tolerance: CGFloat = 6) -> PhoneWindowEdge {
        guard frame.width > 0, frame.height > 0 else { return .none }
        let nearLeft = abs(point.x - frame.minX) <= tolerance
        let nearRight = abs(point.x - frame.maxX) <= tolerance
        let nearTop = abs(point.y - frame.maxY) <= tolerance
        let nearBottom = abs(point.y - frame.minY) <= tolerance
        let nearFrame = point.x >= frame.minX - tolerance && point.x <= frame.maxX + tolerance
            && point.y >= frame.minY - tolerance && point.y <= frame.maxY + tolerance
        guard nearFrame else { return .none }
        switch (nearLeft, nearRight, nearTop, nearBottom) {
        case (true, _, true, _): return .topLeft
        case (_, true, true, _): return .topRight
        case (true, _, _, true): return .bottomLeft
        case (_, true, _, true): return .bottomRight
        case (true, _, _, _): return .left
        case (_, true, _, _): return .right
        case (_, _, true, _): return .top
        case (_, _, _, true): return .bottom
        default: return .none
        }
    }
}

/// The phone window's shape rules: the stream keeps the phone's aspect ratio;
/// the window adds the style's bar above it.
enum PhoneChrome {
    /// The phone's screen turned to match a stream whose orientation differs
    /// from it (the phone rotated); nil while they agree.
    static func turnedPhone(phone: CGSize, video: CGSize) -> CGSize? {
        guard video.width > 0, video.height > 0, phone.width > 0, phone.height > 0 else { return nil }
        guard (video.width > video.height) != (phone.width > phone.height) else { return nil }
        return CGSize(width: phone.height, height: phone.width)
    }

    /// The frame the phone window's green button zooms to: the phone's aspect
    /// fit inside the screen's visible frame. The mirror is never stretched or
    /// cropped, and the window never goes full screen.
    static func zoomFrame(phone: CGSize, style: WindowStyle, visible: NSRect) -> NSRect {
        guard phone.width > 0, phone.height > 0, visible.width > 1, visible.height > 1 else {
            return visible
        }
        let ratio = phone.width / phone.height
        let pad = style.insets(fullScreen: false)
        var streamHeight = max(visible.height - pad.top - pad.bottom, 1)
        var streamWidth = streamHeight * ratio
        let maxStreamWidth = max(visible.width - pad.left - pad.right, 1)
        if streamWidth > maxStreamWidth {
            streamWidth = maxStreamWidth
            streamHeight = streamWidth / ratio
        }
        let size = style.windowSize(stream: CGSize(width: streamWidth, height: streamHeight))
        return NSRect(x: (visible.midX - size.width / 2).rounded(),
                      y: (visible.midY - size.height / 2).rounded(),
                      width: size.width.rounded(), height: size.height.rounded())
    }

    /// A phone window keeps its phone's aspect ratio in the stream, not in the
    /// frame (the bar is not part of the picture). Sizes are window frames.
    ///
    /// A dragged edge leads: a top or bottom drag sets the height and the width
    /// follows, a side drag sets the width and the height follows. A corner, or
    /// a resize with no mouse edge (Accessibility, a tiler, the zoom button),
    /// projects the proposal onto the aspect line and takes the candidate that
    /// reaches further past the proposal on the other axis. Nothing here looks
    /// at the last snapped frame: measuring the drag against it made the
    /// leading axis flip mid-drag, so a mostly-down move after a mostly-across
    /// one produced a smaller window than the step before and the window
    /// fought the person's hand.
    static func frame(proposed: CGSize, phone: CGSize, style: WindowStyle) -> CGSize {
        frame(proposed: proposed, phone: phone, style: style, edge: .none)
    }

    static func frame(proposed: CGSize, phone: CGSize, style: WindowStyle,
                      edge: PhoneWindowEdge) -> CGSize {
        guard phone.width > 0, phone.height > 0 else { return proposed }
        let ratio = phone.height / phone.width
        let stream = style.streamSize(window: proposed)
        let widthLed = CGSize(width: stream.width, height: (stream.width * ratio).rounded())
        let heightLed = CGSize(width: (stream.height / ratio).rounded(), height: stream.height)
        let chosen: CGSize
        switch edge {
        case .top, .bottom:
            // The dragged edge is a horizontal one: the height leads and the
            // width follows, so a single-edge drag can shrink the window.
            chosen = heightLed
        case .left, .right:
            chosen = widthLed
        case .none, .topLeft, .topRight, .bottomLeft, .bottomRight:
            // A corner moves both axes; an unattributed resize keeps the v104
            // larger-area rule.
            chosen = widthLed.width * widthLed.height >= heightLed.width * heightLed.height
                ? widthLed : heightLed
        }
        return style.windowSize(stream: chosen)
    }

    /// The frame a phone window opens at when it has a remembered one: the
    /// remembered height leads, the window takes the phone's shape, and the
    /// screen's limit scales the stream as one (ISS-63). The top-left stays.
    static func restoredFrame(saved: NSRect, phone: CGSize, style: WindowStyle,
                              visible: NSRect, minimum: NSSize = .zero) -> NSRect {
        guard phone.width > 0, phone.height > 0, saved.width > 0, saved.height > 0 else { return saved }
        let ratio = phone.width / phone.height
        let pad = style.insets(fullScreen: false)
        var streamHeight = max(saved.height - pad.top - pad.bottom, 1)
        var streamWidth = streamHeight * ratio
        let maxStreamHeight = max(visible.height - pad.top - pad.bottom, 1)
        let maxStreamWidth = max(visible.width - pad.left - pad.right, 1)
        let scale = min(1, min(maxStreamWidth / streamWidth, maxStreamHeight / streamHeight))
        streamWidth *= scale
        streamHeight *= scale
        // The minimum is the phone's shape too (PhoneWindowController's
        // minSize): a narrow window grows both axes, never one.
        let minStreamWidth = max(minimum.width, max(minimum.height - pad.top - pad.bottom, 0) * ratio)
        if streamWidth < minStreamWidth {
            streamWidth = min(minStreamWidth, maxStreamWidth)
            streamHeight = streamWidth / ratio
        }
        let size = style.windowSize(stream: CGSize(width: streamWidth.rounded(),
                                                   height: streamHeight.rounded()))
        return NSRect(x: saved.minX, y: saved.maxY - size.height,
                      width: size.width, height: size.height)
    }

    /// Whether the mirror's picture needs the window refitted to its shape: a
    /// difference of more than `tolerance` (a fraction). A picture that arrives
    /// under the person's hand waits for the drag's end (ISS-63).
    enum PictureFit: Equatable {
        case none
        case refitNow
        case refitAtDragEnd

        static func decide(video: CGSize, picture: CGSize, isDragging: Bool,
                           tolerance: CGFloat = 0.01) -> PictureFit {
            guard video.width > 0, video.height > 0,
                  picture.width > 0, picture.height > 0 else { return .none }
            let videoRatio = video.width / video.height
            let pictureRatio = picture.width / picture.height
            guard abs(videoRatio - pictureRatio) > tolerance * max(videoRatio, pictureRatio) else {
                return .none
            }
            return isDragging ? .refitAtDragEnd : .refitNow
        }
    }

    /// The frame the window takes when it refits to the picture's shape: the
    /// top-left and the height stay, the width follows (ISS-63).
    static func refitFrame(current: NSRect, picture: CGSize, style: WindowStyle) -> NSRect {
        guard picture.width > 0, picture.height > 0, current.width > 0, current.height > 0 else {
            return current
        }
        let stream = style.streamSize(window: current.size)
        let height = max(stream.height, 1)
        let width = (height * picture.width / picture.height).rounded()
        let size = style.windowSize(stream: CGSize(width: width, height: height))
        return NSRect(x: current.minX, y: current.maxY - size.height,
                      width: size.width, height: size.height)
    }
}

/// Where each window's style is remembered: one key per app package, one for
/// the phone window. An app with no stored choice opens `WindowStyle.standard`.
struct WindowStyleStore {
    static let phoneKey = "chrome.style.phone"
    static let prefix = "chrome.style."

    let defaults: UserDefaults

    /// The key an app package's style lives under (the phone window has its own).
    static func key(forPackage package: String?) -> String {
        guard let package, !package.isEmpty else { return phoneKey }
        return prefix + package
    }

    /// nil for a window with nothing to remember (a link window before the
    /// phone reports the package it displays). A stored value the enum does
    /// not know — the old names included — is ignored and opens the default
    /// (Framed); no migration is attempted.
    func style(forKey key: String?) -> WindowStyle {
        guard let key, let raw = defaults.string(forKey: key), let style = WindowStyle(rawValue: raw) else {
            return .standard
        }
        return style
    }

    func set(_ style: WindowStyle, forKey key: String?) {
        guard let key else { return }
        defaults.set(style.rawValue, forKey: key)
    }
}

/// The Immersive hot zone's rule. The pointer has to rest still inside the zone
/// for `dwell` before the pill shows; a click that arrives before that goes to
/// the app as ordinary touch input (the view passes it straight through) and
/// starts the rest again, so tapping can never summon the pill mid-tap. While
/// the pill or the zone is under the pointer it stays; it hides `hideDelay`
/// after the pointer leaves both.
///
/// Points and rects are in the stream's coordinates with a top-left origin.
struct DwellPill: Equatable {
    let zone: CGRect
    let pill: CGRect
    /// Settings → General "Reveal controls after"; `setDwell` changes it live.
    private(set) var dwell: TimeInterval
    let hideDelay: TimeInterval
    let tolerance: CGFloat

    private(set) var shown = false
    /// When the pill hides unless the pointer comes back.
    private(set) var hideAt: TimeInterval?
    /// Where and when the current rest began; nil while no rest is running.
    private(set) var restStart: TimeInterval?
    private var restPoint: CGPoint = .zero

    init(zone: CGRect = CGRect(origin: .zero, size: DwellChrome.hotZone),
         pill: CGRect = CGRect(x: 0, y: 0, width: 0, height: DwellChrome.pillHeight),
         dwell: TimeInterval = DwellChrome.dwell,
         hideDelay: TimeInterval = DwellChrome.hideDelay,
         tolerance: CGFloat = DwellChrome.tolerance) {
        self.zone = zone
        self.pill = pill
        self.dwell = dwell
        self.hideDelay = hideDelay
        self.tolerance = tolerance
    }

    /// The pointer is at `point` (stream coordinates, top-left origin).
    mutating func pointerMoved(to point: CGPoint, now: TimeInterval) {
        if shown {
            if pill.contains(point) || zone.contains(point) {
                hideAt = nil
            } else if hideAt == nil {
                hideAt = now + hideDelay
            }
            return
        }
        guard zone.contains(point) else {
            restStart = nil
            return
        }
        let drifted = restStart.map { _ in hypot(point.x - restPoint.x, point.y - restPoint.y) > tolerance } ?? true
        if drifted {
            restStart = now
            restPoint = point
        }
    }

    /// The Settings control changed: the next rest uses `value`, and a rest
    /// already running is re-timed from when it began (the controller folds
    /// the time in again, so a shorter delay can show it at once).
    mutating func setDwell(_ value: TimeInterval) {
        dwell = max(value, 0)
    }

    /// A click reached the app through the hot zone: the rest starts again from
    /// it, so the pill cannot appear while the finger is still tapping.
    mutating func clickReachedApp(at point: CGPoint, now: TimeInterval) {
        restStart = now
        restPoint = point
    }

    /// Folds the time in: shows the pill once the rest is long enough, hides it
    /// when the hide is due.
    mutating func update(now: TimeInterval) {
        if !shown, let start = restStart, now - start >= dwell {
            shown = true
            hideAt = nil
            restStart = nil
        }
        if shown, let due = hideAt, now >= due {
            shown = false
            hideAt = nil
            restStart = nil
        }
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
