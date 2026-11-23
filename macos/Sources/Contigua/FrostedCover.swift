// One look for every full-window cover (ISS-55, ISS-66): the held picture
// blurred hard and darkened, white wrapping words and an optional glass capsule
// button, fading in and out over 200 ms. The picture memory keeps the last
// picture's top and bottom average colours for a cover that arrives with no
// frame held (docs/specs/phone-mirror.md MIRROR-6, docs/specs/app-windows.md
// WIN-11 and WIN-39). The fade is one small state machine; the view runs its
// actions.

import AppKit
import CoreImage
import CoreVideo

/// What the shared cover is drawn over.
enum CoverBackdrop: Equatable {
    case heldFrame(NSImage)
    case gradient(top: NSColor, bottom: NSColor)
    case black
}

/// The shared cover's numbers. The dim is tuned above the prototype's 0.45 so
/// white text reads at WCAG AA over a white frame (0.55 black leaves 0.45
/// white: 4.86:1, where 0.45 black leaves only 3.37:1).
enum FrostedCoverStyle {
    static let blurRadius: CGFloat = 30
    static let dimAlpha: CGFloat = 0.55
    static let titleSize: CGFloat = 15
    static let lineSize: CGFloat = 13
    static let sideInset: CGFloat = 24
    static let fadeSeconds: TimeInterval = 0.2
    static let iconSide: CGFloat = 96
    static let buttonHeight: CGFloat = 30
    static let buttonSidePadding: CGFloat = 40
    static let buttonMinWidth: CGFloat = 96
    static let lineGap: CGFloat = 6
    static let titleGap: CGFloat = 12
    static let iconGap: CGFloat = 14
    static let buttonGap: CGFloat = 16

    static func contrast(_ a: NSColor, _ b: NSColor) -> Double {
        let la = luminance(a)
        let lb = luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    static func luminance(_ color: NSColor) -> Double {
        guard let rgb = color.usingColorSpace(.sRGB) else { return 0 }
        func channel(_ value: CGFloat) -> Double {
            let c = Double(value)
            return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(rgb.redComponent) + 0.7152 * channel(rgb.greenComponent)
            + 0.0722 * channel(rgb.blueComponent)
    }
}

/// The last picture a cover saw, blurred for the backdrop, and its top and
/// bottom average colours: a later cover with no frame held still gets the
/// picture's colours rather than a flat fill.
struct CoverPicture {
    private(set) var blurred: NSImage?
    private(set) var top: NSColor?
    private(set) var bottom: NSColor?

    var hasColours: Bool { top != nil && bottom != nil }

    mutating func remember(_ buffer: CVPixelBuffer, viewWidth: CGFloat) {
        let image = CIImage(cvPixelBuffer: buffer)
        let extent = image.extent
        guard extent.width >= 1, extent.height >= 1 else { return }
        if let colours = Self.averageColours(image) {
            top = colours.top
            bottom = colours.bottom
        }
        blurred = Self.blurred(image, viewWidth: viewWidth)
    }

    /// The backdrop for a cover that has no frame right now.
    var fallback: CoverBackdrop {
        if let top, let bottom { return .gradient(top: top, bottom: bottom) }
        return .black
    }

    private static let context = CIContext(options: [.cacheIntermediates: false])

    /// A hard still blur: the frame is downscaled to at most 1024 px first so
    /// a 1080x2340 phone frame never costs the window server a full-size
    /// blurred copy for a picture nobody can inspect at that detail.
    static func blurred(_ image: CIImage, viewWidth: CGFloat) -> NSImage? {
        let extent = image.extent
        guard extent.width >= 1, extent.height >= 1 else { return nil }
        let scale = min(1, 1024 / max(extent.width, extent.height))
        let scaled = scale < 1 ? image.transformed(by: CGAffineTransform(scaleX: scale, y: scale)) : image
        let width = max(scaled.extent.width, 1)
        // 30 pt at the display's own width; a phone frame is wider than the
        // window in pixels, so the radius follows the picture's scale. The cap
        // keeps a zero-width view from asking for a huge radius.
        let radius = max(1, min(240, FrostedCoverStyle.blurRadius * width / max(viewWidth, 100)))
        let blurred = scaled.clampedToExtent()
            .applyingGaussianBlur(sigma: Double(radius))
            .cropped(to: scaled.extent)
        guard let cgImage = context.createCGImage(blurred, from: scaled.extent.integral) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: scaled.extent.width, height: scaled.extent.height))
    }

