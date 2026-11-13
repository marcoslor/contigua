// The stream window's chrome by style (WindowStyle.swift). Compact: none of
// ours. The window is a standard titled one, so AppKit draws its opaque title
// bar above this view, with the system's title and lights; the window kind's
// actions and Live Text ride its trailing NSTitlebarAccessoryViewController
// (WIN-7). This view is exactly the stream. Framed: the picture sits inside a real frame on all four
// sides (FramedChrome): a system material, a 0.5 pt hairline, a 1 pt rim, a
// 10 pt top highlight, a 21 pt window radius and a 12 pt picture radius, with
// our lights, a label-coloured title and our controls in the 38 pt bar.
// Immersive: the old pill style — no bar, no borders, the picture fills the
// window, and the lights and our controls live on a clear-glass pill that the
// dwell brings in (DwellChrome, DwellPill). Full screen looks the same in
// every style: the stream fills the screen and the window's own native title
// bar, which the system brings down with the menu bar, is the only chrome
// (ChromeConfig, WIN-14); none of ours is drawn.

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
        // copy of the picture: Framed's bar is a real material bar.
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
        // Always lay out: the frame is hidden in the other styles, so a title
        // set then has no laid-out label yet; the switch to Framed places it.
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
    /// an 8 pt clearance and the hide thresholds of WIN-68, and the phone
    /// suffix dropped first when the room is short.
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

final class StreamChromeView: NSView {
    let video: VideoLayerView
    /// The Framed style's material, hairline, rim, highlight and title.
    private let framedView = FramedChromeView()
    /// The Immersive style's clear-glass pill; only a background: the buttons above it are the chrome's own
    /// subviews so they can move between the pill's row and their home slots.
    private let pillView = DwellPillView()
    /// What the bar names; nil hides the title (WIN-68). `titleText` is the
    /// name without the phone suffix; `titlePhone` is the phone's display name
    /// the suffix is built from.
    private(set) var titleText: String?
    private var titlePhone: String?
    /// The Show Touches dots: a layer of this view above the stream, clipped
    /// to the picture.
    private let touchDots = CALayer()
    /// Compact's controls: the window kind's actions and Live Text ride
    /// AppKit's own trailing title-bar accessory, in the native title bar
    /// (WIN-7). Hidden in every other style and in full screen.
    let titlebarControls = NSTitlebarAccessoryViewController()
    private let titlebarRow = NSView()
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
    /// The pill is on screen: from the start of its fade-in to the end of its
    /// fade-out. Its pieces (the glass, the capsules, Live Text, the lights)
    /// show and hide on this one flag and fade on one opacity, so no layout
    /// pass during a fade can hide or show one of them on its own (WIN-74).
    private(set) var pillOnScreen = false
    /// The pill's frame in this view while it is up and can show.
    private var pillFrame: NSRect?

    /// True with the system's title bar (full screen): AppKit places the
    /// standard buttons; windowed, this view does (ChromeConfig in
    /// WindowStyle.swift).
    var lightsManagedByAppKit = false

    /// A chrome click that is the window's own (a drag or a double-click
    /// zoom); the e2e check counts them.
    var onBarPress: (() -> Void)?

    /// The cover came or went (WIN-11): the window's geometry follows it.
    var onCoverVisibilityChange: (() -> Void)?

    /// The Live Text button: a click toggles the mode; the drag source is the
    /// frozen frame (nil while the mode is off).
    var onLiveTextToggle: (() -> Void)?
    var liveTextDragProvider: (() -> URL?)?

    /// The window closed: AppKit keeps a closed window in `NSApp.windows`, and
    /// with the window this controller — so the chrome's glass, its layers and
    /// the mirrored video go now instead of living until the app quits
    /// (WIN-33). Nothing is drawn again from a released chrome.
    func releaseGraphics() {
        released = true
        if let window, let index = window.titlebarAccessoryViewControllers.firstIndex(of: titlebarControls) {
            window.removeTitlebarAccessoryViewController(at: index)
        }
        titlebarRow.subviews.forEach { $0.removeFromSuperview() }
        subviews.forEach { $0.removeFromSuperview() }
        layer?.sublayers?.forEach { $0.removeFromSuperlayer() }
        layer?.contents = nil
    }
    /// Set once by `releaseGraphics`: no later layout puts a control back.
    private var released = false

