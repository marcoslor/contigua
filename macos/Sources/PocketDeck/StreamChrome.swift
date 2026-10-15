// The stream window's chrome by style (WindowStyle.swift). Framed: a permanent
// 28 pt bar above the stream. The mirror is NSBackgroundExtensionView: the
// video view is its contentView and it fills the rest of its frame — here the
// bar band — with a replica of the content's top edge, so nothing is read back
// off the CPU and nothing is decoded twice. Over the bar sits the window
// material (within-window blend: it blurs the mirror, not the desktop) whose
// maskImage carries the brief's alpha gradient (mirror alpha stable at the
// seam, fading toward the window's top edge), so the bar melts into the app at
// the seam and into the material at its top. Immersive: no
// chrome at rest; the window is exactly the stream, and the traffic lights live
// on a dwell pill that fades in at the stream's top-left corner when the
// pointer rests there (DwellChrome, DwellPill in WindowStyle.swift). Full
// screen has no bar in either style.
//
// The mask is the mirrored strip's alpha made concrete: NSVisualEffectView
// takes one opacity per row through NSImage.maskImage, and the material shows
// `1 - mirror` at that row (0.15 at the seam, 0.75 at the top edge).

import AppKit
import SwiftUI

/// The bar material's own per-row alpha for a bar `height` tall under `mirror`:
/// row 0 is the image's top (the window's top edge), where the mirror is
/// `alphaTop`, and the last row is the seam, where it is `alphaSeam`.
func barMaskImage(mirror: BarMirror, height: CGFloat) -> NSImage {
    let rows = max(Int(height * 4), 1)
    let width = 4
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: rows,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: width * 4, bitsPerPixel: 32)!
    if let data = rep.bitmapData {
        for row in 0..<rows {
            // The mirror's alpha `distance` pt above the seam; the image's top
            // row is the bar's farthest row from the seam.
            let distance = height * (1 - CGFloat(row) / CGFloat(rows))
            let mirror = mirror.alpha(aboveSeam: distance, bar: height)
            for col in 0..<width {
                let pixel = data + row * width * 4 + col * 4
                pixel[0] = 0
                pixel[1] = 0
                pixel[2] = 0
                pixel[3] = UInt8(((1 - mirror) * 255).rounded())
            }
        }
    }
    let image = NSImage(size: NSSize(width: CGFloat(width), height: height))
    image.addRepresentation(rep)
    // A plain stretchable gradient: the whole 4 pt wide image stretches over
    // the material's bounds (no caps, so no rounded corners of its own).
    image.capInsets = NSEdgeInsets()
    image.resizingMode = .stretch
    return image
}

/// The style-toggle button (⌥⌘F, View ▸ Window Style): one icon right of the
/// zoom light in the framed bar, in the pill in immersive.
struct ToggleIcon: View {
    var perform: () -> Void = {}