    private static func averageColours(_ image: CIImage) -> (top: NSColor, bottom: NSColor)? {
        let extent = image.extent
        let topRect = CGRect(x: extent.minX, y: extent.midY, width: extent.width, height: extent.height / 2)
        let bottomRect = CGRect(x: extent.minX, y: extent.minY, width: extent.width, height: extent.height / 2)
        guard let top = average(image, rect: topRect), let bottom = average(image, rect: bottomRect) else {
            return nil
        }
        return (top, bottom)
    }

    private static func average(_ image: CIImage, rect: CGRect) -> NSColor? {
        guard let filter = CIFilter(name: "CIAreaAverage", parameters: [
            kCIInputImageKey: image,
            kCIInputExtentKey: CIVector(cgRect: rect),
        ]), let output = filter.outputImage else { return nil }
        var bitmap = [UInt8](repeating: 0, count: 4)
        bitmap.withUnsafeMutableBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            context.render(output, toBitmap: base, rowBytes: 4,
                           bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                           format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        }
        return NSColor(srgbRed: CGFloat(bitmap[0]) / 255, green: CGFloat(bitmap[1]) / 255,
                       blue: CGFloat(bitmap[2]) / 255, alpha: 1)
    }
}

/// The cover's one motion machine: hidden -> fadingIn -> shown -> fadingOut ->
/// hidden, 200 ms each way. It returns actions; the view renders them.
struct CoverFade: Equatable {
    enum State: Equatable {
        case hidden
        case fadingIn
        case shown
        case fadingOut
    }

    enum Event: Equatable {
        case show
        case hide
        case tick(TimeInterval)
    }

    enum Action: Equatable {
        case showView
        case hideView
        case render(Double)
    }

    static let duration: TimeInterval = FrostedCoverStyle.fadeSeconds

    /// Closed names for the transition log (`cover fade: hidden --show--> fadingIn`).
    static func name(_ state: State) -> String {
        switch state {
        case .hidden: return "hidden"
        case .fadingIn: return "fadingIn"
        case .shown: return "shown"
        case .fadingOut: return "fadingOut"
        }
    }

    static func name(_ event: Event) -> String {
        switch event {
        case .show: return "show"
        case .hide: return "hide"
        case .tick: return "tick"
        }
    }

    private(set) var state: State = .hidden
    private(set) var startedAt: TimeInterval?
    private(set) var alpha: Double = 0
    private(set) var fromAlpha: Double = 0

    var isAnimating: Bool { state == .fadingIn || state == .fadingOut }

    /// How far a fade started at `start` is at `time`, 0...1. The end is
    /// `time >= start + duration`, the same sum a caller jumping to the end
    /// computes: `(time - start) / duration` rounds below 1 for most starts.
    private static func progress(at time: TimeInterval, from start: TimeInterval?) -> Double {
        let start = start ?? time
        guard time < start + duration else { return 1 }
        return min(1, max(0, (time - start) / duration))
    }

    mutating func handle(_ event: Event, at now: TimeInterval) -> [Action] {
        switch (state, event) {
        case (.hidden, .show):
            state = .fadingIn
            startedAt = now
            fromAlpha = 0
            alpha = 0
            return [.showView, .render(0)]
        case (.hidden, .hide), (.hidden, .tick):
            return []
        case (.fadingIn, .show):
            return []
        case (.fadingIn, .hide):
            state = .fadingOut
            startedAt = now
            fromAlpha = alpha
            return [.render(alpha)]
        case (.fadingIn, .tick(let time)):
            let progress = Self.progress(at: time, from: startedAt)
            alpha = fromAlpha + (1 - fromAlpha) * progress
            guard progress < 1 else {
                state = .shown
                startedAt = nil
                alpha = 1
                return [.render(1)]
            }
            return [.render(alpha)]
        case (.shown, .show), (.shown, .tick):
            return []
        case (.shown, .hide):
            state = .fadingOut
            startedAt = now
            fromAlpha = 1
            return [.render(1)]
        case (.fadingOut, .show):
            state = .fadingIn
            startedAt = now
            fromAlpha = alpha
            return [.render(alpha)]
        case (.fadingOut, .hide):
            return []
        case (.fadingOut, .tick(let time)):
            let progress = Self.progress(at: time, from: startedAt)
            alpha = fromAlpha * (1 - progress)
            guard progress < 1 else {
                state = .hidden
                startedAt = nil
                alpha = 0
                return [.render(0), .hideView]
            }
            return [.render(alpha)]
        }
    }
}