    init(video: VideoLayerView, style: WindowStyle) {
        self.video = video
        self.style = style
        super.init(frame: NSRect(origin: .zero, size: style.contentSize(stream: video.frame.size)))
        wantsLayer = true
        video.wantsLayer = true
        actions.isHidden = true
        liveTextButton.onPress = { [weak self] in self?.onLiveTextToggle?() }
        liveTextButton.dragProvider = { [weak self] in self?.liveTextDragProvider?() }
        addSubview(framedView)
        framedView.isHidden = true
        addSubview(video)
        // The dots ride above the stream, below the controls (2), clipped to
        // the picture.
        video.touchDotHost = touchDots
        touchDots.zPosition = 1
        touchDots.masksToBounds = true
        layer?.addSublayer(touchDots)
        titlebarControls.layoutAttribute = .trailing
        titlebarControls.view = titlebarRow
        titlebarControls.isHidden = true
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
        pillView.layer?.zPosition = 2
        liveTextCapsule.layer?.zPosition = 2
        actions.layer?.zPosition = 2
        layoutChrome()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// The Framed bar's title, for the window tests.
    var framedTitleView: FramedChromeView { framedView }

    /// The Immersive pill, for the window tests (they look inside).
    var pill: DwellPillView { pillView }

    /// The picture's own rect in this view's coordinates (the whole view in
    /// Compact, Immersive and full screen; the inset rect in Framed).
    var contentRect: NSRect { video.frame }

    /// The Show Touches dots' layer, for the tests and the chrome state.
    var touchDotsLayer: CALayer { touchDots }

    /// The dots drawn right now (the chrome state's evidence).
    var touchDotCount: Int { touchDots.sublayers?.count ?? 0 }

    /// The bar's actions, for the layout tests.
    var actionsForTesting: [HeaderAction] { actions.actions }
    /// The action row's and the Live Text capsule's frames, for the layout
    /// tests (nil for a row with no actions).
    var actionsFrameForTesting: NSRect? { actions.actions.isEmpty ? nil : actions.frame }
    var liveTextFrameForTesting: NSRect { liveTextCapsule.frame }

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

    /// Right now: the height of our own top chrome band — Framed's 38 pt bar —
    /// or 0 in the other styles (Compact's title bar is AppKit's, outside this
    /// view), in full screen and while the opening cover is one sheet (WIN-11).
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

    /// The Immersive style's pill is the windowed chrome: no bar, no frame.
    private var immersiveChrome: Bool { windowedChrome == .immersive }

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
    /// from the stream's top-left corner, the 28 pt row's height, wide
    /// enough for its contents. nil when it cannot show (a framed window with
    /// no cover, full screen, the opening cover's one sheet).
    private func newPillFrame() -> NSRect? {
        guard immersiveChrome else { return nil }
        return NSRect(x: DwellChrome.pillInset,
                      y: bounds.height - DwellChrome.pillInset - DwellChrome.pillHeight,
                      width: DwellChrome.pillWidth(actions: actions.actions), height: DwellChrome.pillHeight)
    }

    /// The stream's rect: Framed's content rect inside its frame; the whole
    /// view in Compact (its title bar is AppKit's, above this view), in
    /// Immersive and in full screen.
    private func layoutStream() {
        video.frame = streamContentRect
        touchDots.frame = video.frame
        // One sheet over the whole content view in every style, Framed's band
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
        clearLayerAnimations(video.layer)
        // The window's corners round once, on this container.
        if let layer = layer {
            layer.cornerRadius = windowCornerRadius
            layer.cornerCurve = .continuous
            layer.masksToBounds = true
        }
        // The picture's own corners: Framed's 12 pt, not the window's 21.
        let contentRadius = framedGeometry ? FramedChrome.contentRadius : 0
        if let shaped = video.layer {
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
        if let frame = newPillFrame() {
            pillFrame = frame
            if pillOnScreen { pillView.frame = frame }
        } else {
            pillFrame = nil
        }
        layoutControls()
    }

    /// The window's own radius where our chrome draws the window's edge: 21
    /// for Framed, 16 for Immersive. Compact's window is AppKit's titled
    /// window, whose shape and corners are the system's; full screen is
    /// square. The cover keeps the stored style's radius.
    private var windowCornerRadius: CGFloat {
        if isFullScreen { return 0 }
        switch style {
        case .compact: return 0
        case .immersive: return ChromeBar.cornerRadius
        case .framed: return FramedChrome.outerRadius
        }
    }

    /// The bar's name: an app's, the phone's, or nil for a link or handoff
    /// window that does not know an app yet (WIN-68, MIRROR-26). `phone` is
    /// the active phone's display name; the bar draws "<App> (<phone>)" and
    /// drops the suffix before the app's name is truncated.
    func setBarTitle(_ text: String?, phone: String? = nil) {
        guard titleText != text || titlePhone != phone else { return }
        titleText = text
        titlePhone = phone
        updateFramedTitle()
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

    /// The e2e's view of our title — Framed's frame is the only chrome of
    /// ours that draws one; Compact and full screen show the window's own
    /// title in AppKit's title bar. The text itself is never written to the
    /// state.
    var barTitleVisible: Bool {
        framedGeometry && !framedView.titleIsHidden
    }
    var barTitleRect: NSRect? {
        if framedGeometry, !framedView.titleIsHidden {
            return convert(framedView.titleFrame, from: framedView)
        }
        return nil
    }

    /// The top edge and height of the row the controls ride: the windowed
    /// bar, or the cover's top row while the style's chrome is one sheet.
    private var controlRowTop: CGFloat {
        if barHeight > 0 { return bounds.height - barHeight }
        return bounds.height - ChromeBar.height
    }

    private var controlRowHeight: CGFloat {
        return barHeight > 0 ? barHeight : ChromeBar.height
    }

    /// Compact windowed: the controls ride AppKit's title bar (the trailing
    /// accessory), the cover up or not.
    private var titlebarHosted: Bool { style == .compact && !isFullScreen }

    /// The native title bar's height, from AppKit: the window's frame above
    /// its content.
    private var titlebarHeight: CGFloat {
        guard let window else { return ChromeBar.height }
        return max(window.frame.height - window.contentLayoutRect.height, ChromeBar.height)
    }

    /// The controls' views move between this view and the title-bar row.
    private func hostControls(in host: NSView) {
        for view in [actions, liveTextCapsule, liveTextButton] where view.superview !== host {
            host.addSubview(view)
        }
    }

    /// Where the kind's actions and Live Text ride. Positions only: show/hide
    /// is the style's, the cover's and the dwell's business.
    private func layoutControls() {
        guard !released else { return }
        let side = HeaderBar.liveTextSide
        if let window, !window.titlebarAccessoryViewControllers.contains(titlebarControls) {
            window.addTitlebarAccessoryViewController(titlebarControls)
        }
        titlebarControls.isHidden = !titlebarHosted
        if titlebarHosted {
            // Compact: the native title bar carries the row, `rightInset` in
            // from its right end and centred on its line.
            hostControls(in: titlebarRow)
            let height = titlebarHeight
            let width = (HeaderBar.row(actions.actions, rightEdge: 0)?.width ?? 0) + HeaderBar.rightInset
            titlebarRow.frame = NSRect(x: 0, y: 0, width: width, height: height)
            if let row = HeaderBar.row(actions.actions, rightEdge: width) {
                actions.isHidden = actionCount == 0
                liveTextButton.isHidden = false
                liveTextCapsule.isHidden = false
                actions.frame = NSRect(x: row.actionsX, y: (height - ChromeBar.height) / 2,
                                       width: row.actionsWidth, height: ChromeBar.height)
                liveTextCapsule.frame = NSRect(x: row.liveTextX, y: (height - side) / 2, width: side, height: side)
                liveTextButton.frame = liveTextCapsule.frame
            }
            liveTextStatus.isHidden = !liveTextActive
            layoutLiveTextStatus()
            layoutPanelStatus()
            return
        }
        hostControls(in: self)
        // Full screen is the system's own title bar (ChromeConfig): no chrome
        // of ours there; View ▸ Live Text and the Navigate menu still reach
        // every control.
        if isFullScreen {
            hideControlRow()
            liveTextStatus.isHidden = !liveTextActive
            layoutLiveTextStatus()
            layoutPanelStatus()
            return
        }
        if immersiveChrome {
            guard pillOnScreen, let pill = pillFrame else {
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
            liveTextCapsule.frame = NSRect(x: pill.minX + DwellChrome.pillLiveTextX(actions: actions.actions),
                                           y: buttonY,
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
    /// top edge where there is no bar or frame (Immersive, full screen, the
    /// opening cover's top row).
    private func layoutLiveTextStatus() {
        guard !liveTextStatus.isHidden else { return }
        let size = liveTextStatus.preferredSize
        if immersiveChrome || isFullScreen || titlebarHosted {
            liveTextStatus.frame = NSRect(x: bounds.midX - size.width / 2,
                                          y: bounds.height - size.height - 10,
                                          width: size.width, height: size.height)
            return
        }
        let top = barHeight > 0 || openingCover.isShowing ? controlRowTop : bounds.height
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
        liveTextStatus.isHidden = !active
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

    private func layoutPanelStatus() {
        guard !panelStatus.isHidden else { return }
        let size = panelStatus.preferredSize
        let y: CGFloat
        if immersiveChrome || isFullScreen || titlebarHosted {
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
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyMaterial()
        layoutControls()
    }

    private func applyMaterial() {
        let material = HeaderBar.material(for: effectiveAppearance)
        actions.material = material
        liveTextCapsule.material = material
    }

    /// True at a point in this view that the chrome owns over the picture:
    /// Framed's margins and rounded-off corners, and Immersive's pill while it
    /// is up. Compact's title bar and full screen's are AppKit's, outside this
    /// view. Clicks and hover share this one rule (ISS-49,
    /// WIN-61): a point the chrome owns is never the phone's.
    func ownsPoint(_ point: NSPoint) -> Bool {
        if isFullScreen { return false }
        if framedGeometry {
            return !FramedChrome.contentContains(point, in: bounds)
        }
        guard immersiveChrome, pillOnScreen, let pillFrame else { return false }
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
        // Framed's margins and rounded-off corners are the window's own: a
        // click there is a drag (and counts), never the picture's (ISS-49).
        // The disconnection overlay's band drags here too; its body below the
        // band takes the click (WIN-39).
        return self
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        if framedGeometry || (immersiveChrome && pillOnScreen) {
            onBarPress?()
            if event.clickCount == 2 {
                window.performZoom(nil)
                return
            }
        }
        window.performDrag(with: event)
    }

    /// The Immersive dwell pill came or went (the controller folds time in).
    /// The pill is one unit: its glass, its capsules, the Live Text button and
    /// the three lights show together and fade together, in or out, on one
    /// opacity over `DwellChrome.pillFade`. The real lights live in the title
    /// area above this view, so only their frames change.
    func setPill(_ shown: Bool) {
        guard !shown || immersiveChrome else { return }
        guard showsPill != shown else { return }
        showsPill = shown
        if shown {
            pillOnScreen = true
            pillFrame = newPillFrame()
            if let frame = pillFrame { pillView.frame = frame }
            let members = pillMembers
            members.forEach { $0.alphaValue = 0 }
            pillView.isHidden = false
            layoutControls()
            placeTrafficLights()
            window?.invalidateShadow()
            fadePill(members, to: 1) {
                self.placeTrafficLights()
            }
            // Unhiding a title-area button makes AppKit assert its standard
            // slot on the next titlebar layout pass; this comes after it.
            DispatchQueue.main.async { [weak self] in  // gcd: after AppKit's titlebar pass on this turn
                if let self, self.pillOnScreen { self.placeTrafficLights() }
            }
        } else {
            fadePill(pillMembers, to: 0) {
                // Shown again meanwhile: the fade-in owns the pieces now.
                if !self.showsPill { self.parkPill() }
            }
        }
    }

    /// Every piece of the pill that is on screen with it.
    private var pillMembers: [NSView] {
        var members: [NSView] = [pillView, liveTextCapsule, liveTextButton]
        if !actions.isHidden || actionCount > 0 { members.append(actions) }
        if immersiveChrome, !lightsManagedByAppKit { members += trafficLights }
        return members
    }

    /// Reduce Motion, read when the pill comes or goes (tests set it).
    var reduceMotion: () -> Bool = {
        Motion.reduce(system: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    }

    /// One fade for the whole pill: every piece in the same animation group;
    /// none under Reduce Motion.
    /// A view that has been hidden since it was made has no layer yet, and an
    /// alpha change on it is not animated (the glass and the lights popped in
    /// on the first reveal): each piece is layer-backed before the fade.
    private func fadePill(_ members: [NSView], to alpha: CGFloat, completion: @escaping () -> Void) {
        guard !reduceMotion() else {
            // Reduce Motion: the whole pill comes or goes at once, still as one.
            members.forEach { $0.alphaValue = alpha }
            completion()
            return
        }
        for view in members where view.layer == nil { view.wantsLayer = true }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = DwellChrome.pillFade
            context.allowsImplicitAnimation = true
            members.forEach { $0.animator().alphaValue = alpha }
        }, completionHandler: completion)
    }

    /// The pill is gone: everything parked hidden for the next dwell. The
    /// buttons keep alpha 1 hidden so ⌘W/⌘M still "click" them.
    private func parkPill() {
        pillOnScreen = false
        pillView.isHidden = true
        pillView.alphaValue = 0
        hideControlRow()
        actions.alphaValue = 1
        liveTextCapsule.alphaValue = 1
        liveTextButton.alphaValue = 1
        lightsHide()
        window?.invalidateShadow()
    }

    private func lightsHide() {
        // Only park when no chrome owns the lights: the bar does too, and
        // Immersive full screen gives them to AppKit.
        guard immersiveChrome, !lightsManagedByAppKit else { return }
        trafficLights.forEach {
            if !pillOnScreen {
                $0.isHidden = true
                $0.alphaValue = 1
            }
        }
    }

    /// Where the traffic lights ride: Framed's bar line (12.25 pt insets), the
    /// Immersive pill's row, or out of sight. The lights live in the title
    /// area above the full-size content, so they are placed there in window
    /// coordinates and converted. With the system's title bar (Compact, full
    /// screen) they are AppKit's: shown, and laid out where AppKit puts them.
    func placeTrafficLights() {
        guard let window else { return }
        if lightsManagedByAppKit {
            for light in trafficLights {
                light.isHidden = false
                light.alphaValue = 1
            }
            trafficLights.first?.superview?.needsLayout = true
            return
        }
        let height = window.frame.height
        for (i, type) in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].enumerated() {
            guard let light = window.standardWindowButton(type) else { continue }
            guard let superview = light.superview else { continue }
            if barHeight > 0 {
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
                // Its opacity is the pill's (setPill), never set here.
                light.isHidden = !pillOnScreen
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
        showsPill = false
        parkPill()
        style = new
        layoutChrome()
        placeTrafficLights()
    }
}
