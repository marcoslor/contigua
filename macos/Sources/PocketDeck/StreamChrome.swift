// The stream window's chrome by style (WindowStyle.swift). Framed: a permanent
// 28 pt bar above the stream. The mirror is NSBackgroundExtensionView: the
// video view is its contentView and it fills the rest of its frame — here the
// bar band — with a replica of the content's top edge, so nothing is read back
// off the CPU and nothing is decoded twice. The replica carries the system's
// progressive blur (strongest at the window's top edge, sharp at the seam)
// turned up to 30 pt (BarBlur.swift), a 14 % window-background tint and a light
// white haze over the bar band only, clear at its seam; the stream's colours
// still show through, so the bar reads as colour, not content. The centred
// title is the app's name (or the phone's in the Mirror) in the tone the band
// behind it allows (BarTitle.swift). The traffic lights ride the bar's line as
// standard controls. Immersive: no chrome at rest; the window is exactly the
// stream, and the traffic lights live on a dwell pill that fades in at the
// stream's top-left corner when the pointer rests there (DwellChrome, DwellPill
// in WindowStyle.swift). Full screen has no bar in either style.

import AppKit
import SwiftUI

/// The immersive dwell pill (DwellChrome): clear glass at the stream's top-left
/// corner — it blurs what is under it without the regular glass's grey fill —
/// and its empty areas drag the window; the window kind's actions and the real
/// traffic lights (which ride the window's title area above this view) sit on
/// top.
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
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func mouseDown(with event: NSEvent) {
        onPress?()
        window?.performDrag(with: event)
    }
}

/// The window's content for both styles: the stream, and above it (framed)
/// the bar — the extension view's blurred mirror, with the traffic lights
/// riding it and the window kind's actions at the right end. In immersive
/// those actions ride the dwell pill instead, and the whole chrome is out of
/// sight until the pointer dwells.
final class StreamChromeView: NSView {
    let video: VideoLayerView
    /// The bar's mirror: the extension view spans the whole window, so the
    /// band beyond the video's top edge is its filled replica — blurred
    /// progressively by the system, with no material over it.
    private let ext = NSBackgroundExtensionView()
    /// The immersive dwell pill; only a background: the buttons above it are
    /// the chrome's own subviews so they can move between bar and pill frames.
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
    /// What the bar names; nil hides the title (WIN-68).
    private(set) var titleText: String?
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
    /// would be reflected into the framed bar; this layer is a sibling above
    /// the mirror, so the bar shows the video only.
    private let touchDots = CALayer()
    /// The window kind's actions at the right end (the phone window's
    /// Back/Home/Recents), each group in its own glass capsule; hidden in the
    /// bar and shown in the pill alike.
    private let actions = HeaderBarView(frame: .zero)
    /// The phone window's sleeping-panel cover (docs/design/phone-mirror.md):
    /// above the stream, below the pill and the kind's actions.
    let phoneOverlay = PhoneScreenOverlayView(frame: .zero)
    /// The cover an app (or the phone) window shows until its first frame
    /// (OpeningCover): above the stream and the sleeping cover, below the chrome.
    let openingCover = OpeningCoverView(frame: .zero)
    /// The disconnection screen (StallOverlay, WIN-39): the last frame under one
    /// acrylic that reaches over the framed bar, so the bar's mirror is never
    /// the bright stream while it is up. Above the covers, below the bar's
    /// controls and the traffic lights.
    let stallOverlay = StallOverlayView(frame: .zero)
    /// Live Text (docs/design/livetext.md): its button rides the bar next to
    /// the kind's actions (or inside the pill), and its status pill says the
    /// window is frozen while the mode is on.
    let liveTextButton = LiveTextBarButton(frame: .zero)
    private let liveTextCapsule = HeaderCapsuleView(material: HeaderBar.material(dark: false))
    private let liveTextStatus = LiveTextStatusView(frame: .zero)
    /// "Turn Off Phone Screen": the short pill that says the mirrored panel went
    /// off, or came back when the person ended it on the phone.
    private let panelStatus = LiveTextStatusView(frame: .zero)
    private(set) var style: WindowStyle
    /// Live Text is on: the kind's actions are frozen (HeaderActionPolicy).
    private(set) var liveTextActive = false

