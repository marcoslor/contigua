// The phone window's screen state and the overlay a sleeping panel puts over
// the last frame (docs/design/phone-mirror.md "Screen off and wake"). The model
// is pure: time and views stay outside, so the tests pin every transition.
// The view is only pixels and one button; it forwards no input to the phone.

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

    /// Enough to read one short sentence, then the mirror is quiet again.
    static let panelPillSeconds: TimeInterval = 2

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
    /// (the bar glyph and the menu check follow it).
    @discardableResult
    mutating func setPanel(_ panel: PhonePanel?, at time: TimeInterval) -> Bool {
        // A phone that does not report it leaves the option alone.
        guard let panel else { return false }
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

    /// Time passed: true when the panel pill has run out and came down.
    @discardableResult
    mutating func tick(at time: TimeInterval) -> Bool {
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

/// The blurred, dimmed frame with the centred message and, for a sleeping
/// panel, its Wake Screen button. A click anywhere on it is the button; on the
/// secure cover the click is taken and nothing is sent. The view never reaches
/// the input mapper, and the window suspends input while it is up.
final class PhoneScreenOverlayView: NSView {
    /// The person wants the phone's screen back (the window sends `phone.wake`).
    var onWake: (() -> Void)?

    /// What is covered right now (nil: live video).
    private(set) var cover: PhoneCover?

    private let blur = NSVisualEffectView()
    private let dim = NSView()
    private let message = NSTextField(labelWithString: "The phone's screen is off")
    private let button = NSButton(title: "Wake Screen", target: nil, action: nil)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        // A strong material over the frozen frame, then a dim layer so white
        // text keeps its contrast over any picture.
        blur.material = .hudWindow
        blur.blendingMode = .withinWindow
        blur.state = .active
        blur.autoresizingMask = [.width, .height]
        addSubview(blur)
        dim.wantsLayer = true
        dim.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.38).cgColor
        dim.autoresizingMask = [.width, .height]
        addSubview(dim)
        message.font = .systemFont(ofSize: 15, weight: .medium)
        message.textColor = .white
        message.alignment = .center
        addSubview(message)
        button.bezelStyle = .rounded
        button.controlSize = .large
        button.target = self
        button.action = #selector(wakePressed)
        addSubview(button)
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isOpaque: Bool { false }

    /// Shows the cover for `cover`, or takes it away (nil). The sleeping panel
    /// offers Wake Screen; a secure surface has no button and says why.
    func show(_ cover: PhoneCover?) {
        self.cover = cover
        isHidden = cover == nil
        switch cover {
        case .screenOff:
            message.stringValue = "The phone's screen is off"
            button.isHidden = false
        case .secure:
            message.stringValue = "Android doesn't let PocketDeck show this screen."
            button.isHidden = true
        case nil:
            break
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        blur.frame = bounds
        dim.frame = bounds
        let messageSize = message.intrinsicContentSize
        let showsButton = !button.isHidden
        let buttonSize = showsButton ? button.intrinsicContentSize : .zero
        let gap: CGFloat = showsButton ? 14 : 0
        let total = messageSize.height + gap + buttonSize.height
        let top = (bounds.height - total) / 2
        message.frame = NSRect(x: 0, y: top + gap + buttonSize.height,
                               width: bounds.width, height: messageSize.height)
        button.frame = NSRect(x: (bounds.width - buttonSize.width) / 2, y: top,
                              width: buttonSize.width, height: buttonSize.height)
    }

    /// The button keeps its own click; every other point in the overlay is the
    /// same Wake Screen action, so the whole blurred frame is clickable.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, let superview else { return nil }
        guard bounds.contains(convert(point, from: superview)) else { return nil }
        if cover == .screenOff, let hit = button.hitTest(convert(point, from: superview)) { return hit }
        return self
    }

    override func mouseDown(with event: NSEvent) {
        // The secure cover takes the click and sends nothing: there is no
        // button, and the phone's PIN pad must never see a stray tap.
        guard cover == .screenOff else { return }
        onWake?()
    }

    @objc private func wakePressed(_ sender: Any?) {
        guard cover == .screenOff else { return }
        onWake?()
    }
}
