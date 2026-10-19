// The two window styles a stream window can wear, and the rules behind them.
//
// Framed (the default): a permanent 28 pt bar above the stream — window
// material over the stream's own top 28 pt, which an NSBackgroundExtensionView
// mirrors into the bar and fades into the material by the seam/top alphas —
// holding the traffic lights. Immersive: the window is
// exactly the stream, and the lights live behind a 350 ms dwell in a 72x32 pt
// hot zone at the stream's top-left.
//
// Everything in this file is pure: the views (StreamChrome.swift) and the unit
// tests read the same numbers, and time is always passed in.

import AppKit

enum WindowStyle: String, CaseIterable {
    case framed
    case immersive

    /// An app with no stored choice opens framed.
    static let standard = WindowStyle.framed

    /// The name the View menu shows.
    var label: String { self == .framed ? "Framed" : "Immersive" }

    /// The padding the style adds around the stream: the bar above it, nothing
    /// on the other three sides. Full screen never has a bar.
    func insets(fullScreen: Bool) -> NSEdgeInsets {
        NSEdgeInsets(top: self == .framed && !fullScreen ? ChromeBar.height : 0, left: 0, bottom: 0, right: 0)
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
    /// window grows or shrinks by the bar above the stream, so the stream keeps
    /// its place on screen; if the bar would then poke above the screen's
    /// visible area, the window moves down just enough for it to fit.
    func frame(switchedTo next: WindowStyle, current: NSRect, visible: NSRect, fullScreen: Bool = false) -> NSRect {
        var frame = current
        frame.size.height += next.insets(fullScreen: fullScreen).top - insets(fullScreen: fullScreen).top
        if frame.maxY > visible.maxY { frame.origin.y -= frame.maxY - visible.maxY }
        return frame
    }
}

/// The framed bar and the immersive pill: the numbers both styles share.
enum ChromeBar {
    /// The permanent bar above the stream.
    static let height: CGFloat = 28
    /// The stream's own corners, as the window's in the immersive style.
    static let cornerRadius: CGFloat = 16
    /// Traffic lights: the standard 20 pt in from the window's left edge,
    /// centred on the bar's own line. 14 pt square buttons, 23 pt apart.
    static let trafficLightInset: CGFloat = 20
    static let trafficLightButtonSide: CGFloat = 14
    static let trafficLightSpacing: CGFloat = 23
}

/// The immersive style's hot zone, the dwell that brings the lights in and the
/// pill they sit in.
enum DwellChrome {
    /// At the stream's top-left.
    static let hotZone = CGSize(width: 72, height: 32)
    /// The pill is as tall as the framed bar, at the stream's top-left corner;
    /// its width follows what is in it.
    static let pillHeight: CGFloat = 28
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
    /// The lights ride the pill 8 pts in from its edge, on the pill's centre
    /// line, 23 pt apart like the bar's 20/43/66.
    static let pillLightInset: CGFloat = pillInset + 8
    static let pillLightSpacing: CGFloat = 23
    /// The window kind's actions 8 pts right of the zoom light's slot.
    static let pillActionsX: CGFloat = pillLightInset + 2 * pillLightSpacing + ChromeBar.trafficLightButtonSide + 8
    /// The pill is as tall as the framed bar and as wide as its contents.
    static func pillWidth(actionCount: Int) -> CGFloat {
        guard actionCount > 0 else { return pillActionsX + 8 - pillInset }
        return pillActionsX + CGFloat(actionCount) * HeaderControls.buttonWidth + 6
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

    /// A phone window keeps its phone's aspect ratio in the stream, not in the
    /// frame (the bar is not part of the picture). The dimension the user
    /// moved more leads; the other follows. Sizes are window frames.
    static func frame(proposed: CGSize, current: CGSize, phone: CGSize, style: WindowStyle) -> CGSize {
        guard phone.width > 0, phone.height > 0 else { return proposed }
        let ratio = phone.height / phone.width
        let stream = style.streamSize(window: proposed)
        let widthMoved = abs(proposed.width - current.width)
        let heightMoved = abs(proposed.height - current.height)
        if widthMoved * ratio >= heightMoved {
            return style.windowSize(stream: CGSize(width: stream.width, height: (stream.width * ratio).rounded()))
        }
        return style.windowSize(stream: CGSize(width: (stream.height / ratio).rounded(), height: stream.height))
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
    /// phone reports the package it displays).
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

/// The immersive hot zone's rule. The pointer has to rest still inside the zone
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
    let dwell: TimeInterval
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
