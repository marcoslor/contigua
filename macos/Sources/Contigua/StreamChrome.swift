// The stream window's chrome by style (WindowStyle.swift). Compact: a
// permanent 28 pt bar above the stream. The mirror is NSBackgroundExtensionView:
// the video view is its contentView and it fills the rest of its frame — here
// the bar band — with a replica of the content's top edge, so nothing is read
// back off the CPU and nothing is decoded twice. The replica carries the
// system's progressive blur (strongest at the window's top edge, sharp at the
// seam) turned up to 30 pt (BarBlur.swift), a 14 % window-background tint and a
// light white haze over the bar band only, clear at its seam. The centred title
// is the app's name and the phone's, in the tone the band behind it allows
// (BarTitle.swift). Framed: the picture sits inside a real frame on all four
// sides (FramedChrome): a system material, a 0.5 pt hairline, a 1 pt rim, a
// 10 pt top highlight, a 21 pt window radius and a 12 pt picture radius, with
// our lights, a label-coloured title and our controls in the 38 pt bar.
// Immersive: the old pill style — no bar, no borders, the picture fills the
// window, and the lights and our controls live on a clear-glass pill that the
// dwell brings in (DwellChrome, DwellPill). Full screen: in Framed and
// Compact the stream fills the screen and one 28 pt acrylic bar, hidden until
// the pointer reaches the top edge, carries our lights, title and controls
// (FullScreenBar, FullScreenBarMachine); in Immersive the system's own title bar
// is returned to AppKit, as it was before the merge.

import AppKit
import SwiftUI

/// The Immersive style's dwell pill (DwellChrome): clear glass at the stream's
/// top-left corner — it blurs what is under it without the regular glass's grey
/// fill — and its empty areas drag the window; the window kind's actions and
/// the real traffic lights (which ride the window's title area above this view)
/// sit on top.
final class DwellPillView: NSGlassEffectView {
    /// A click that reached the pill (the e2e check counts them).
    var onPress: (() -> Void)?

    init() {
        super.init(frame: NSRect(origin: .zero, size: CGSize(width: DwellChrome.pillWidth(actions: []),
                                                             height: DwellChrome.pillHeight)))
        cornerRadius = DwellChrome.pillCornerRadius
        // Clear glass: the blur stays, the grey scrim does not. The traffic
        // lights and the kind's actions are standard controls over it, so
        // nothing needs a tinted backdrop to stay legible.
        style = .clear
        tintColor = .clear
        alphaValue = 0
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }  // unrecoverable: no nib or coder builds this view

    override func mouseDown(with event: NSEvent) {
        onPress?()
        window?.performDrag(with: event)
    }
}

/// The Framed style's frame: the translucent system material, the 0.5 pt outer
/// hairline, the 1 pt inner rim, the 10 pt top highlight, and the window title
/// on the bar's centre line. Sits under the stream and the chrome's controls.
final class FramedChromeView: NSView {
    private let material = NSVisualEffectView()
    private let tintLayer = CALayer()
    private let highlightLayer = CAGradientLayer()
    private let hairlineLayer = CAShapeLayer()
    private let rimLayer = CAShapeLayer()
    private let titleLabel = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = FramedChrome.outerRadius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true

        // The desktop behind the window is the material's backdrop, never a
        // copy of the picture: Framed's bar is a real material bar, not the
        // Compact mirror.
        material.blendingMode = .behindWindow
        material.state = .active
        material.wantsLayer = true
        material.layer?.zPosition = -10
        addSubview(material)

        tintLayer.masksToBounds = true
        tintLayer.zPosition = 0
        layer?.addSublayer(tintLayer)

        highlightLayer.startPoint = CGPoint(x: 0.5, y: 1)
        highlightLayer.endPoint = CGPoint(x: 0.5, y: 0)
        highlightLayer.zPosition = 1
        layer?.addSublayer(highlightLayer)

        for (depth, shape) in [hairlineLayer, rimLayer].enumerated() {
            shape.fillColor = NSColor.clear.cgColor
            shape.lineJoin = .round
            shape.zPosition = CGFloat(depth + 2)
            layer?.addSublayer(shape)
        }

        BarTitle.configure(titleLabel)
        titleLabel.textColor = FramedChrome.titleColor
        addSubview(titleLabel)
        titleLabel.layer?.zPosition = 5

        updateAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }  // unrecoverable: the view is never decoded

    /// The window's appearance can arrive after this view was built (the chrome
    /// is created before its window): take the material again when it does.
    func refreshAppearance() {
        updateAppearance()
    }

    private var titleRightEdge: CGFloat = 0
    /// The name without the phone suffix, for the narrow-window drop.
    private var titleBase: String?

    func setTitle(_ title: String?, base: String? = nil, rightEdge: CGFloat) {
        titleLabel.stringValue = title ?? ""
        titleBase = base
        titleRightEdge = rightEdge
        // Always lay out: the frame is hidden while Compact, so a title set
        // then has no laid-out label yet; the switch to Framed must place it.
        needsLayout = true
    }

    /// The tests read the bar's own label (its place, its truncation and its
    /// colour); nothing in the app does.
    var titleText: String { titleLabel.stringValue }
    var titleFrame: NSRect { titleLabel.frame }
    var titleLineBreakMode: NSLineBreakMode { titleLabel.lineBreakMode }
    var titleTextColor: NSColor { titleLabel.textColor ?? .labelColor }
    var titlePointSize: CGFloat { titleLabel.font?.pointSize ?? 0 }
    var titleIsHidden: Bool { titleLabel.isHidden }
    var materialKind: NSVisualEffectView.Material { material.material }
    var tintColor: NSColor {
        tintLayer.backgroundColor.map { NSColor(cgColor: $0) ?? .clear } ?? .clear
    }
    var highlightFrame: NSRect { highlightLayer.frame }
    var hairlineWidth: CGFloat { hairlineLayer.lineWidth }
    var rimWidth: CGFloat { rimLayer.lineWidth }

    /// The title's rect between the lights and the right-hand controls, with
    /// the same 8 pt clearance and hide thresholds as the Compact bar
    /// (WIN-68), and the phone suffix dropped first when the room is short.
    private func fitting() -> (text: String, frame: NSRect)? {
        let lightsEnd = FramedChrome.lightInset + 2 * ChromeBar.trafficLightSpacing
            + ChromeBar.trafficLightButtonSide
        return BarTitle.fitting(text: titleLabel.stringValue, base: titleBase,
                                windowWidth: bounds.width, barHeight: FramedChrome.topInset,
                                boundsHeight: bounds.height, lightsEnd: lightsEnd,
                                rightRowStart: titleRightEdge)
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        material.frame = bounds
        tintLayer.frame = bounds
        let inset = FramedChrome.hairline / 2
        hairlineLayer.path = CGPath(roundedRect: bounds.insetBy(dx: inset, dy: inset),
                                    cornerWidth: FramedChrome.outerRadius - inset,
                                    cornerHeight: FramedChrome.outerRadius - inset,
                                    transform: nil)
        hairlineLayer.lineWidth = FramedChrome.hairline
        let rimInset = FramedChrome.hairline + FramedChrome.rim / 2
        rimLayer.path = CGPath(roundedRect: bounds.insetBy(dx: rimInset, dy: rimInset),
                               cornerWidth: FramedChrome.outerRadius - rimInset,
                               cornerHeight: FramedChrome.outerRadius - rimInset,
                               transform: nil)
        rimLayer.lineWidth = FramedChrome.rim
        highlightLayer.frame = NSRect(x: FramedChrome.hairline + FramedChrome.rim,
                                      y: bounds.height - FramedChrome.hairline - FramedChrome.rim
                                          - FramedChrome.highlightHeight,
                                      width: max(bounds.width - 2 * (FramedChrome.hairline + FramedChrome.rim), 0),
                                      height: FramedChrome.highlightHeight)
        let fit = fitting()
        BarTitle.layOut(fit?.text, in: titleLabel, frame: fit?.frame)
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAppearance()
    }

    /// The measured material: a 90 % tint toward #2c3137 in dark appearance, a
    /// 12 % white veil in light, so the desktop's colour carries through.
    private func updateAppearance() {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        material.material = .underWindowBackground
        tintLayer.backgroundColor = (dark
            ? NSColor(srgbRed: 44 / 255, green: 49 / 255, blue: 55 / 255, alpha: 0.90)
            : NSColor(white: 1, alpha: 0.12)).cgColor
        hairlineLayer.strokeColor = NSColor.black.withAlphaComponent(dark ? 0.90 : 0.28).cgColor
        rimLayer.strokeColor = NSColor.white.withAlphaComponent(dark ? 0.22 : 0.62).cgColor
        highlightLayer.colors = [
            NSColor.white.withAlphaComponent(dark ? 0.12 : 0.32).cgColor,
            NSColor.white.withAlphaComponent(0).cgColor,
        ]
        titleLabel.textColor = FramedChrome.titleColor
        needsLayout = true
    }
}

