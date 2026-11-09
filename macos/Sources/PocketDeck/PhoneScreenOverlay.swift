// The phone window's screen state and the overlay a sleeping panel or a secure
// surface puts over the last frame (docs/design/phone-mirror.md "Screen off and
// wake"). The model is pure: time and views stay outside, so the tests pin every
// transition. The view is the shared frosted cover (FrostedCover.swift, WIN-65)
// with an optional Wake Screen button; it forwards no input to the phone.

import AppKit

/// `state.screen`: display 0's power state as the phone reports it.
enum PhoneScreen: String, Equatable {
    case on
    case off
}

/// `state.panel`: whether the phone is holding its own panel's power off for
/// this window ("Turn Off Phone Screen", docs/design/phone-mirror.md).
enum PhonePanel: String, Equatable {
    case on
    case off
}

/// "Turn Off Phone Screen" as the person left it, per phone id in the profile's
/// defaults: it is a choice about their phone, so it survives its window.
enum PhonePanelOffSetting {
    static let key = "phonePanelOff"

    static func read(from defaults: UserDefaults, deviceId: String) -> Bool {
        guard !deviceId.isEmpty else { return false }
        return (defaults.dictionary(forKey: key) as? [String: Bool])?[deviceId] ?? false
    }

    static func write(_ on: Bool, for deviceId: String, to defaults: UserDefaults) {
        guard !deviceId.isEmpty else { return }
        var all = (defaults.dictionary(forKey: key) as? [String: Bool]) ?? [:]
        if on { all[deviceId] = true } else { all.removeValue(forKey: deviceId) }
        if all.isEmpty { defaults.removeObject(forKey: key) } else { defaults.set(all, forKey: key) }
    }
}

/// Settings ▸ Phones ▸ "Keep the phone screen off until I turn it on from the
/// Mac", per phone, off by default. It only changes what the phone's power
/// button does while the Mac holds the panel off; the phone stays locked either
/// way, and the hold still ends on request on, window close, session end and
/// the crash watchdog.
enum PhonePanelIgnorePowerSetting {
    static let key = "phonePanelIgnorePower"

    static func read(from defaults: UserDefaults, deviceId: String) -> Bool {
        guard !deviceId.isEmpty else { return false }
        return (defaults.dictionary(forKey: key) as? [String: Bool])?[deviceId] ?? false
    }

    static func write(_ on: Bool, for deviceId: String, to defaults: UserDefaults) {
        guard !deviceId.isEmpty else { return }
        var all = (defaults.dictionary(forKey: key) as? [String: Bool]) ?? [:]
        if on { all[deviceId] = true } else { all.removeValue(forKey: deviceId) }
        if all.isEmpty { defaults.removeObject(forKey: key) } else { defaults.set(all, forKey: key) }
    }
}

/// What covers the mirror: a sleeping panel, or a surface Android blanks.
enum PhoneCover: Equatable {
    case screenOff
    case secure
}

/// What the phone window shows over the held frame while the panel sleeps or a
/// secure surface hides the screen.
struct PhoneScreenOverlay: Equatable {
    /// The last screen the phone reported; nil until a `state` carries it, and
    /// read as "on" (nothing is overlaid on a phone that does not report it).
    private(set) var screen: PhoneScreen?
    /// `state.secure`: the phone's mirror is a secure surface (the PIN pad,
    /// the keyguard bouncer, a FLAG_SECURE app).
    private(set) var secureReported = false
    /// Black frames while the screen is on: the fallback for phones that do
    /// not report `secure` yet.
    private(set) var blackSince: TimeInterval?
    private(set) var blackCovered = false
    /// Every wake this window asked the phone for: one per open/reconnect and
    /// one per Wake Screen click while the overlay is up.
    private(set) var wakeRequests = 0
    /// `state.panel`: the phone holds its own panel off for this mirror.
    private(set) var panelOff = false
    /// A `state.panel` has arrived; before that the check stays off.
    private(set) var panelReported = false
    /// The short sentence the chrome shows for [panelPillSeconds] after panel-off
    /// starts or the phone ends it: "Phone screen off" / "Phone screen on".
    private(set) var panelPill: String?
    private(set) var panelPillUntil: TimeInterval?
    /// When the Mac asked for the panel off and has heard nothing: a request
    /// without an answer is a failure too (the phone never applied it).
    private(set) var panelRequestedAt: TimeInterval?