    var body: some View {
        Button(action: perform) {
            Image(systemName: ChromeBar.toggleSymbol)
                .font(.system(size: ChromeBar.toggleFontSize, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .focusable(false)
        .help("Toggle Window Style")
        .accessibilityLabel("Toggle Window Style")
        .frame(width: ChromeBar.toggleSize, height: ChromeBar.toggleSize)
    }
}

/// The immersive dwell pill (DwellChrome): a blur-material pill at the stream's
/// top-left corner; its empty areas drag the window; the toggle, the window
/// kind's actions and the real traffic lights (which ride the window's title
/// area above this view) sit on top.
final class DwellPillView: NSGlassEffectView {
    /// A click that reached the pill (the e2e check counts them).
    var onPress: (() -> Void)?

    init() {
        super.init(frame: NSRect(origin: .zero, size: CGSize(width: DwellChrome.pillWidth(actionCount: 0),
                                                             height: DwellChrome.pillHeight)))
        cornerRadius = DwellChrome.pillCornerRadius
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
/// the bar — the extension view's mirror under the masked window material,
/// with the traffic lights riding it and the toggle + window kind's actions
/// beside them. In immersive the same toggle and actions ride the dwell pill
/// instead, and the whole chrome is out of sight until the pointer dwells.
final class StreamChromeView: NSView {
    let video: VideoLayerView
    /// The bar's mirror: the extension view spans the whole window, so the
    /// band beyond the video's top edge is its filled replica.
    private let ext = NSBackgroundExtensionView()
    /// The bar material, masked by `barMaskImage` so the mirror shows through
    /// at the seam and the window material takes the top.
    private let bar = NSVisualEffectView()
    /// The immersive dwell pill; only a background: the buttons above it are
    /// the chrome's own subviews so they can move between bar and pill frames.
    private let pillView = DwellPillView()
    /// The style toggle (⌥⌘F) in both styles.
    private let toggle = NSHostingView(rootView: ToggleIcon())
    /// The window kind's actions at the right end (the phone window's
    /// Back/Home/Recents); hidden in the bar and shown in the pill alike.
    private let actions = NSHostingView(rootView: HeaderControls(actions: []))
    private(set) var style: WindowStyle
    var mirror: BarMirror = .standard { didSet { refreshBarMask() } }

    /// The pill's fade state; only `setPill` moves it.
    private(set) var showsPill = false
    /// The pill's frame in the toolbar area while it is up.
    private var pillFrame: NSRect?

    /// A bar or pill click that is the window's own (a drag or a double-click
    /// zoom); the e2e check counts them.
    var onBarPress: (() -> Void)?
    /// The style toggle's tap (⌥⌘F's same action).
    var onToggleStyle: (() -> Void)? {
        didSet { toggle.rootView.perform = { [onToggleStyle] in onToggleStyle?() } }
    }

    init(video: VideoLayerView, style: WindowStyle) {
        self.video = video
        self.style = style
        super.init(frame: NSRect(origin: .zero, size: style.windowSize(stream: video.frame.size)))
        wantsLayer = true
        ext.automaticallyPlacesContentView = false
        ext.contentView = video
        video.wantsLayer = true
        // A plain material (not .titlebar: that one draws the window-chrome
        // art with rounded translucent edges) within-window: it blurs the
        // window's own content under it (the mirrored stream fill), not what
        // is behind the window. Over a busy desktop the behind-window blend
        // read as transparent glass along the bar's borders and corners; the
        // mirror must own the bar.
        bar.material = .menu
        bar.blendingMode = .withinWindow
        bar.state = .active
        toggle.sizingOptions = []
        actions.sizingOptions = []
        // The bar and the pill are window overlays; their safe areas would push
        // the buttons down.
        toggle.safeAreaRegions = []
        actions.safeAreaRegions = []
        actions.isHidden = true
        toggle.isHidden = true
        pillView.onPress = { [weak self] in self?.onBarPress?() }
        addSubview(ext)
        addSubview(bar)
        addSubview(pillView)
        addSubview(toggle)
        addSubview(actions)
        refreshBarMask()
        layoutChrome()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// The pill, for the window tests (they look inside).
    var pill: DwellPillView { pillView }

    /// The dwell pill's own rect in the stream's coordinates, top-left origin
    /// (DwellPill's feeding geometry): the pill sits `pillInset` in from the
    /// stream's top-left corner and is as wide as its contents.
    var pillStreamRect: CGRect {
        CGRect(x: DwellChrome.pillInset, y: DwellChrome.pillInset,
               width: DwellChrome.pillWidth(actionCount: actionCount), height: DwellChrome.pillHeight)
    }

    func setActions(_ actions: [HeaderAction]) {
        self.actions.rootView = HeaderControls(actions: actions)
        needsLayout = true
    }

    var actionCount: Int { actions.rootView.actions.count }

    /// The toggle's parked state, for the window tests (it returns from a pill
    /// round-trip to the bar).
    var toggleHidden: Bool { toggle.isHidden }

    /// Right now: the framed bar above the stream, or nothing in immersive and
    /// in full screen.
    var barHeight: CGFloat {
        guard style == .framed, !(window?.styleMask.contains(.fullScreen) ?? false) else { return 0 }
        return ChromeBar.height
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
    /// enough for its contents. nil when it cannot show (framed, full screen).
    private func newPillFrame() -> NSRect? {
        guard style == .immersive, !(window?.styleMask.contains(.fullScreen) ?? false) else { return nil }
        return NSRect(x: DwellChrome.pillInset, y: bounds.height - DwellChrome.pillInset - DwellChrome.pillHeight,
                      width: DwellChrome.pillWidth(actionCount: actionCount), height: DwellChrome.pillHeight)
    }

    func layoutChrome() {
        ext.frame = bounds
        let bar = barHeight
        video.frame = NSRect(x: 0, y: 0, width: bounds.width, height: max(bounds.height - bar, 0))
        self.bar.frame = NSRect(x: 0, y: bounds.height - bar, width: bounds.width, height: bar)
        self.bar.isHidden = bar == 0
        ext.isHidden = bar == 0
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
    }

    /// The style toggle and the kind's actions over the framed bar or, while
    /// the pill shows, inside it. Positions only: show/hide is the style's and
    /// the dwell's business (setStyle, setPill).
    private func layoutControls() {
        let barVisible = barHeight > 0
        if barVisible {
            toggle.isHidden = false
            actions.isHidden = actionCount == 0
            if actionCount > 0 {
                let width = CGFloat(actionCount) * HeaderControls.buttonWidth
                actions.frame = NSRect(x: bounds.width - width - 12, y: bounds.height - barHeight,
                                       width: width, height: barHeight)
            }
            // 8 pt right of the zoom light (20/43/66 set in placeTrafficLights).
            toggle.frame = ChromeBar.toggleFrame(zoom: CGRect(x: 20 + 2 * 23, y: bounds.height - 21,
                                                              width: 14, height: 14))
        } else if showsPill, let pill = pillFrame {
            actions.isHidden = actionCount == 0
            if actionCount > 0 {
                let width = CGFloat(actionCount) * HeaderControls.buttonWidth
                actions.frame = NSRect(x: pill.minX + DwellChrome.pillActionsX, y: pill.minY,
                                       width: width, height: pill.height)
            }
            toggle.frame = NSRect(x: pill.minX + DwellChrome.pillToggleX, y: pill.minY + 6,
                                  width: ChromeBar.toggleSize, height: ChromeBar.toggleSize)
        }
    }

    private func refreshBarMask() {
        guard barHeight > 0 else { return }
        bar.maskImage = barMaskImage(mirror: mirror, height: ChromeBar.height)
    }

    override var isOpaque: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard barHeight > 0, let hit = super.hitTest(point) else { return super.hitTest(point) }
        // The bar's two layers are the window's own: a click on the bar is a
        // drag (and counts), while the toggle and the kind's actions keep
        // their clicks.
        return hit === bar || hit === ext ? self : hit
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
        let controlViews: [NSView] = [pillView, toggle, actions]
        let lights = trafficLights
        if shown {
            controlViews.forEach { $0.alphaValue = 0 }
            pillView.isHidden = false
            toggle.isHidden = false
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
                lights.forEach { $0.animator().alphaValue = 0 }
            }, completionHandler: {
                // Still hidden: park everything for the next dwell. The buttons
                // keep alpha 1 hidden so ⌘W/⌘M still "click" them.
                if !self.showsPill {
                    self.pillView.isHidden = true
                    self.toggle.isHidden = true
                    self.actions.isHidden = true
                    self.toggle.alphaValue = 1
                    self.actions.alphaValue = 1
                    self.lightsHide()
                    self.window?.invalidateShadow()
                }
            })
        }
    }

    private func lightsHide() {
        // Only park when no chrome owns the lights: the bar does too.
        guard barHeight == 0 else { return }
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
        guard let window else { return }
        let height = window.frame.height
        for (i, type) in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].enumerated() {
            guard let light = window.standardWindowButton(type) else { continue }
            guard let superview = light.superview else { continue }
            if barHeight > 0 {
                light.isHidden = false
                light.alphaValue = 1
                // x 20/43/66, y from the window's bottom edge (titlebar views do
                // not overlap the full-size content), measured by the demo.
                let frame = NSRect(x: ChromeBar.trafficLightInset + CGFloat(i) * ChromeBar.trafficLightSpacing, y: height - 21, width: ChromeBar.trafficLightButtonSide, height: ChromeBar.trafficLightButtonSide)
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

    /// The style itself changed (⌥⌘F / View menu): relayout, re-mask, re-place
    /// the lights; the pill never survives a switch.
    func setStyle(_ new: WindowStyle) {
        guard style != new else { return }
        style = new
        if showsPill { setPill(false) }
        pillView.isHidden = true
        pillView.alphaValue = 0
        toggle.isHidden = true
        actions.isHidden = true
        refreshBarMask()
        layoutChrome()
        placeTrafficLights()
    }
}