/// The full-screen bar's background: the system's full-screen material,
/// blended within the window so it frosts the stream under it. The title rides
/// inside it; the lights and our controls are placed on its line by the chrome.
final class FullScreenBarView: NSVisualEffectView {
    private let titleLabel = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        material = FullScreenBar.material
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        BarTitle.configure(titleLabel)
        titleLabel.textColor = FullScreenBar.titleColor
        addSubview(titleLabel)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }  // unrecoverable: the view is never decoded

    func setTitle(_ title: String?, base: String? = nil) {
        titleLabel.stringValue = title ?? ""
        titleBase = base
        needsLayout = true
    }

    private var titleBase: String?

    var titleText: String { titleLabel.stringValue }
    var titleFrame: NSRect { titleLabel.frame }
    var titleIsHidden: Bool { titleLabel.isHidden }
    var titleTextColor: NSColor { titleLabel.textColor ?? .labelColor }

    /// The title between the lights and the controls, with WIN-68's clearance,
    /// hide thresholds and middle truncation; the phone suffix goes first.
    private func fitting(rightRowStart: CGFloat) -> (text: String, frame: NSRect)? {
        BarTitle.fitting(text: titleLabel.stringValue, base: titleBase,
                         windowWidth: bounds.width, barHeight: FullScreenBar.height,
                         boundsHeight: bounds.height, lightsEnd: BarTitle.lightsEnd,
                         rightRowStart: rightRowStart)
    }

    func layoutTitle(rightRowStart: CGFloat) {
        let fit = fitting(rightRowStart: rightRowStart)
        BarTitle.layOut(fit?.text, in: titleLabel, frame: fit?.frame)
    }

    override func layout() {
        super.layout()
        needsLayout = false
    }
}

/// The window's content: the stream, the style's windowed chrome — Compact's
/// mirrored bar or Framed's material frame, with the traffic lights and our
/// controls on their line — the full-screen acrylic bar and its title, the
/// covers, and the kind's actions at the bar's right end.
final class StreamChromeView: NSView {
    let video: VideoLayerView
    /// The bar's mirror: the extension view spans the whole window, so the
    /// band beyond the video's top edge is its filled replica — blurred
    /// progressively by the system, with no material over it.
    private let ext = BarMirrorView()
    /// The Framed style's material, hairline, rim, highlight and title.
    private let framedView = FramedChromeView()
    /// The full-screen bar: the acrylic ground and its centred title.
    private let fullBarView = FullScreenBarView()
    /// The full-screen bar's slide: 1 while it is fully off the top edge.
    private(set) var fullBarOffset: CGFloat = FullScreenBar.height
    /// The FullScreenBarView's sibling for the Immersive style: the clear-glass
    /// pill; only a background: the buttons above it are the chrome's own
    /// subviews so they can move between the pill's row and their home slots.
    private let pillView = DwellPillView()
    /// The haze over the bar band only: white at the window's top edge, clear
    /// at the seam (WIN-40). Above the mirror, below the bar's controls.
    private let hazeLayer = CAGradientLayer()
    /// The 14 % window-background tint over the bar band (WIN-67), above the
    /// haze and below the title and the controls.
    private let tintLayer = CALayer()
    /// The centred title, one field per tone so a tone change cross-fades
    /// instead of blinking (WIN-68, WIN-69). `titleLight` is white ink,
    /// `titleDark` black.
    private let titleLight = NSTextField(labelWithString: "")
    private let titleDark = NSTextField(labelWithString: "")
    /// What the bar names; nil hides the title (WIN-68). `titleText` is the
    /// name without the phone suffix; `titlePhone` is the phone's display name
    /// the suffix is built from.
    private(set) var titleText: String?
    private var titlePhone: String?
    /// The title's frame in this view, nil while hidden.
    private var titleFrame: NSRect?
    private var titleVisible = false
    /// The band's two tones and their hysteresis (WIN-69).
    private var toneMachine = BarToneMachine()
    /// The displayed picture's top band, the mirror's own source.
    private let toneSource: BarToneSource
    /// Reduce Motion: a tone change applies at once.
    private let reduceMotion: () -> Bool
    private var toneTimer: Timer?
    private var toneSampleInFlight = false
    private var lastToneStamp: UInt64?
    private var loggedUnresolvedTone = false
    /// Re-applies the system blur radius when the hosting view builds or
    /// rebuilds its backdrop (WIN-40).
    private let barBlur: BarBlurTuner
    /// The window events that can come with a rebuilt backdrop; tokens only.
    private var windowObservers: [NSObjectProtocol] = []
    /// The Show Touches dots: a layer of this view, not of the video. The
    /// extension view mirrors its contentView (the video), so a dot there
    /// would be reflected into the Compact bar; this layer is a sibling above
    /// the mirror, so the bar shows the video only.
    private let touchDots = CALayer()
    /// The window kind's actions at the right end (the phone window's
    /// Back/Home/Recents), each group in its own glass capsule.
    private let actions = HeaderBarView(frame: .zero)
    /// The phone window's sleeping-panel cover (docs/design/phone-mirror.md):
    /// above the stream, below the chrome's controls.
    let phoneOverlay = PhoneScreenOverlayView(frame: .zero)
    /// The cover an app (or the phone) window shows until its first frame
    /// (OpeningCover): above the stream and the sleeping cover, below the chrome.
    let openingCover = OpeningCoverView(frame: .zero)
    /// The disconnection screen (StallOverlay, WIN-39): the last frame under one
    /// acrylic that reaches over the style's top band, so the bar's mirror is
    /// never the bright stream while it is up. Above the covers, below the
    /// bar's controls and the traffic lights.
    let stallOverlay = StallOverlayView(frame: .zero)
    /// Live Text (docs/design/livetext.md): its button rides the bar next to
    /// the kind's actions, and its status pill says the window is frozen while
    /// the mode is on.
    let liveTextButton = LiveTextBarButton(frame: .zero)
    private let liveTextCapsule = HeaderCapsuleView(material: HeaderBar.material(dark: false))
    private let liveTextStatus = LiveTextStatusView(frame: .zero)
    /// "Turn Off Phone Screen": the short pill that says the mirrored panel went
    /// off, or came back when the person ended it on the phone.
    private let panelStatus = LiveTextStatusView(frame: .zero)
    private(set) var style: WindowStyle
    /// Live Text is on: the kind's actions are frozen (HeaderActionPolicy).
    private(set) var liveTextActive = false

    /// The Immersive style's pill is up (the dwell or Always Visible brought it
    /// in); only `setPill` moves it.
    private(set) var showsPill = false
    /// The pill's frame in this view while it is up and can show.
    private var pillFrame: NSRect?

    /// Native full screen: the chrome owns the standard buttons' place (the
    /// full-screen bar reveals them), so this view always manages them
    /// (ChromeConfig in WindowStyle.swift).
    var lightsManagedByAppKit = false

    /// A chrome click that is the window's own (a drag or a double-click
    /// zoom); the e2e check counts them.
    var onBarPress: (() -> Void)?

    /// The cover came or went (WIN-11): the window's geometry and its
    /// full-screen bar follow it.
    var onCoverVisibilityChange: (() -> Void)?

    /// The title's tone changed: the window rewrites the chrome state so the
    /// e2e and the chrome state file see the tone that is drawn.
    var onBarToneChange: (() -> Void)?