    /// Enough to read one short sentence, then the mirror is quiet again.
    static let panelPillSeconds: TimeInterval = 2

    /// How long a request may go unanswered before the Mac says it failed.
    /// docs/design/phone-mirror.md "The Mac button tells the truth".
    static let panelReplySeconds: TimeInterval = 2

    /// The sentence for a request that did not turn the screen off.
    static let panelFailedText = "The phone didn't turn its screen off"

    /// Half a second of black frames while the screen is on is a secure
    /// surface Android is hiding, not a dark app.
    static let blackCoverDelay: TimeInterval = 0.5

    init(screen: PhoneScreen? = nil) {
        self.screen = screen
    }

    /// What is over the mirror now, if anything.
    var cover: PhoneCover? {
        if screen == .off { return .screenOff }
        if secureReported || blackCovered { return .secure }
        return nil
    }

    /// True while the frozen frame is shown as covered.
    var isShowing: Bool { cover != nil }

    /// A `state` arrived; true when the picture state changed.
    @discardableResult
    mutating func set(screen: PhoneScreen?) -> Bool {
        guard screen != self.screen else { return false }
        self.screen = screen
        if screen == .off {
            blackSince = nil
            blackCovered = false
        }
        return true
    }

    /// `state.secure` changed: the phone's own report wins over the frames.
    @discardableResult
    mutating func setSecure(_ secure: Bool) -> Bool {
        guard secure != secureReported else { return false }
        secureReported = secure
        blackSince = nil
        blackCovered = false
        return true
    }

    /// A displayed frame arrived at `time` (host uptime). True when the cover
    /// came or went: black for `blackCoverDelay` puts it up, content takes it
    /// away (the phone's own `secure` report is only cleared by the phone).
    @discardableResult
    mutating func frame(at time: TimeInterval, black: Bool) -> Bool {
        guard screen != .off, !secureReported else { return false }
        if black {
            let since = blackSince ?? time
            blackSince = since
            guard !blackCovered, time - since >= Self.blackCoverDelay else { return false }
            blackCovered = true
            return true
        }
        blackSince = nil
        guard blackCovered else { return false }
        blackCovered = false
        return true
    }

    /// The window opened, re-opened or reconnected: display 0 is woken once.
    mutating func opened() {
        wakeRequests += 1
    }

    /// `state.panel` arrived at `time`. True when the panel's state changed
    /// (the bar glyph and the menu check follow it). Any report answers a
    /// pending request, so it also clears the 2 s reply clock.
    @discardableResult
    mutating func setPanel(_ panel: PhonePanel?, at time: TimeInterval) -> Bool {
        // A phone that does not report it leaves the option alone.
        guard let panel else { return false }
        panelRequestedAt = nil
        let off = panel == .off
        // The default reads as on, so the first report only says something when
        // it says off; a later one speaks only on a real transition.
        let changed = off != panelOff
        // Only a real transition says something: the first report is just the
        // truth arriving.
        if panelReported && changed {
            panelPill = off ? "Phone screen off" : "Phone screen on"
            panelPillUntil = time + Self.panelPillSeconds
        }
        panelReported = true
        panelOff = off
        return changed
    }

    /// The Mac asked the phone to turn its screen off at `time`; a `state.panel`
    /// report ends the wait, [tick] gives up after [panelReplySeconds].
    mutating func requestPanelOff(at time: TimeInterval) {
        panelRequestedAt = time
    }

    /// The phone refused the request (`bad_request`/`unavailable`): say so for
    /// two seconds and leave the button unchecked. The phone's truth stands.
    @discardableResult
    mutating func panelRequestFailed(at time: TimeInterval) -> Bool {
        panelRequestedAt = nil
        panelPill = Self.panelFailedText
        panelPillUntil = time + Self.panelPillSeconds
        return true
    }