/// What a cover says. Every cover fills this in; the shared view draws it.
struct FrostedCoverContent {
    var title: String
    var line: String?
    var button: String?
    var icon: NSImage?
    var showsIcon = false
    var iconIsDimmed = false
    var showsSweep = false
    var topInset: CGFloat = 0
}

/// The shared full-window cover: the held picture blurred hard and darkened,
/// the title and optional line centred in white, an optional glass capsule
/// button, and the fade machine. It takes every click that is not its button,
/// so a covered stream never sees a stray touch.
class FrostedCoverView: NSView {
    var onPrimary: (() -> Void)?
    /// A click anywhere on the cover (the sleeping panel wakes from one).
    var onCoverClick: (() -> Void)?
    /// The cover came or went (`isHidden` flipped): the chrome lays out with
    /// the compact geometry while a cover is up (WIN-11).
    var onVisibilityChange: (() -> Void)?

    /// The bar's height: the words centre in the body below it.
    var topInset: CGFloat = 0 {
        didSet { if topInset != oldValue { needsLayout = true } }
    }

    private(set) var content: FrostedCoverContent?
    private(set) var fade = CoverFade()
    private(set) var backdrop: CoverBackdrop = .black

    private let backdropLayer = CALayer()
    private let gradientLayer = CAGradientLayer()
    private let dimLayer = CALayer()
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let lineLabel = NSTextField(labelWithString: "")
    private let sweep = NSView()
    private let sweepLayer = CAGradientLayer()
    private let buttonBacking = NSView()
    private let buttonGlass = NSGlassEffectView()
    private var button: NSButton?
    private var buttonTitle: String?
    private var buttonSize = NSSize.zero
    private var fadeTimer: Timer?
    private var picture = CoverPicture()