    /// The pill's fade state; only `setPill` moves it.
    private(set) var showsPill = false
    /// Native full screen: AppKit owns the standard buttons' place (the title
    /// bar macOS reveals), so this chrome must not hide or move them
    /// (ChromeConfig in WindowStyle.swift).
    var lightsManagedByAppKit = false
    /// The pill's frame in the toolbar area while it is up.
    private var pillFrame: NSRect?

    /// A bar or pill click that is the window's own (a drag or a double-click
    /// zoom); the e2e check counts them.
    var onBarPress: (() -> Void)?

    /// The cover changed the chrome's effective style (WIN-11): the window's
    /// dwell configuration follows it, alongside the layout below.
    var onEffectiveStyleChange: (() -> Void)?

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
        video.wantsLayer = true
        actions.isHidden = true
        pillView.onPress = { [weak self] in self?.onBarPress?() }
        liveTextButton.onPress = { [weak self] in self?.onLiveTextToggle?() }
        liveTextButton.dragProvider = { [weak self] in self?.liveTextDragProvider?() }
        addSubview(ext)
        // The dots ride above the stream but outside the mirror: above the
        // extension view's layer (0), below the pill and the actions (2), and
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
            field.font = BarTitle.font()
            field.alignment = .center
            field.lineBreakMode = .byTruncatingMiddle
            field.usesSingleLineMode = true
            field.maximumNumberOfLines = 1
            field.isBezeled = false
            field.drawsBackground = false
            field.isEditable = false
            field.isSelectable = false
            field.alphaValue = 0
            field.isHidden = true
            field.wantsLayer = true
            field.layer?.zPosition = 0.6
            addSubview(field)
        }
        titleLight.textColor = .white
        titleDark.textColor = .black
        titleLight.setAccessibilityElement(false)
        titleDark.setAccessibilityElement(false)
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
            self.onEffectiveStyleChange?()
        }
        addSubview(stallOverlay)
        stallOverlay.layer?.zPosition = 1.7
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

    /// The pill, for the window tests (they look inside).
    var pill: DwellPillView { pillView }

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

    /// The dwell pill's own rect in the stream's coordinates, top-left origin
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
    /// where a click lands. nil while the bar and the dwell pill are hidden.
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

    /// Right now: the framed bar above the stream for the chrome, or 0 in
    /// immersive, in full screen, and while the opening cover wears the
    /// immersive geometry (WIN-11).
    var barHeight: CGFloat {
        guard effectiveStyle == .framed, !(window?.styleMask.contains(.fullScreen) ?? false) else { return 0 }
        return ChromeBar.height
    }

    /// The bar inset the stored style gives the stream, whether or not the
    /// chrome draws it now: the video's rect follows this, not the cover's
    /// immersive layout, so the virtual display's size never moves with the
    /// cover and the bar's backdrop stays alive under it (WIN-11, WIN-40).
    private var streamBarHeight: CGFloat {
        guard style == .framed, !(window?.styleMask.contains(.fullScreen) ?? false) else { return 0 }
        return ChromeBar.height
    }

    /// The style the chrome lays out with right now: while the opening cover is
    /// up a framed window wears the immersive geometry, so the cover is one
    /// sheet over the whole window and no empty bar shows behind it (WIN-11).
    /// The stored style is untouched; the first frame brings the bar back at
    /// once, under the cover's 200 ms fade-out.
    var effectiveStyle: WindowStyle {
        style == .framed && openingCover.isShowing ? .immersive : style
    }

    override func layout() {
        super.layout()
        layoutChrome()
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        layoutChrome()
    }

    /// The pill's frame in this view (the window's content): `pillInset` in
    /// from the stream's top-left corner, as tall as the framed bar, wide
    /// enough for its contents. nil when it cannot show (a framed window with
    /// no cover, full screen).
    private func newPillFrame() -> NSRect? {
        guard effectiveStyle == .immersive, !(window?.styleMask.contains(.fullScreen) ?? false) else { return nil }
        return NSRect(x: DwellChrome.pillInset, y: bounds.height - DwellChrome.pillInset - DwellChrome.pillHeight,
                      width: DwellChrome.pillWidth(actions: actions.actions), height: DwellChrome.pillHeight)
    }

    /// The geometry an implicit frame change animates. Only these go: a
    /// resize step must land in the same commit, and the extension view's
    /// private content layer otherwise eases its own frame for ~0.25 s.
    /// Opacity fades (the dwell controls, the touch dots, the cover), the
    /// cover's gradient sweep and the edge hint's group are deliberate and stay.
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

    func layoutChrome() {
        // Every frame here moves in the same transaction as the window's new
        // size. Without that, the layer-backed views animate to their new
        // frames for ~0.25 s: during a fast drag the picture trails the edge
        // WindowServer already shows, and the strip exposed behind it is the
        // video view's black background (WIN-58).
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ext.frame = bounds
        let bar = barHeight
        video.frame = NSRect(x: 0, y: 0, width: bounds.width,
                             height: max(bounds.height - streamBarHeight, 0))
        // The dots sit exactly over the stream, in its own coordinates, but on
        // this view's layer: no animation while the bar comes and goes.
        touchDots.frame = video.frame
        // The phone cover is one sheet over the whole window (WIN-65): the
        // held picture runs under the titlebar and the bar band, so no band of
        // another colour sits on top while the screen sleeps or is secure.
        phoneOverlay.frame = bounds
        // The cover is one sheet over the whole window in either style, the
        // bar's band included (WIN-11).
        openingCover.frame = bounds
        // The overlay is one sheet from the window's top edge: it covers the
        // bar too, and its words stay centred in the body below it.
        stallOverlay.frame = bounds
        stallOverlay.topInset = bar
        CATransaction.commit()
        // No implicit frame animation may outlive the layout pass: during a
        // live resize the picture must take the new frame in the same commit,
        // or the edge the window already shows stays black for ~0.25 s.
        clearLayerAnimations(layer)
        clearLayerAnimations(ext.layer)
        clearLayerAnimations(video.layer)
        // The ext is never hidden: it is the video view's parent (its contentView
        // is the stream), and hiding NSBackgroundExtensionView blanks its
        // contentView — a stream window left immersive then showed nothing. With
        // the bar gone the ext's frame is the stream's own: nothing to fill.
        // The corners round exactly once, on this container: the children stay
        // square, so the bar's seam and the stream's top edge stay straight,
        // and the extension's mirror never copies a rounded corner (a rounded
        // video corner mirrored into the bar read as a dark crescent).
        if let layer = layer {
            layer.cornerRadius = ChromeBar.cornerRadius
            layer.cornerCurve = .continuous
            layer.masksToBounds = true
        }
        layoutControls()
        if newPillFrame() != nil {
            pillFrame = newPillFrame()
            if showsPill { pillView.frame = pillFrame.map { $0 } ?? .zero }
        }
        updateBarHaze()
        reapplyBarBlur()
    }

    /// Frames and shows the bar's haze and tint from the current state: the
    /// 28 pt band above the stream and nothing below its seam. Hidden while
    /// the opening cover's ground or the stall overlay owns the bar, and in
    /// immersive or full screen (both have no bar). The title follows them.
    func updateBarHaze() {
        let bar = barHeight
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let top = NSColor(white: 1, alpha: ChromeBar.hazeTopAlpha(dark: dark)).cgColor
        let visible = bar > 0 && !openingCover.isShowing && !stallOverlay.isShowing
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

    /// Re-applies the system blur radius after an event that can bring a new
    /// backdrop: a layout, the first frame, an appearance, backing-scale, key
    /// or occlusion change. Observation only; nothing runs per frame.
    func reapplyBarBlur(reportMissing: Bool = false) {
        guard window != nil else { return }
        barBlur.apply(in: ext.layer, reportMissing: reportMissing)
    }

    /// The bar's name: an app's, the phone's, or nil for a link or handoff
    /// window that does not know an app yet (WIN-68, MIRROR-23).
    func setBarTitle(_ text: String?) {
        guard titleText != text else { return }
        titleText = text
        updateBarTitle()
    }

    /// Lays the title out and starts or stops its sampling. Called by every
    /// layout and every cover change; the geometry is read at layout time,
    /// never stored from a proposal.
    private func updateBarTitle() {
        let row = HeaderBar.row(actions.actions, rightEdge: bounds.width)
        let frame = barTitleFrame(row: row)
        titleFrame = frame
        let shows = frame != nil
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
        guard let frame else { return }
        let text = titleText ?? ""
        if titleLight.stringValue != text {
            titleLight.stringValue = text
            titleDark.stringValue = text
        }
        let mode = BarTitle.lineBreakMode(text: text, width: frame.width)
        titleLight.lineBreakMode = mode
        titleDark.lineBreakMode = mode
        titleLight.frame = frame
        titleDark.frame = frame
    }

    private func barTitleFrame(row: HeaderBar.Row?) -> NSRect? {
        guard !openingCover.isShowing, !stallOverlay.isShowing, !phoneOverlay.isShowing else { return nil }
        return BarTitle.frame(text: titleText, windowWidth: bounds.width, barHeight: barHeight,
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
        guard titleVisible, let frame = titleFrame, !toneSampleInFlight else { return }
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
        let line = String(format: "bar tone: %@ --sample(%.3f..%.3f)--> %@",
                          before, band.low, band.high, toneMachine.tone.rawValue)
        Log.video.notice("\(line, privacy: .public)")  // log-ok: closed tone names and luminances
        if case .unresolved = change, !loggedUnresolvedTone {
            loggedUnresolvedTone = true
            let kept = toneMachine.tone.rawValue
            Log.video.notice("bar tone: neither ink reaches the contrast limit; keeping \(kept, privacy: .public)")  // log-ok: a closed tone name
        }
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

    /// The e2e's view of the title: shown, its rect in this view, its tone,
    /// and the bar's tint. The text itself is never written to the state.
    var barTitleVisible: Bool { titleVisible }
    var barTitleToneName: String { toneMachine.tone.rawValue }
    var barTitleRect: NSRect? { titleVisible ? titleFrame : nil }
    var barTintVisible: Bool { !tintLayer.isHidden }

    /// The tests' own clock tick: one forced sample, independent of the timer.
    func sampleBarToneForTesting() {
        sampleBarTone(force: true)
    }

    /// The title's truncation and its two ink alphas, for the tests.
    var barTitleLineBreakMode: NSLineBreakMode { titleLight.lineBreakMode }
    func barTitleAlpha(_ tone: BarTone) -> CGFloat {
        tone == .light ? titleLight.alphaValue : titleDark.alphaValue
    }

    /// The system blur's radius right now, 0 when the fallback is in force
    /// (WIN-40; the e2e reads it).
    var barBlurRadius: CGFloat { BarBlur.systemRadius(in: ext.layer) ?? 0 }

    /// True while the haze is drawn (WIN-40; the e2e reads it).
    var hazeVisible: Bool { !hazeLayer.isHidden }

    /// True when the framed bar's mirror band would show. The opening cover is
    /// one opaque sheet over it until the first frame (WIN-11), and the phone
    /// cover is one sheet from the window's top edge (WIN-65); the stall
    /// overlay reports its own covering separately (`barMirrorCovered`).
    var barMirrorVisible: Bool { barHeight > 0 && !openingCover.isShowing && !phoneOverlay.isShowing }

    /// The kind's actions over the framed bar or, while the pill shows, inside
    /// it. Positions only: show/hide is the style's and the dwell's business
    /// (setStyle, setPill).
    private func layoutControls() {
        let barVisible = barHeight > 0
        let side = HeaderBar.liveTextSide
        if barVisible {
            actions.isHidden = actionCount == 0
            liveTextButton.isHidden = false
            liveTextCapsule.isHidden = false
            if let row = HeaderBar.row(actions.actions, rightEdge: bounds.width) {
                let y = bounds.height - barHeight
                // The capsules are centred vertically in the bar band; the
                // Live Text button is a square on the lights' centre line,
                // `rightInset` in from the right (the lights' left inset).
                actions.frame = NSRect(x: row.actionsX, y: y, width: row.actionsWidth, height: barHeight)
                let buttonY = y + (barHeight - side) / 2
                liveTextCapsule.frame = NSRect(x: row.liveTextX, y: buttonY, width: side, height: side)
                liveTextButton.frame = liveTextCapsule.frame
            }
            layoutLiveTextStatus(bar: true)
        } else if showsPill, let pill = pillFrame {
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
            layoutLiveTextStatus(bar: false)
        } else {
            // Full screen has no bar or pill: the View menu is the way in.
            liveTextButton.isHidden = true
            liveTextCapsule.isHidden = true
            layoutLiveTextStatus(bar: false)
        }
        layoutPanelStatus(bar: barVisible)
    }

    /// The status pill: centred in the framed bar, or just under the stream's
    /// top edge where there is no bar (immersive, full screen).
    private func layoutLiveTextStatus(bar: Bool) {
        guard !liveTextStatus.isHidden else { return }
        let size = liveTextStatus.preferredSize
        liveTextStatus.frame = bar
            ? NSRect(x: bounds.midX - size.width / 2, y: bounds.height - barHeight + (barHeight - size.height) / 2,
                     width: size.width, height: size.height)
            : NSRect(x: bounds.midX - size.width / 2, y: bounds.height - size.height - 10,
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
        if active { layoutLiveTextStatus(bar: barHeight > 0) }
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
        layoutPanelStatus(bar: barHeight > 0)
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

    private func layoutPanelStatus(bar: Bool) {
        guard !panelStatus.isHidden else { return }
        let size = panelStatus.preferredSize
        let y = bar
            ? bounds.height - barHeight + (barHeight - size.height) / 2
            : bounds.height - size.height - 10
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
    /// the bar stayed light in a Dark window (the capture in
    /// `.agent/conv-fixes-1/` showed it).
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

    /// The bottom edge of the band that belongs to the window: the framed bar
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

    /// True at a point in this view that the chrome owns over the picture: the
    /// framed band (the 28 pt bar and the titlebar rows above the stream's
    /// first visible row) and the immersive pill while it is up. Clicks and
    /// hover share this one rule (ISS-49, WIN-61): a point the chrome owns is
    /// never the phone's.
    func ownsPoint(_ point: NSPoint) -> Bool {
        if barHeight > 0 { return point.y >= inertBandBottom }
        guard effectiveStyle == .immersive, showsPill, let pillFrame else { return false }
        return pillFrame.contains(point)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        guard ownsPoint(convert(point, from: superview)) else { return hit }
        guard let hit else { return nil }
        // The bar's mirrored band is the window's own: a click on it is a drag
        // (and counts). The band decides, not which view the mirror's content
        // ends up in: the extension view stretches the video over the window,
        // so the picture can answer for the bar's points (ISS-49). The bar's
        // own controls keep their clicks — the kind's actions, the Live Text
        // capsule and its button, and the pill (harmless in framed). The
        // disconnection overlay's band drags here too; its body below the band
        // takes the click (WIN-39).
        if hit === actions || hit.isDescendant(of: actions) { return hit }
        if hit === liveTextCapsule || hit.isDescendant(of: liveTextCapsule) { return hit }
        if hit === liveTextButton || hit.isDescendant(of: liveTextButton) { return hit }
        if hit === pillView || hit.isDescendant(of: pillView) { return hit }
        return self
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        if barHeight > 0 {
            onBarPress?()
            if event.clickCount == 2 {
                window.performZoom(nil)
                return
            }
        }
        window.performDrag(with: event)
    }

    /// The dwell pill came or went (the controller folds time in): fade it and
    /// its buttons in over `fadeIn`, move the controls and the lights to its
    /// slots, and on the way out park everything hidden again. The real lights
    /// live in the title area above this view, so only their frames change.
    func setPill(_ shown: Bool) {
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
            DispatchQueue.main.async { [weak self] in
                if let self, self.showsPill { self.placeTrafficLights() }
            }
        } else {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = DwellChrome.fadeIn
                controlViews.forEach { $0.animator().alphaValue = 0 }
                // Full screen's bar keeps the system's lights up.
                if !self.lightsManagedByAppKit { lights.forEach { $0.animator().alphaValue = 0 } }
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
        // Only park when no chrome owns the lights: the bar does too, and in
        // full screen AppKit does.
        guard barHeight == 0, !lightsManagedByAppKit else { return }
        trafficLights.forEach {
            if !showsPill {
                $0.isHidden = true
                $0.alphaValue = 1
            }
        }
    }

    /// Where the traffic lights ride: the framed bar's line while that bar
    /// shows, the pill's lights row while the dwell pill shows, out of sight
    /// otherwise. The lights live in the title area above the full-size
    /// content, so they are placed there in window coordinates and converted.
    func placeTrafficLights() {
        // Full screen: the system's bar, the system's buttons (ChromeConfig).
        guard let window, !lightsManagedByAppKit else { return }
        let height = window.frame.height
        for (i, type) in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].enumerated() {
            guard let light = window.standardWindowButton(type) else { continue }
            guard let superview = light.superview else { continue }
            if barHeight > 0 {
                light.isHidden = false
                light.alphaValue = 1
                // x 20/43/66, y from the window's bottom edge (titlebar views do
                // not overlap the full-size content), measured by the demo.
                let frame = NSRect(x: ChromeBar.trafficLightInset + CGFloat(i) * ChromeBar.trafficLightSpacing,
                                   y: height - ChromeBar.trafficLightInset - ChromeBar.trafficLightButtonSide,
                                   width: ChromeBar.trafficLightButtonSide, height: ChromeBar.trafficLightButtonSide)
                light.frame = superview.convert(frame, from: nil)
            } else if showsPill {
                light.isHidden = false
                // The pill's row: 8 pt in from its edge, 14x14 centred on the
                // pill's centre line.
                let x = DwellChrome.pillLightInset + CGFloat(i) * DwellChrome.pillLightSpacing
                let frame = NSRect(x: x, y: height - DwellChrome.pillInset - DwellChrome.pillHeight / 2 - ChromeBar.trafficLightButtonSide / 2,
                                   width: ChromeBar.trafficLightButtonSide, height: ChromeBar.trafficLightButtonSide)
                light.frame = superview.convert(frame, from: nil)
            } else {
                light.isHidden = true
                light.alphaValue = 1
            }
        }
    }

    private var trafficLights: [NSButton] {
        [.closeButton, .miniaturizeButton, .zoomButton].compactMap { window?.standardWindowButton($0) }
    }

    /// The style itself changed (⌥⌘F / View menu): relayout, re-place the
    /// lights; the pill never survives a switch.
    func setStyle(_ new: WindowStyle) {
        guard style != new else { return }
        style = new
        if showsPill { setPill(false) }
        pillView.isHidden = true
        pillView.alphaValue = 0
        actions.isHidden = true
        layoutChrome()
        placeTrafficLights()
    }
}