    /// Time passed: true when the pill appeared or came down. A panel-off
    /// request the phone never answered within [panelReplySeconds] is a failure.
    @discardableResult
    mutating func tick(at time: TimeInterval) -> Bool {
        if let requested = panelRequestedAt, time - requested >= Self.panelReplySeconds {
            return panelRequestFailed(at: time)
        }
        guard let until = panelPillUntil, time >= until else { return false }
        panelPill = nil
        panelPillUntil = nil
        return true
    }

    /// A click on the frame: the Wake Screen button while the sleeping cover is
    /// up, nil (an ordinary touch) on live video and on the secure cover.
    mutating func click() -> Bool {
        guard cover == .screenOff else { return false }
        wakeRequests += 1
        return true
    }
}

/// Whether a displayed frame is entirely (near) black: the phone's encoder
/// sends solid black for a surface Android will not let it show.
enum BlackFrame {
    /// Per-channel ceiling for BGRA pixels, and for the luma plane of a
    /// bi-planar buffer (video-range black is 16; a dark app is brighter).
    private static let bgraCeiling: UInt8 = 8
    private static let lumaCeiling: UInt8 = 24

    /// Samples the frame on a grid; one visible pixel (a cursor, a status bar)
    /// makes it content.
    static func isBlack(_ buffer: CVPixelBuffer) -> Bool {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        guard width > 0, height > 0 else { return false }
        let stepX = max(1, width / 128)
        let stepY = max(1, height / 128)
        let format = CVPixelBufferGetPixelFormatType(buffer)
        if format == kCVPixelFormatType_32BGRA || format == kCVPixelFormatType_32ARGB {
            guard let base = CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to: UInt8.self) else {
                return false
            }
            let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
            let offset = format == kCVPixelFormatType_32BGRA ? 0 : 1
            for y in stride(from: 0, to: height, by: stepY) {
                for x in stride(from: 0, to: width, by: stepX) {
                    let pixel = base + y * rowBytes + x * 4 + offset
                    if pixel[0] > bgraCeiling || pixel[1] > bgraCeiling || pixel[2] > bgraCeiling {
                        return false
                    }
                }
            }
            return true
        }
        guard CVPixelBufferGetPlaneCount(buffer) > 0,
              let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)?.assumingMemoryBound(to: UInt8.self) else {
            return false
        }
        let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        for y in stride(from: 0, to: height, by: stepY) {
            for x in stride(from: 0, to: width, by: stepX) {
                if base[y * rowBytes + x] > lumaCeiling { return false }
            }
        }
        return true
    }
}
/// The Phone Mirror's sleeping-panel and secure cover, drawn by the shared
/// frosted cover (FrostedCover, MIRROR-6/MIRROR-8). A click anywhere on the
/// sleeping cover wakes; the secure cover takes the click and sends nothing.
final class PhoneScreenOverlayView: FrostedCoverView {
    /// The person wants the phone's screen back (the window sends `phone.wake`).
    var onWake: (() -> Void)?

    /// What is covered right now (nil: live video).
    private(set) var cover: PhoneCover?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        onCoverClick = { [weak self] in self?.wake() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Shows the cover for `cover`, or takes it away (nil). The sleeping panel
    /// offers Wake Screen; a secure surface has no button and says why.
    /// `heldFrame` is the picture displayed when the cover arrives.
    func show(_ cover: PhoneCover?, heldFrame: CVPixelBuffer? = nil) {
        self.cover = cover
        switch cover {
        case .screenOff:
            onPrimary = { [weak self] in self?.wake() }
            super.show(FrostedCoverContent(title: "The phone's screen is off",
                                           button: "Wake Screen"), heldFrame: heldFrame)
        case .secure:
            onPrimary = nil
            super.show(FrostedCoverContent(title: "Android doesn't let PocketDeck show this screen."),
                       heldFrame: heldFrame)
        case nil:
            onPrimary = nil
            super.show(nil)
        }
    }

    private func wake() {
        guard cover == .screenOff else { return }
        onWake?()
    }
}