    /// Reduce Motion, read when the cover comes or goes (tests set it).
    var reduceMotion: () -> Bool = {
        Motion.reduce(system: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    }

    /// The fade's state, for the tests and the chrome state.
    var isShowing: Bool { content != nil }

    /// The sheet is on screen now — held, fading in or still fading out. A
    /// capture may call it evidence only when this is false.
    var isVisiblyShowing: Bool { fade.state != .hidden }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false
        backdropLayer.contentsGravity = .resizeAspectFill
        backdropLayer.backgroundColor = NSColor.black.cgColor
        backdropLayer.name = "frosted-cover.backdrop.black"
        layer?.addSublayer(backdropLayer)
        gradientLayer.startPoint = CGPoint(x: 0.5, y: 1)
        gradientLayer.endPoint = CGPoint(x: 0.5, y: 0)
        gradientLayer.isHidden = true
        layer?.addSublayer(gradientLayer)
        dimLayer.backgroundColor = NSColor.black.withAlphaComponent(FrostedCoverStyle.dimAlpha).cgColor
        dimLayer.name = "frosted-cover.dim"
        layer?.addSublayer(dimLayer)

        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.wantsLayer = true
        iconView.layer?.cornerRadius = 22
        iconView.layer?.cornerCurve = .continuous
        iconView.layer?.masksToBounds = true
        iconView.isHidden = true
        addSubview(iconView)

        for label in [titleLabel, lineLabel] {
            label.font = .systemFont(ofSize: label === titleLabel
                                     ? FrostedCoverStyle.titleSize : FrostedCoverStyle.lineSize,
                                     weight: label === titleLabel ? .semibold : .regular)
            label.textColor = .white
            label.alignment = .center
            label.lineBreakMode = .byWordWrapping
            label.maximumNumberOfLines = 3
            label.cell?.wraps = true
            label.isHidden = true
            addSubview(label)
        }

        sweep.wantsLayer = true
        sweepLayer.colors = [NSColor.controlAccentColor.withAlphaComponent(0).cgColor,
                             NSColor.controlAccentColor.cgColor,
                             NSColor.controlAccentColor.withAlphaComponent(0).cgColor]
        sweepLayer.startPoint = CGPoint(x: 0, y: 0.5)
        sweepLayer.endPoint = CGPoint(x: 1, y: 0.5)
        sweepLayer.locations = [0, 0.5, 1]
        sweep.layer?.addSublayer(sweepLayer)
        sweep.isHidden = true
        addSubview(sweep)

        buttonBacking.wantsLayer = true
        buttonBacking.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.3).cgColor
        buttonBacking.isHidden = true
        addSubview(buttonBacking)
        buttonGlass.style = .clear
        buttonGlass.tintColor = NSColor.black.withAlphaComponent(0.35)
        buttonGlass.isHidden = true
        addSubview(buttonGlass)

        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }  // unrecoverable: NSCoder is never used

    deinit {
        // A window can close mid-fade: an orphaned 60 Hz timer would keep the
        // run loop busy for the rest of the app's life.
        fadeTimer?.invalidate()
    }

    override var isOpaque: Bool { false }

    /// Shows `content` (the fade starts on the first show) or takes the cover
    /// away (nil). `heldFrame` is the picture displayed right now; when it is
    /// nil the cover uses the last picture's average colours, else black.
    func show(_ content: FrostedCoverContent?, heldFrame: CVPixelBuffer? = nil) {
        let now = ProcessInfo.processInfo.systemUptime
        let wasShowing = isShowing
        guard let content else {
            self.content = nil
            // The chrome's geometry follows the picture the moment the cover
            // is logically gone; the sheet itself fades out above it.
            if wasShowing { onVisibilityChange?() }
            run(.hide, at: now)
            return
        }
        if let heldFrame {
            picture.remember(heldFrame, viewWidth: max(bounds.width, 1))
        }
        self.content = content
        topInset = content.topInset
        apply(content)
        rebuildBackdrop()
        if isHidden {
            isHidden = false
        }
        if !wasShowing { onVisibilityChange?() }
        run(.show, at: now)
        needsLayout = true
    }

    /// The fade reached its end or a new one started: render it. Reduce Motion
    /// takes the cover in or out at once (CONV-MAC-22).
    private func run(_ event: CoverFade.Event, at now: TimeInterval) {
        let before = fade.state
        var actions = fade.handle(event, at: now)
        if reduceMotion(), fade.isAnimating {
            actions += fade.handle(.tick(now + CoverFade.duration), at: now + CoverFade.duration)
        }
        if fade.state != before {
            // Closed tokens only: the fade's path in a field log (AGENTS.md).
            Log.app.debug("cover fade: \(CoverFade.name(before), privacy: .public) --\(CoverFade.name(event), privacy: .public)--> \(CoverFade.name(self.fade.state), privacy: .public)")  // log-ok: closed fade state tokens, never a person's value
        }
        for action in actions {
            switch action {
            case .showView:
                isHidden = false
                alphaValue = CGFloat(fade.alpha)
            case .hideView:
                alphaValue = 1
                isHidden = true
            case .render(let alpha):
                alphaValue = CGFloat(alpha)
            }
        }
        if fade.isAnimating { startFadeTimer() } else { stopFadeTimer() }
    }

    private func startFadeTimer() {
        guard fadeTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.run(.tick(ProcessInfo.processInfo.systemUptime), at: ProcessInfo.processInfo.systemUptime)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        fadeTimer = timer
    }

    private func stopFadeTimer() {
        fadeTimer?.invalidate()
        fadeTimer = nil
    }

    private func apply(_ content: FrostedCoverContent) {
        titleLabel.stringValue = content.title
        titleLabel.isHidden = content.title.isEmpty
        lineLabel.stringValue = content.line ?? ""
        lineLabel.isHidden = (content.line ?? "").isEmpty
        if content.showsIcon {
            let picture = content.icon
                ?? NSImage(systemSymbolName: "app.dashed", accessibilityDescription: nil)
            iconView.image = picture
            iconView.contentTintColor = content.iconIsDimmed ? .systemGray : NSColor(white: 0.92, alpha: 1)
            iconView.alphaValue = content.iconIsDimmed && picture?.isTemplate == false ? 0.55 : 1
            iconView.isHidden = picture == nil
        } else {
            iconView.image = nil
            iconView.isHidden = true
        }
        applyButton(content.button)
        sweep.isHidden = !content.showsSweep
        startSweep(active: content.showsSweep)
        needsLayout = true
    }

    private func applyButton(_ title: String?) {
        guard title != buttonTitle else { return }
        buttonTitle = title
        button?.removeFromSuperview()
        button = nil
        buttonSize = .zero
        buttonBacking.isHidden = title == nil
        buttonGlass.isHidden = title == nil
        guard let title else { return }
        let attributed = NSAttributedString(string: title, attributes: [
            .foregroundColor: NSColor.white,
            .font: NSFont.systemFont(ofSize: FrostedCoverStyle.lineSize, weight: .semibold),
        ])
        let text = attributed.size()
        buttonSize = NSSize(width: max(FrostedCoverStyle.buttonMinWidth,
                                       ceil(text.width) + FrostedCoverStyle.buttonSidePadding),
                           height: FrostedCoverStyle.buttonHeight)
        let button = NSButton(title: title, target: self, action: #selector(primaryPressed))
        button.isBordered = false
        button.bezelStyle = .inline
        button.focusRingType = .none
        button.attributedTitle = attributed
        button.alignment = .center
        button.setAccessibilityLabel(title)
        button.setAccessibilityRole(.button)
        addSubview(button, positioned: .above, relativeTo: buttonGlass)
        self.button = button
    }

    private func rebuildBackdrop() {
        let kind: CoverBackdrop
        if let blurred = picture.blurred {
            kind = .heldFrame(blurred)
        } else {
            kind = picture.fallback
        }
        backdrop = kind
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        backdropLayer.name = nil
        gradientLayer.name = nil
        switch kind {
        case .heldFrame(let image):
            backdropLayer.contents = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
            backdropLayer.backgroundColor = nil
            backdropLayer.name = "frosted-cover.backdrop.held"
            gradientLayer.isHidden = true
        case .gradient(let top, let bottom):
            backdropLayer.contents = nil
            backdropLayer.backgroundColor = nil
            gradientLayer.colors = [top.cgColor, bottom.cgColor]
            gradientLayer.name = "frosted-cover.backdrop.gradient"
            gradientLayer.isHidden = false
        case .black:
            backdropLayer.contents = nil
            backdropLayer.backgroundColor = NSColor.black.cgColor
            backdropLayer.name = "frosted-cover.backdrop.black"
            gradientLayer.isHidden = true
        }
        CATransaction.commit()
    }

    private func startSweep(active: Bool) {
        sweepLayer.frame = sweep.bounds
        sweepLayer.removeAnimation(forKey: "sweep")
        guard active else { return }
        guard !reduceMotion() else {
            sweepLayer.locations = [0.3, 0.45, 0.6]
            return
        }
        sweepLayer.locations = [0, 0.5, 1]
        let animation = CABasicAnimation(keyPath: "locations")
        animation.fromValue = [-0.4, -0.2, 0]
        animation.toValue = [1, 1.2, 1.4]
        animation.duration = 1.25
        animation.repeatCount = .infinity
        sweepLayer.add(animation, forKey: "sweep")
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        backdropLayer.frame = bounds
        gradientLayer.frame = bounds
        dimLayer.frame = bounds
        sweep.frame = NSRect(x: 0, y: bounds.height - 2, width: bounds.width, height: 2)
        sweepLayer.frame = sweep.bounds
        CATransaction.commit()

        let sideInset = FrostedCoverStyle.sideInset
        let textWidth = max(bounds.width - sideInset * 2, 80)
        let iconSide = iconView.isHidden ? 0 : FrostedCoverStyle.iconSide
        let titleHeight = titleLabel.isHidden ? 0 : height(of: titleLabel, width: textWidth)
        let lineHeight = lineLabel.isHidden ? 0 : height(of: lineLabel, width: textWidth)
        let buttonHeight = button == nil ? 0 : buttonSize.height
        enum Part { case icon, title, line, button }
        var items: [(part: Part, height: CGFloat, gap: CGFloat)] = []
        func add(_ part: Part, _ height: CGFloat, _ gap: CGFloat) {
            guard height > 0 else { return }
            items.append((part: part, height: height, gap: items.isEmpty ? 0 : gap))
        }
        add(.icon, iconSide, FrostedCoverStyle.iconGap)
        add(.title, titleHeight, FrostedCoverStyle.titleGap)
        add(.line, lineHeight, FrostedCoverStyle.lineGap)
        add(.button, buttonHeight, FrostedCoverStyle.buttonGap)
        let total = items.reduce(CGFloat.zero) { $0 + $1.height + $1.gap }
        var y = topInset + (bounds.height - topInset + total) / 2
        for item in items {
            y -= item.gap + item.height
            switch item.part {
            case .icon:
                iconView.frame = NSRect(x: (bounds.width - iconSide) / 2, y: y,
                                        width: iconSide, height: iconSide)
            case .title:
                titleLabel.frame = NSRect(x: sideInset, y: y, width: textWidth, height: titleHeight)
            case .line:
                lineLabel.frame = NSRect(x: sideInset, y: y, width: textWidth, height: lineHeight)
            case .button:
                let frame = NSRect(x: (bounds.width - buttonSize.width) / 2, y: y,
                                   width: buttonSize.width, height: buttonSize.height)
                buttonBacking.frame = frame
                buttonBacking.layer?.cornerRadius = buttonSize.height / 2
                buttonGlass.frame = frame
                buttonGlass.cornerRadius = buttonSize.height / 2
                button?.frame = frame
            }
        }
    }

    private func height(of label: NSTextField, width: CGFloat) -> CGFloat {
        label.preferredMaxLayoutWidth = width
        let size = label.sizeThatFits(NSSize(width: width, height: .greatestFiniteMagnitude))
        return ceil(size.height)
    }

    /// The title's drawn frame and the button, for the layout tests.
    var titleFrame: NSRect { titleLabel.frame }
    var titleText: String { titleLabel.stringValue }
    var lineText: String { lineLabel.stringValue }
    var buttonFrame: NSRect? {
        guard let button, !button.isHidden else { return nil }
        return button.frame
    }
    var buttonLabel: String? { button?.title }
    var iconPicture: NSImage? { iconView.image }
    var hasIcon: Bool { !iconView.isHidden }
    var sweepFrame: NSRect { sweep.frame }

    /// A cover button's centre in window coordinates, nil while it is not up.
    func buttonCentre(_ title: String) -> NSPoint? {
        guard let button, !button.isHidden, button.title == title else { return nil }
        return button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
    }

    @discardableResult
    func press(_ title: String) -> Bool {
        guard let button, !button.isHidden, button.title == title else { return false }
        button.performClick(nil)
        return true
    }

    /// The buttons keep their clicks; every other point is the cover's and
    /// reaches nothing (the sleeping panel turns it into one wake).
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, content != nil, let superview else { return nil }
        guard bounds.contains(convert(point, from: superview)) else { return nil }
        if let button, !button.isHidden,
           let hit = button.hitTest(convert(point, from: superview)) { return hit }
        return self
    }

    override func mouseDown(with event: NSEvent) {
        guard content != nil else { return }
        onCoverClick?()
    }

    @objc private func primaryPressed(_ sender: Any?) {
        onPrimary?()
    }
}

extension FrostedCoverView {
    /// The hit-test point a test uses for the whole cover.
    var coverCentreInWindow: NSPoint {
        convert(NSPoint(x: bounds.midX, y: bounds.midY), to: nil)
    }
}