    /// The Live Text button: a click toggles the mode; the drag source is the
    /// frozen frame (nil while the mode is off).
    var onLiveTextToggle: (() -> Void)?
    var liveTextDragProvider: (() -> URL?)?

    /// The window closed: AppKit keeps a closed window in `NSApp.windows`, and
    /// with the window this controller — so the chrome's glass, its layers and
    /// the mirrored video go now instead of living until the app quits
    /// (WIN-33). Nothing is drawn again from a released chrome.
    func releaseGraphics() {
        barBlur.windowClosing(root: ext.layer)
        ext.onSystemPass = nil
        stopToneTimer()
        ext.contentView = nil
        subviews.forEach { $0.removeFromSuperview() }
        layer?.sublayers?.forEach { $0.removeFromSuperlayer() }
        layer?.contents = nil
    }

    init(video: VideoLayerView, style: WindowStyle, barBlur: BarBlurTuner = BarBlurTuner(),
         toneSource: BarToneSource? = nil,
         reduceMotion: @escaping () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }) {
        self.video = video
        self.style = style
        self.barBlur = barBlur
        self.toneSource = toneSource ?? video
        self.reduceMotion = reduceMotion
        super.init(frame: NSRect(origin: .zero, size: style.windowSize(stream: video.frame.size)))
        wantsLayer = true
        ext.automaticallyPlacesContentView = false
        ext.contentView = video
        // The radius follows the extension view's own passes: that is where
        // the system builds its backdrop, after this view's layout.
        ext.onSystemPass = { [weak self] in self?.reapplyBarBlur() }
        video.wantsLayer = true
        actions.isHidden = true
        liveTextButton.onPress = { [weak self] in self?.onLiveTextToggle?() }
        liveTextButton.dragProvider = { [weak self] in self?.liveTextDragProvider?() }
        addSubview(ext)
        addSubview(framedView, positioned: .below, relativeTo: ext)
        framedView.isHidden = true
        // The dots ride above the stream but outside the mirror: above the
        // extension view's layer (0), below the actions (2), and
        // clipped at the seam, so a touch at the very top edge never paints
        // over the bar.
        video.touchDotHost = touchDots
        touchDots.zPosition = 1
        touchDots.masksToBounds = true
        layer?.addSublayer(touchDots)
        // The haze sits over the mirror (0) and under the dots and the controls
        // (1/2); its own frame keeps it inside the 28 pt band. The first colour
        // is at the window's top edge (layer y 1), the clear one at the seam.
        hazeLayer.startPoint = CGPoint(x: 0.5, y: 1)
        hazeLayer.endPoint = CGPoint(x: 0.5, y: 0)
        hazeLayer.zPosition = 0.55
        layer?.addSublayer(hazeLayer)
        // The tint sits over the haze but under the title and every control.
        tintLayer.zPosition = 0.56
        tintLayer.isHidden = true
        layer?.addSublayer(tintLayer)
        for field in [titleLight, titleDark] {
            BarTitle.configure(field)
            field.alphaValue = 0
            field.isHidden = true
            field.wantsLayer = true
            field.layer?.zPosition = 0.6
            addSubview(field)
        }
        titleLight.textColor = .white
        titleDark.textColor = .black
        addSubview(phoneOverlay)
        phoneOverlay.layer?.zPosition = 1.5
        addSubview(openingCover)
        openingCover.layer?.zPosition = 1.6
        // The cover's coming or going changes the geometry every control and
        // the cover itself lay out with (WIN-11): relayout at once, with no
        // animation, the same way a style switch does.
        openingCover.onVisibilityChange = { [weak self] in
            guard let self else { return }
            self.layoutChrome()
            self.placeTrafficLights()
            self.onCoverVisibilityChange?()
        }
        addSubview(stallOverlay)
        stallOverlay.layer?.zPosition = 1.7
        addSubview(fullBarView)
        fullBarView.isHidden = true
        pillView.onPress = { [weak self] in self?.onBarPress?() }
        addSubview(pillView)
        addSubview(actions)
        addSubview(liveTextCapsule)
        liveTextStatus.isHidden = true
        addSubview(liveTextButton)
        addSubview(liveTextStatus)
        panelStatus.isHidden = true
        addSubview(panelStatus)
        panelStatus.layer?.zPosition = 3
        liveTextCapsule.isHidden = true
        liveTextButton.layer?.zPosition = 2
        liveTextStatus.layer?.zPosition = 3
        fullBarView.layer?.zPosition = 2
        pillView.layer?.zPosition = 2
        liveTextCapsule.layer?.zPosition = 2
        actions.layer?.zPosition = 2
        layoutChrome()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// The Framed bar's title, for the window tests.
    var framedTitleView: FramedChromeView { framedView }

    /// The full-screen bar, for the window tests.
    var fullBarBackground: FullScreenBarView { fullBarView }

    /// The Immersive pill, for the window tests (they look inside).
    var pill: DwellPillView { pillView }

    /// The picture's own rect in this view's coordinates (the whole view in
    /// Compact; the inset content rect in Framed and while opening).
    var contentRect: NSRect { video.frame }

    /// The mirror's frame in the chrome (the e2e's geometry).
    var mirrorFrame: NSRect { ext.frame }

    /// The Show Touches dots' layer, for the tests and the chrome state.
    var touchDotsLayer: CALayer { touchDots }

    /// The dots drawn right now (the chrome state's evidence).
    var touchDotCount: Int { touchDots.sublayers?.count ?? 0 }

    /// True when the dots are outside the extension view's mirror (the bar
    /// must mirror the video only): the video draws into this layer, and this
    /// layer is the chrome's own, above the extension view.
    var touchDotsOutsideMirror: Bool {
        video.touchDotHost === touchDots && touchDots.superlayer === layer
    }

    /// The bar's actions, for the layout tests.
    var actionsForTesting: [HeaderAction] { actions.actions }

    /// The pill's own rect in the stream's coordinates, top-left origin
    /// (DwellPill's feeding geometry): the pill sits `pillInset` in from the
    /// stream's top-left corner and is as wide as its contents.
    var pillStreamRect: CGRect {
        CGRect(x: DwellChrome.pillInset, y: DwellChrome.pillInset,
               width: DwellChrome.pillWidth(actions: actions.actions), height: DwellChrome.pillHeight)
    }

    func setActions(_ actions: [HeaderAction]) {
        self.actions.setActions(actions, liveTextActive: liveTextActive)
        needsLayout = true
        layoutChrome()
    }

    var actionCount: Int { actions.actionCount }

    /// The centre of the bar button for one kind, in the window's coordinates:
    /// where a click lands. nil while the bar is hidden.
    func headerButtonCentre(_ kind: HeaderActionKind) -> NSPoint? {
        guard !actions.isHidden, let button = actions.button(for: kind), button.window != nil else { return nil }
        return button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
    }

    /// The bar's capsule material right now (the appearance test reads it).
    var barMaterial: HeaderBar.Material { actions.material }

    /// The bar's buttons the keyboard may focus, in reading order (MIRROR-13).
    var focusableBarIndices: [Int] { actions.focusableIndices }

    /// The keyboard's focus ring on one bar button (nil: back to the picture).
    func setBarFocus(_ index: Int?) { actions.setFocus(index) }

    /// The bar button at an index, for Return/Space while the bar has focus.
    func barAction(at index: Int) -> HeaderAction? { actions.action(at: index) }

    /// The controller sets this as the full-screen transition begins (AppKit
    /// adds the style mask only after it) and clears it on exit. Tests use it
    /// too: a test process must not change the person's Space.
    var fullScreenOverride: Bool?

    /// True in native full screen.
    var isFullScreen: Bool {
        fullScreenOverride ?? (window?.styleMask.contains(.fullScreen) ?? false)
    }

    /// The windowed style whose chrome shows: nil in full screen and while the
    /// opening cover owns the window as one sheet (WIN-11).
    var windowedChrome: WindowStyle? {
        guard !isFullScreen, !openingCover.isShowing else { return nil }
        return style
    }

    /// Right now: the windowed top chrome band's height — Compact's 28 pt bar
    /// or Framed's 38.5 pt bar — or 0 in full screen and while the opening
    /// cover is one sheet over the whole window (WIN-11).
    var barHeight: CGFloat {
        guard let chrome = windowedChrome else { return 0 }
        return chrome.insets(fullScreen: false).top
    }

    /// The stored style's stream rect, whether or not the chrome draws its
    /// band: the virtual display's size follows this, never the cover, so the
    /// cover coming or going cannot resize the phone's display (WIN-11).
    var streamContentRect: NSRect {
        let pad = style.insets(fullScreen: isFullScreen)
        return NSRect(x: bounds.minX + pad.left, y: bounds.minY + pad.bottom,
                      width: max(bounds.width - pad.left - pad.right, 0),
                      height: max(bounds.height - pad.top - pad.bottom, 0))
    }

    /// The Framed style's frame is drawn: windowed, cover not up.
    private var framedGeometry: Bool { windowedChrome == .framed }

    /// The Compact mirror's band is live: windowed, cover up, not Framed.
    private var compactBar: Bool { windowedChrome == .compact }

    /// The Immersive style's pill is the windowed chrome: no bar, no frame.
    private var immersiveChrome: Bool { windowedChrome == .immersive }

    /// The full-screen bar is visible (revealing, shown or hiding).
    private(set) var fullBarVisible = false

    override func layout() {
        super.layout()
        layoutChrome()
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        layoutChrome()
    }

    /// The geometry an implicit frame change animates. Only these go: a
    /// resize step must land in the same commit, and the extension view's
    /// private content layer otherwise eases its own frame for ~0.25 s.
    /// Opacity fades (the controls, the touch dots, the cover), the cover's
    /// gradient sweep and the edge hint's group are deliberate and stay.
    static let resizeAnimationKeys: Set<String> = [
        "position", "bounds", "bounds.size", "bounds.origin", "frame", "frameSize", "frameOrigin",
        // AVSampleBufferDisplayLayer's private video container scales the
        // picture into new bounds with this one (measured on a drag, 11-05).
        "sublayerTransform",
    ]

    /// Removes the frame animations (`resizeAnimationKeys`) from a layer tree.
    private func clearLayerAnimations(_ layer: CALayer?) {
        guard let layer else { return }
        for key in layer.animationKeys() ?? [] {
            let path = (layer.animation(forKey: key) as? CAPropertyAnimation)?.keyPath ?? key
            if Self.resizeAnimationKeys.contains(path) || Self.resizeAnimationKeys.contains(key) {
                layer.removeAnimation(forKey: key)
            }
        }
        for sublayer in layer.sublayers ?? [] { clearLayerAnimations(sublayer) }
    }

    /// The pill's frame in this view (the window's content): `pillInset` in
    /// from the stream's top-left corner, as tall as the Compact bar, wide
    /// enough for its contents. nil when it cannot show (a framed window with
    /// no cover, full screen, the opening cover's one sheet).
    private func newPillFrame() -> NSRect? {
        guard immersiveChrome else { return nil }
        return NSRect(x: DwellChrome.pillInset,
                      y: bounds.height - DwellChrome.pillInset - DwellChrome.pillHeight,
                      width: DwellChrome.pillWidth(actions: actions.actions), height: DwellChrome.pillHeight)
    }

    /// The stream's rect: Framed's content rect while its frame is drawn; the
    /// stored style's stream rect while the cover is one sheet; the whole view
    /// in full screen. The extension view fills the view in Compact so its
    /// bar band is the mirrored top of the stream.
    private func layoutStream() {
        let content = streamContentRect
        if framedGeometry || openingCover.isShowing {
            ext.frame = content
            video.frame = NSRect(origin: .zero, size: content.size)
            touchDots.frame = content
        } else {
            ext.frame = bounds
            video.frame = NSRect(x: 0, y: 0, width: bounds.width, height: content.height)
            touchDots.frame = video.frame
        }
        // One sheet over the whole window in either style, the style's band
        // included (WIN-11, WIN-65).
        phoneOverlay.frame = bounds
        openingCover.frame = bounds
        stallOverlay.frame = bounds
        stallOverlay.topInset = barHeight
        framedView.frame = bounds
        framedView.isHidden = !framedGeometry
        if framedGeometry {
            updateFramedTitle()
        }
    }

    func layoutChrome() {
        // Every frame here moves in the same transaction as the window's new
        // size. Without that, the layer-backed views animate to their new
        // frames for ~0.25 s: during a fast drag the picture trails the edge
        // WindowServer already shows, and the strip exposed behind it is the
        // video view's black background (WIN-58).
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layoutStream()
        CATransaction.commit()
        // No implicit frame animation may outlive the layout pass: during a
        // live resize the picture must take the new frame in the same commit,
        // or the edge the window already shows stays black for ~0.25 s.
        clearLayerAnimations(layer)
        clearLayerAnimations(ext.layer)
        clearLayerAnimations(video.layer)
        // The ext is never hidden: it is the video view's parent (its contentView
        // is the stream), and hiding NSBackgroundExtensionView blanks its
        // contentView — a stream window left without its bar then showed
        // nothing. The corners round exactly once, on this container: the
        // children stay square, so the bar's seam and the stream's top edge
        // stay straight, and the extension's mirror never copies a rounded
        // corner (a rounded video corner mirrored into the bar read as a dark
        // crescent).
        if let layer = layer {
            layer.cornerRadius = windowCornerRadius
            layer.cornerCurve = .continuous
            layer.masksToBounds = true
        }
        // The picture's own corners: Framed's 11.5 pt, not the window's 22.
        // The extension view and the video round together, or one black corner
        // would show through the other.
        let contentRadius = framedGeometry ? FramedChrome.contentRadius : 0
        for shaped in [ext.layer, video.layer].compactMap({ $0 }) {
            shaped.cornerRadius = contentRadius
            shaped.cornerCurve = .continuous
            shaped.masksToBounds = contentRadius > 0
        }
        if !framedGeometry {
            touchDots.cornerRadius = 0
            phoneOverlay.layer?.cornerRadius = 0
            phoneOverlay.layer?.masksToBounds = false
        } else {
            touchDots.cornerRadius = FramedChrome.contentRadius
            phoneOverlay.layer?.cornerRadius = FramedChrome.contentRadius
            phoneOverlay.layer?.masksToBounds = true
        }
        placeFullBar()
        if let frame = newPillFrame() {
            pillFrame = frame
            if showsPill { pillView.frame = frame }
        } else {
            pillFrame = nil
        }
        layoutControls()
        updateBarHaze()
        reapplyBarBlur()
    }

    /// The window's own radius: 22 for Framed, 16 for Compact and Immersive,
    /// square in full screen except for Immersive, which kept its 16 pt corners
    /// in full screen before the merge; the cover keeps the stored style's
    /// window radius.
    private var windowCornerRadius: CGFloat {
        if isFullScreen, style != .immersive { return 0 }
        switch style {
        case .compact, .immersive: return ChromeBar.cornerRadius
        case .framed: return FramedChrome.outerRadius
        }
    }

    /// Frames and shows the Compact bar's haze and tint from the current
    /// state: the 28 pt band above the stream and nothing below its seam.
    /// Hidden while the opening cover's ground or the stall overlay owns the
    /// bar, and in Framed or full screen (neither mirrors the picture). The
    /// title follows them.
    func updateBarHaze() {
        let bar = barHeight
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let top = NSColor(white: 1, alpha: ChromeBar.hazeTopAlpha(dark: dark)).cgColor
        let visible = compactBar && bar > 0 && !stallOverlay.isShowing
            && !phoneOverlay.isShowing
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        hazeLayer.colors = [top, NSColor(white: 1, alpha: 0).cgColor]
        hazeLayer.frame = NSRect(x: 0, y: bounds.height - bar, width: bounds.width, height: bar)
        hazeLayer.isHidden = !visible
        effectiveAppearance.performAsCurrentDrawingAppearance {
            tintLayer.backgroundColor = NSColor.windowBackgroundColor
                .withAlphaComponent(BarTitle.tintAlpha).cgColor
        }
        tintLayer.frame = hazeLayer.frame
        tintLayer.isHidden = !visible
        CATransaction.commit()
        updateBarTitle()
    }

    /// Re-applies the system blur radius after the extension view's own pass
    /// (where the system builds its backdrop) or an event that can bring a new
    /// backdrop: a layout, the first frame, an appearance, backing-scale, key
    /// or occlusion change. Observation only; nothing runs per frame. Only the
    /// Compact mirror has the filter; Framed's material has no backdrop blur
    /// of this kind.
    func reapplyBarBlur() {
        guard window != nil, compactBar else { return }
        barBlur.apply(in: ext.layer)
    }

    /// The bar's name: an app's, the phone's, or nil for a link or handoff
    /// window that does not know an app yet (WIN-68, MIRROR-26). `phone` is
    /// the active phone's display name; the bar draws "<App> (<phone>)" and
    /// drops the suffix before the app's name is truncated.
    func setBarTitle(_ text: String?, phone: String? = nil) {
        guard titleText != text || titlePhone != phone else { return }
        titleText = text
        titlePhone = phone
        updateBarTitle()
        updateFramedTitle()
        fullBarView.setTitle(BarTitleName.withPhone(text, phone: phone), base: text)
        placeFullBar()
    }

    /// The Framed bar's own label: the same name and phone suffix, in the
    /// system label colour, between the lights and our controls (WIN-71). No
    /// tone machine here.
    private func updateFramedTitle() {
        let row = HeaderBar.row(actions.actions, rightEdge: bounds.width,
                                rightInset: FramedChrome.controlsRightInset)
        framedView.setTitle(BarTitleName.withPhone(titleText, phone: titlePhone), base: titleText,
                            rightEdge: row?.actionsX ?? bounds.width)
        // A hidden view has no layout pass of its own; the chrome state and the
        // switch to Framed both read the label's place now.
        framedView.layoutSubtreeIfNeeded()
    }

    /// Lays the title out and starts or stops its sampling. Called by every
    /// layout and every cover change; the geometry is read at layout time,
    /// never stored from a proposal.
    private func updateBarTitle() {
        let row = HeaderBar.row(actions.actions, rightEdge: bounds.width)
        let fitted = compactBarTitle(row: row)
        titleFrame = fitted?.frame
        let shows = compactBar && fitted != nil
        if shows != titleVisible {
            titleVisible = shows
            if shows {
                titleLight.isHidden = false
                titleDark.isHidden = false
                if toneMachine.hasSample {
                    applyTone(toneMachine.tone, animated: false)
                } else {
                    titleLight.alphaValue = 0
                    titleDark.alphaValue = 0
                }
                startToneTimer()
                sampleBarTone(force: !toneMachine.hasSample)
            } else {
                titleLight.isHidden = true
                titleDark.isHidden = true
                stopToneTimer()
            }
        }
        guard let fitted else { return }
        BarTitle.layOut(fitted.text, in: titleLight, frame: fitted.frame)
        BarTitle.layOut(fitted.text, in: titleDark, frame: fitted.frame)
    }

    private func compactBarTitle(row: HeaderBar.Row?) -> (text: String, frame: NSRect)? {
        guard compactBar, !stallOverlay.isShowing, !phoneOverlay.isShowing else { return nil }
        return BarTitle.fitting(text: BarTitleName.withPhone(titleText, phone: titlePhone),
                                base: titleText, windowWidth: bounds.width, barHeight: barHeight,
                                boundsHeight: bounds.height, lightsEnd: BarTitle.lightsEnd,
                                rightRowStart: row?.actionsX ?? bounds.width)
    }

    /// One tone sample at most every 0.5 s, and only when a new frame has
    /// arrived since the last one: a still picture has no new tone.
    private func startToneTimer() {
        guard toneTimer == nil else { return }
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sampleBarTone(force: false) }
        }
        RunLoop.main.add(timer, forMode: .common)
        toneTimer = timer
    }

    private func stopToneTimer() {
        toneTimer?.invalidate()
        toneTimer = nil
    }

    private func sampleBarTone(force: Bool) {
        guard compactBar, titleVisible, let frame = titleFrame, !toneSampleInFlight else { return }
        if !force, let last = lastToneStamp, last == toneSource.frameStamp { return }
        let picture = video.videoRect()
        guard picture.width > 0, picture.height > 0 else { return }
        let x0 = max(frame.minX, picture.minX)
        let x1 = min(frame.maxX, picture.maxX)
        guard x1 > x0 else { return }
        let from = (x0 - picture.minX) / picture.width
        let to = (x1 - picture.minX) / picture.width
        let band = min(1, ChromeBar.height / picture.height)
        let stamp = toneSource.frameStamp
        toneSampleInFlight = true
        toneSource.topBandRange(xFrom: from, xTo: to, bandFraction: band) { [weak self] range in
            guard let self else { return }
            self.toneSampleInFlight = false
            guard let range else { return }
            self.lastToneStamp = stamp
            self.consumeToneSample(range, frame: frame)
        }
    }

    /// The band behind the title is the mirror's frame under the tint and the
    /// haze; the machine then decides the ink (WIN-69). The haze fades from
    /// the window's top edge to the seam, so the darkest end uses its alpha
    /// at the title's bottom line and the brightest end at its top.
    private func consumeToneSample(_ frame: BandRange, frame titleFrame: NSRect) {
        var tint = 0.0
        effectiveAppearance.performAsCurrentDrawingAppearance {
            tint = NSColor.windowBackgroundColor.relativeLuminance ?? tint
        }
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let topAlpha = Double(ChromeBar.hazeTopAlpha(dark: dark))
        let bandTop = bounds.height
        func haze(_ offset: CGFloat) -> Double {
            let clamped = min(max(offset, 0), ChromeBar.height)
            return topAlpha * (1 - Double(clamped / ChromeBar.height))
        }
        let band = BarToneEstimate.blend(
            frame: frame, tintLuminance: tint,
            hazeTop: haze(bandTop - titleFrame.maxY),
            hazeBottom: haze(bandTop - titleFrame.minY))
        let before = toneMachine.hasSample ? toneMachine.tone.rawValue : "none"
        let change = toneMachine.handle(.sample(band))
        switch change {
        case .ignored:
            return
        case .baseline, .changed, .unresolved:
            applyTone(toneMachine.tone, animated: true)
        }
        // An unresolved sample that kept the tone is the ignored case for the
        // view: no fade and no transition line every half second.
        guard change != .ignored, before != toneMachine.tone.rawValue else { return }
        applyTone(toneMachine.tone, animated: true)
        let line = String(format: "bar tone: %@ --sample(%.3f..%.3f)--> %@",
                          before, band.low, band.high, toneMachine.tone.rawValue)
        Log.video.notice("\(line, privacy: .public)")  // log-ok: closed tone names and luminances
        onBarToneChange?()
    }

    /// The two fields cross-fade; Reduce Motion swaps them at once.
    private func applyTone(_ tone: BarTone, animated: Bool) {
        titleLight.setAccessibilityElement(tone == .light)
        titleDark.setAccessibilityElement(tone == .dark)
        let light: CGFloat = tone == .light ? 1 : 0
        let dark: CGFloat = tone == .dark ? 1 : 0
        guard animated, !reduceMotion() else {
            titleLight.alphaValue = light
            titleDark.alphaValue = dark
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = BarTitle.fadeDuration
            titleLight.animator().alphaValue = light
            titleDark.animator().alphaValue = dark
        }
    }

    /// The e2e's view of the title: shown, its rect in this view, its ink, and
    /// the bar's tint. The text itself is never written to the state. Framed
    /// and the full-screen bar use the system label colour, so their tone
    /// reads `none` (WIN-71: no tone machine there).
    var barTitleVisible: Bool {
        if compactBar { return titleVisible }
        if framedGeometry { return !framedView.titleIsHidden }
        if fullBarVisible { return !fullBarView.titleIsHidden }
        return false
    }
    /// The ink drawn now; none until the first sample decides it (the
    /// Compact fields are transparent before that).
    var barTitleToneName: String {
        guard compactBar, titleVisible else { return "none" }
        return toneMachine.hasSample ? toneMachine.tone.rawValue : "none"
    }
    var barTitleRect: NSRect? {
        if compactBar { return titleVisible ? titleFrame : nil }
        if framedGeometry, !framedView.titleIsHidden {
            return convert(framedView.titleFrame, from: framedView)
        }
        if fullBarVisible, !fullBarView.titleIsHidden {
            return convert(fullBarView.titleFrame, from: fullBarView)
        }
        return nil
    }
    var barTintVisible: Bool { !tintLayer.isHidden }

    /// The tests' own clock tick: one forced sample, independent of the timer.
    func sampleBarToneForTesting() {
        sampleBarTone(force: true)
    }

    /// The title's truncation and its two ink alphas, for the tests.
    var barTitleLineBreakMode: NSLineBreakMode { titleLight.lineBreakMode }
    /// The text drawn now: the whole "<App> (<phone>)" or the app's name alone
    /// once the suffix had to go.
    var barTitleString: String { titleLight.stringValue }
    func barTitleAlpha(_ tone: BarTone) -> CGFloat {
        tone == .light ? titleLight.alphaValue : titleDark.alphaValue
    }

    /// The system blur's radius right now, 0 when the fallback is in force
    /// (WIN-40; the e2e reads it).
    var barBlurRadius: CGFloat { BarBlur.systemRadius(in: ext.layer) ?? 0 }

    /// True while the haze is drawn (WIN-40; the e2e reads it).
    var hazeVisible: Bool { !hazeLayer.isHidden }

    /// True when the Compact bar's mirror band would show. The opening cover
    /// is one opaque sheet over it until the first frame (WIN-11), and the
    /// phone cover is one sheet from the window's top edge (WIN-65); the stall
    /// overlay reports its own covering separately (`barMirrorCovered`).
    var barMirrorVisible: Bool { compactBar && !phoneOverlay.isShowing }

    /// The top edge and height of the row the controls ride: the windowed
    /// bar, the cover's top row while the style's chrome is one sheet, or the
    /// full-screen bar's current slide position.
    private var controlRowTop: CGFloat {
        if isFullScreen { return bounds.height - FullScreenBar.height + fullBarOffset }
        if barHeight > 0 { return bounds.height - barHeight }
        return bounds.height - ChromeBar.height
    }

    private var controlRowHeight: CGFloat {
        if isFullScreen { return FullScreenBar.height }
        return barHeight > 0 ? barHeight : ChromeBar.height
    }

    /// Where the kind's actions and Live Text ride. Positions only: show/hide
    /// is the style's, the cover's and the dwell's business.
    private func layoutControls() {
        let side = HeaderBar.liveTextSide
        // Immersive full screen is the system's own title bar (ChromeConfig):
        // no chrome of ours there.
        if isFullScreen, style == .immersive {
            hideControlRow()
            liveTextStatus.isHidden = !liveTextActive
            layoutLiveTextStatus()
            layoutPanelStatus()
            return
        }
        // Full screen in Framed or Compact: the acrylic bar's slide decides.
        if isFullScreen, !fullBarVisible {
            hideControlRow()
            liveTextStatus.isHidden = true
            layoutPanelStatus()
            return
        }
        if immersiveChrome {
            guard showsPill, let pill = pillFrame else {
                hideControlRow()
                liveTextStatus.isHidden = !liveTextActive
                layoutLiveTextStatus()
                layoutPanelStatus()
                return
            }
            actions.isHidden = actionCount == 0
            liveTextButton.isHidden = false
            liveTextCapsule.isHidden = false
            // The pill's own row: the lights, then the action capsules from
            // pillActionsX, then a gap and the Live Text capsule.
            actions.frame = NSRect(x: pill.minX + DwellChrome.pillActionsX, y: pill.minY,
                                   width: HeaderBar.rowWidth(actions.actions), height: pill.height)
            let buttonY = pill.minY + (pill.height - side) / 2
            liveTextCapsule.frame = NSRect(x: actions.frame.maxX + HeaderBar.capsuleGap, y: buttonY,
                                           width: side, height: side)
            liveTextButton.frame = liveTextCapsule.frame
            liveTextStatus.isHidden = !liveTextActive
            layoutLiveTextStatus()
            layoutPanelStatus()
            return
        }
        let rowHeight = controlRowHeight
        let top = controlRowTop
        let rightInset = framedGeometry ? FramedChrome.controlsRightInset : HeaderBar.rightInset
        guard let row = HeaderBar.row(actions.actions, rightEdge: bounds.width, rightInset: rightInset) else {
            hideControlRow()
            layoutPanelStatus()
            return
        }
        actions.isHidden = actionCount == 0
        liveTextButton.isHidden = false
        liveTextCapsule.isHidden = false
        // The capsules are centred vertically in the band; the Live Text button
        // is a square on the lights' centre line, `rightInset` in from the
        // right (the lights' left inset).
        actions.frame = NSRect(x: row.actionsX, y: top, width: row.actionsWidth, height: rowHeight)
        let buttonY = top + (rowHeight - side) / 2
        liveTextCapsule.frame = NSRect(x: row.liveTextX, y: buttonY, width: side, height: side)
        liveTextButton.frame = liveTextCapsule.frame
        liveTextStatus.isHidden = !liveTextActive
        layoutLiveTextStatus()
        layoutPanelStatus()
    }

    private func hideControlRow() {
        actions.isHidden = true
        liveTextButton.isHidden = true
        liveTextCapsule.isHidden = true
    }

    /// The status pill: centred in the chrome row, or just under the window's
    /// top edge where there is no bar or frame (Immersive, Immersive full screen,
    /// the opening cover's top row).
    private func layoutLiveTextStatus() {
        guard !liveTextStatus.isHidden else { return }
        let size = liveTextStatus.preferredSize
        if immersiveChrome || (isFullScreen && style == .immersive) {
            liveTextStatus.frame = NSRect(x: bounds.midX - size.width / 2,
                                          y: bounds.height - size.height - 10,
                                          width: size.width, height: size.height)
            return
        }
        let top = isFullScreen || barHeight > 0 || openingCover.isShowing ? controlRowTop : bounds.height
        liveTextStatus.frame = NSRect(x: bounds.midX - size.width / 2,
                                      y: top + (controlRowHeight - size.height) / 2,
                                      width: size.width, height: size.height)
    }

    /// The mode came or went: the status pill, the button's accent, the drag
    /// source and the frozen controls follow it.
    /// What freezes the phone-side kinds: Live Text or a cover over the mirror.
    func setFrozen(_ frozen: Bool) {
        actions.setFrozen(frozen)
    }

    /// The link is down: the phone-side kinds dim with the offline reason.
    func setOffline(_ offline: Bool) {
        actions.setOffline(offline)
    }

    /// The kinds the bar has live (the chrome state reports them).
    var enabledHeaderKinds: [String] { actions.enabledKinds }

    func setLiveText(active: Bool) {
        liveTextActive = active
        liveTextButton.isOn = active
        actions.setActions(actions.actions, liveTextActive: active)
        liveTextStatus.setText("Live Text")
        liveTextStatus.isHidden = !active || (isFullScreen && style != .immersive && !fullBarVisible)
        if active { layoutLiveTextStatus() }
        needsLayout = true
    }

    /// True while the status pill is up (the chrome state file reports it).
    var showsLiveTextStatus: Bool { !liveTextStatus.isHidden }

    /// The phone window's mirrored panel is held off (`panel_off` in the state).
    private(set) var panelOff = false

    /// The phone window's panel-off state: the bar glyph and the chrome state.
    func setPanelOff(_ off: Bool) {
        panelOff = off
        needsLayout = true
    }

    /// The panel pill's text, also while hidden: the chrome state reports whether
    /// the last one said the request failed.
    private(set) var panelPillText: String?

    /// The "Phone screen off" / "Phone screen on" pill; nil takes it away.
    /// It shares the Live Text pill's line and steps left while that one is up.
    func setPanelPill(_ text: String?) {
        panelPillText = text
        if let text {
            panelStatus.setText(text)
            panelStatus.isHidden = false
        } else {
            panelStatus.isHidden = true
        }
        needsLayout = true
        layoutPanelStatus()
    }

    /// True while the phone's panel-off pill is up (the chrome state reports it).
    var showsPanelStatus: Bool { !panelStatus.isHidden }

    /// The overlay covers the bar's mirror (WIN-39): it spans the bar's band and
    /// sits above the extension view, so the bar shows the same cover as the
    /// body instead of the bright stream. The phone cover does the same for
    /// the sleeping panel and a secure surface (WIN-65). False once it is down.
    var barMirrorCovered: Bool {
        guard barHeight > 0 else { return false }
        let band = NSRect(x: 0, y: video.frame.maxY, width: bounds.width,
                          height: bounds.height - video.frame.maxY)
        let cover: NSView? = stallOverlay.isShowing ? stallOverlay
            : (phoneOverlay.isShowing ? phoneOverlay : nil)
        guard let cover else { return false }
        return cover.frame.contains(band)
            && (cover.layer?.zPosition ?? 0) > (ext.layer?.zPosition ?? 0)
    }

    private func layoutPanelStatus() {
        guard !panelStatus.isHidden else { return }
        let size = panelStatus.preferredSize
        let y: CGFloat
        if immersiveChrome || (isFullScreen && style == .immersive) {
            y = bounds.height - size.height - 10
        } else {
            y = controlRowTop + (controlRowHeight - size.height) / 2
        }
        // Live Text may already hold the centre: step left instead of stacking
        // two pills on each other.
        let shift = showsLiveTextStatus ? liveTextStatus.frame.width / 2 + size.width / 2 + 8 : 0
        panelStatus.frame = NSRect(x: bounds.midX - size.width / 2 - shift, y: y,
                                   width: size.width, height: size.height)
    }

    override var isOpaque: Bool { false }

    /// The capsule material follows the window's appearance (light or dark).
    /// A chrome built into a window that is already dark never hears a change,
    /// so the material is also taken when it lands in its window; without that
    /// the bar stayed light in a Dark window (a capture showed it).
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyMaterial()
        // The alphas follow the appearance, and macOS may rebuild the backdrop
        // it applies to.
        updateBarHaze()
        reapplyBarBlur()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        reapplyBarBlur()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyMaterial()
        updateBarHaze()
        reapplyBarBlur()
        observeWindow()
        if window == nil { stopToneTimer() }
    }

    deinit {
        windowObservers.forEach(NotificationCenter.default.removeObserver)
        toneTimer?.invalidate()
    }

    /// Re-apply the radius when the window becomes or stops being key and when
    /// its occlusion changes: those are the events after which the hosting
    /// view has been seen to rebuild its backdrop.
    private func observeWindow() {
        windowObservers.forEach(NotificationCenter.default.removeObserver)
        windowObservers = []
        guard let window else { return }
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                     NSWindow.didChangeOcclusionStateNotification] {
            windowObservers.append(NotificationCenter.default.addObserver(
                forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.reapplyBarBlur() }
                })
        }
    }

    private func applyMaterial() {
        let material = HeaderBar.material(for: effectiveAppearance)
        actions.material = material
        liveTextCapsule.material = material
    }

    /// The bottom edge of the band that belongs to the window: the Compact bar
    /// plus whatever the native titlebar covers. The titlebar is taller than
    /// the bar on macOS 26 (32 against 28), and its last rows still show the
    /// stream's top edge at the window's edge. A click there is the bar's, not
    /// the picture's (ISS-49); without this the click under the titlebar
    /// reaches VideoLayerView and becomes a touch. No window (tests build the
    /// chrome alone): the bar alone.
    private var inertBandBottom: CGFloat {
        let barBottom = bounds.height - barHeight
        guard let window else { return barBottom }
        let contentTop = convert(window.contentLayoutRect, from: nil).maxY
        return min(barBottom, contentTop)
    }

    /// True at a point in this view that the chrome owns over the picture:
    /// Compact's bar and the native titlebar rows above the stream's first
    /// visible row, Framed's margins and rounded-off corners, Immersive's pill
    /// while it is up, and the full-screen bar's band WHILE it is revealed.
    /// Clicks and hover share this one rule (ISS-49, WIN-61): a point the
    /// chrome owns is never the phone's.
    func ownsPoint(_ point: NSPoint) -> Bool {
        if isFullScreen {
            return style != .immersive && fullBarVisible && point.y >= bounds.height - FullScreenBar.height
        }
        if framedGeometry {
            return !FramedChrome.contentContains(point, in: bounds)
        }
        if barHeight > 0 {
            return point.y >= inertBandBottom
        }
        guard immersiveChrome, showsPill, let pillFrame else { return false }
        return pillFrame.contains(point)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        let local = convert(point, from: superview)
        // The chrome's own controls always keep their clicks: the kind's
        // actions, the Live Text capsule and its button, and the pill.
        if let hit {
            if hit === actions || hit.isDescendant(of: actions) { return hit }
            if hit === liveTextCapsule || hit.isDescendant(of: liveTextCapsule) { return hit }
            if hit === liveTextButton || hit.isDescendant(of: liveTextButton) { return hit }
            if hit === pillView || hit.isDescendant(of: pillView) { return hit }
        }
        guard ownsPoint(local) else { return hit }
        guard hit != nil else { return nil }
        // The bar's mirrored band is the window's own: a click on it is a drag
        // (and counts). The band decides, not which view the mirror's content
        // ends up in: the extension view stretches the video over the window,
        // so the picture can answer for the bar's points (ISS-49). Framed's
        // margins and rounded-off corners are the same. The disconnection
        // overlay's band drags here too; its body below the band takes the
        // click (WIN-39).
        return self
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        if barHeight > 0 || framedGeometry || (isFullScreen && fullBarVisible)
            || (immersiveChrome && showsPill) {
            onBarPress?()
            if event.clickCount == 2 {
                window.performZoom(nil)
                return
            }
        }
        window.performDrag(with: event)
    }

    /// The Immersive dwell pill came or went (the controller folds time in):
    /// fade it and its buttons in over `fadeIn`, move the controls and the
    /// lights to its slots, and on the way out park everything hidden again.
    /// The real lights live in the title area above this view, so only their
    /// frames change.
    func setPill(_ shown: Bool) {
        guard !shown || immersiveChrome else { return }
        guard showsPill != shown else { return }
        showsPill = shown
        let controlViews: [NSView] = [pillView, actions]
        let lights = trafficLights
        if shown {
            controlViews.forEach { $0.alphaValue = 0 }
            pillView.isHidden = false
            actions.isHidden = actionCount == 0
            lights.forEach { $0.alphaValue = 0; $0.isHidden = false }
            layoutControls()
            pillFrame = newPillFrame()
            if let frame = pillFrame { pillView.frame = frame }
            placeTrafficLights()
            window?.invalidateShadow()
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = DwellChrome.fadeIn
                controlViews.forEach { $0.animator().alphaValue = 1 }
                lights.forEach { $0.animator().alphaValue = 1 }
            }, completionHandler: {
                self.placeTrafficLights()
            })
            // Unhiding a title-area button makes AppKit assert its standard
            // slot on the next titlebar layout pass; this comes after it.
            DispatchQueue.main.async { [weak self] in  // gcd: after AppKit's titlebar pass on this turn
                if let self, self.showsPill { self.placeTrafficLights() }
            }
        } else {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = DwellChrome.fadeIn
                controlViews.forEach { $0.animator().alphaValue = 0 }
                lights.forEach { $0.animator().alphaValue = 0 }
            }, completionHandler: {
                // Still hidden: park everything for the next dwell. The buttons
                // keep alpha 1 hidden so ⌘W/⌘M still "click" them.
                if !self.showsPill {
                    self.pillView.isHidden = true
                    self.actions.isHidden = true
                    self.actions.alphaValue = 1
                    self.lightsHide()
                    self.window?.invalidateShadow()
                }
            })
        }
    }

    private func lightsHide() {
        // Only park when no chrome owns the lights: the bar does too, and
        // Immersive full screen gives them to AppKit.
        guard immersiveChrome, !lightsManagedByAppKit else { return }
        trafficLights.forEach {
            if !showsPill {
                $0.isHidden = true
                $0.alphaValue = 1
            }
        }
    }

    /// The full-screen bar's offset from the top edge, in points: 0 shown,
    /// `FullScreenBar.height` hidden off the top.
    private func setFullBarOffset(_ offset: CGFloat) {
        fullBarOffset = offset
        fullBarVisible = offset < FullScreenBar.height
        fullBarView.isHidden = !fullBarVisible
        actions.alphaValue = 1
        placeFullBar()
        layoutControls()
        placeTrafficLights()
        window?.invalidateShadow()
    }

    /// Frames the acrylic bar and its title at the current slide offset.
    private func placeFullBar() {
        guard isFullScreen else {
            fullBarView.isHidden = true
            return
        }
        let row = HeaderBar.row(actions.actions, rightEdge: bounds.width)
        let height = FullScreenBar.height
        fullBarView.frame = NSRect(x: 0, y: bounds.height - height + fullBarOffset,
                                   width: bounds.width, height: height)
        fullBarView.layoutTitle(rightRowStart: row?.actionsX ?? bounds.width)
    }

    /// Parks the bar just above the window's top edge, still drawn: the start
    /// of the slide in and the end of the slide out.
    private func parkFullBarAboveTheTop() {
        fullBarOffset = FullScreenBar.height
        fullBarVisible = true
        fullBarView.isHidden = false
        placeFullBar()
        layoutControls()
        placeTrafficLights()
    }

    /// Slides the full-screen bar in from above the top edge. The completion
    /// runs once the frames have landed, for the machine's animationFinished.
    func revealFullBar(animated: Bool, completion: @escaping () -> Void) {
        guard isFullScreen else { completion(); return }
        fullBarView.isHidden = false
        fullBarVisible = true
        actions.isHidden = false
        liveTextButton.isHidden = false
        liveTextCapsule.isHidden = false
        layoutControls()
        placeTrafficLights()
        guard animated, !reduceMotion() else {
            setFullBarOffset(0)
            completion()
            return
        }
        parkFullBarAboveTheTop()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = FullScreenBar.revealDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            fullBarView.animator().frame = NSRect(x: 0, y: bounds.height - FullScreenBar.height,
                                                  width: bounds.width, height: FullScreenBar.height)
            for view in [actions, liveTextCapsule, liveTextButton] {
                view.animator().frame = view.frame.offsetBy(dx: 0, dy: -FullScreenBar.height)
            }
            self.moveFullScreenLights(toOffset: 0, animated: true)
        } completionHandler: { [weak self] in
            guard let self else { return }
            self.setFullBarOffset(0)
            completion()
        }
    }

    /// Slides the full-screen bar away above the top edge, then parks it.
    func hideFullBar(animated: Bool, completion: @escaping () -> Void) {
        guard isFullScreen else { completion(); return }
        guard animated, !reduceMotion() else {
            setFullBarOffset(FullScreenBar.height)
            completion()
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = FullScreenBar.hideDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            fullBarView.animator().frame = NSRect(x: 0, y: bounds.height,
                                                  width: bounds.width, height: FullScreenBar.height)
            for view in [actions, liveTextCapsule, liveTextButton] {
                view.animator().frame = view.frame.offsetBy(dx: 0, dy: FullScreenBar.height)
            }
            self.moveFullScreenLights(toOffset: FullScreenBar.height, animated: true)
        } completionHandler: { [weak self] in
            guard let self else { return }
            self.setFullBarOffset(FullScreenBar.height)
            completion()
        }
    }

    /// Applies a full-screen bar state with no animation (entry, exit).
    func setFullBarShown(_ shown: Bool) {
        setFullBarOffset(shown ? 0 : FullScreenBar.height)
    }

    /// Moves the window's own traffic lights with the full-screen bar: 7 pt in
    /// from the left and the window's top edge, on the bar's line.
    private func moveFullScreenLights(toOffset offset: CGFloat, animated: Bool) {
        guard let window, !lightsManagedByAppKit else { return }
        let height = window.frame.height
        for (i, type) in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].enumerated() {
            guard let light = window.standardWindowButton(type), let superview = light.superview else { continue }
            let frame = NSRect(x: ChromeBar.trafficLightInset + CGFloat(i) * ChromeBar.trafficLightSpacing,
                               y: height - FullScreenBar.height + offset
                                   + (FullScreenBar.height - ChromeBar.trafficLightButtonSide) / 2,
                               width: ChromeBar.trafficLightButtonSide, height: ChromeBar.trafficLightButtonSide)
            let target = superview.convert(frame, from: nil)
            if animated {
                light.animator().frame = target
            } else {
                light.frame = target
            }
        }
    }

    /// Where the traffic lights ride: the windowed bar's line (Compact's
    /// 7 pt insets or Framed's 12.25), the full-screen bar's line while that
    /// bar is off the top, or out of sight. The lights live in the title area
    /// above the full-size content, so they are placed there in window
    /// coordinates and converted.
    func placeTrafficLights() {
        guard let window, !lightsManagedByAppKit else { return }
        let height = window.frame.height
        for (i, type) in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].enumerated() {
            guard let light = window.standardWindowButton(type) else { continue }
            guard let superview = light.superview else { continue }
            if isFullScreen {
                light.isHidden = !fullBarVisible
                light.alphaValue = 1
                let frame = NSRect(x: ChromeBar.trafficLightInset + CGFloat(i) * ChromeBar.trafficLightSpacing,
                                   y: height - FullScreenBar.height + fullBarOffset
                                       + (FullScreenBar.height - ChromeBar.trafficLightButtonSide) / 2,
                                   width: ChromeBar.trafficLightButtonSide, height: ChromeBar.trafficLightButtonSide)
                light.frame = superview.convert(frame, from: nil)
            } else if barHeight > 0 {
                light.isHidden = false
                light.alphaValue = 1
                let inset = framedGeometry ? FramedChrome.lightInset : ChromeBar.trafficLightInset
                let frame = NSRect(x: inset + CGFloat(i) * ChromeBar.trafficLightSpacing,
                                   y: height - inset - ChromeBar.trafficLightButtonSide,
                                   width: ChromeBar.trafficLightButtonSide, height: ChromeBar.trafficLightButtonSide)
                light.frame = superview.convert(frame, from: nil)
            } else if immersiveChrome {
                // The pill's row: 8 pt in from its edge, 14x14 centred on the
                // pill's centre line; out of sight while the chrome is hidden.
                light.isHidden = !showsPill
                light.alphaValue = 1
                let x = DwellChrome.pillLightInset + CGFloat(i) * DwellChrome.pillLightSpacing
                let frame = NSRect(x: x,
                                   y: height - DwellChrome.pillInset - DwellChrome.pillHeight / 2
                                       - ChromeBar.trafficLightButtonSide / 2,
                                   width: ChromeBar.trafficLightButtonSide, height: ChromeBar.trafficLightButtonSide)
                light.frame = superview.convert(frame, from: nil)
            } else {
                // The opening cover's one sheet: the lights ride its top row.
                light.isHidden = false
                light.alphaValue = 1
                let frame = NSRect(x: ChromeBar.trafficLightInset + CGFloat(i) * ChromeBar.trafficLightSpacing,
                                   y: height - ChromeBar.trafficLightInset - ChromeBar.trafficLightButtonSide,
                                   width: ChromeBar.trafficLightButtonSide, height: ChromeBar.trafficLightButtonSide)
                light.frame = superview.convert(frame, from: nil)
            }
        }
    }

    private var trafficLights: [NSButton] {
        [.closeButton, .miniaturizeButton, .zoomButton].compactMap { window?.standardWindowButton($0) }
    }

    /// The style itself changed (⌥⌘F / View menu): relayout, re-place the
    /// lights; the Immersive pill never survives a switch.
    func setStyle(_ new: WindowStyle) {
        guard style != new else { return }
        if showsPill { setPill(false) }
        pillView.isHidden = true
        pillView.alphaValue = 0
        actions.isHidden = true
        style = new
        layoutChrome()
        placeTrafficLights()
    }
}
