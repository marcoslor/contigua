// The stream window's chrome by style (WindowStyle.swift). Framed: a permanent
// 28 pt bar above the stream. The mirror is NSBackgroundExtensionView: the
// video view is its contentView and it fills the rest of its frame — here the
// bar band — with a replica of the content's top edge, so nothing is read back
// off the CPU and nothing is decoded twice. Over the bar sits the window
// material whose maskImage carries the brief's alpha gradient (mirror alpha
// stable at the seam, fading toward the window's top edge), so the bar melts
// into the app at the seam and into the material at its top. Immersive: no
// chrome at rest; the window is exactly the stream. Full screen has no bar in
// either style.
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
    return image
}

/// The window's content for both styles: the stream, and above it (framed)
/// the bar — the extension view's mirror under the masked window material,
/// with the traffic lights riding it and the window kind's actions at its
/// right end. Clicks on the bar move the window.
final class StreamChromeView: NSView {
    let video: VideoLayerView
    /// The bar's mirror: the extension view spans the whole window, so the
    /// band beyond the video's top edge is its filled replica.
    private let ext = NSBackgroundExtensionView()
    /// The bar material, masked by `barMaskImage` so the mirror shows through
    /// at the seam and the window material takes the top.
    private let bar = NSVisualEffectView()
    /// The window kind's actions at the bar's right end (the phone window's
    /// Back/Home/Recents); hidden with the bar.
    private let actions: NSHostingView<HeaderControls>
    private(set) var style: WindowStyle
    var mirror: BarMirror = .standard { didSet { refreshBarMask() } }

    /// A click on the bar (the window moves with it); the e2e check counts them.
    var onBarPress: (() -> Void)?

    init(video: VideoLayerView, style: WindowStyle) {
        self.video = video
        self.style = style
        actions = NSHostingView(rootView: HeaderControls(actions: []))
        super.init(frame: NSRect(origin: .zero, size: style.windowSize(stream: video.frame.size)))
        wantsLayer = true
        ext.automaticallyPlacesContentView = false
        ext.contentView = video
        video.wantsLayer = true
        bar.material = .titlebar
        bar.blendingMode = .behindWindow
        bar.state = .active
        actions.sizingOptions = []
        // The bar is a window overlay; its safe area would push the buttons down.
        actions.safeAreaRegions = []
        addSubview(ext)
        addSubview(bar)
        addSubview(actions)
        refreshBarMask()
        layoutChrome()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func setActions(_ actions: [HeaderAction]) {
        self.actions.rootView = HeaderControls(actions: actions)
        needsLayout = true
    }

    var actionCount: Int { actions.rootView.actions.count }

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

    func layoutChrome() {
        ext.frame = bounds
        let bar = barHeight
        video.frame = NSRect(x: 0, y: 0, width: bounds.width, height: max(bounds.height - bar, 0))
        self.bar.frame = NSRect(x: 0, y: bounds.height - bar, width: bounds.width, height: bar)
        self.bar.isHidden = bar == 0
        ext.isHidden = bar == 0
        // The stream's corners are the window's: rounded at the bottom in both
        // styles, and at the top too in immersive (the at-rest window shape);
        // in framed the top edge is the seam, so only the bottom two round.
        if let layer = video.layer {
            layer.cornerRadius = ChromeBar.cornerRadius
            layer.cornerCurve = .continuous
            layer.masksToBounds = true
            layer.maskedCorners = bar == 0
                ? [.layerMinXMinYCorner, .layerMaxXMinYCorner, .layerMinXMaxYCorner, .layerMaxXMaxYCorner]
                : [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        }
        self.actions.isHidden = bar == 0
        if bar > 0, actionCount > 0 {
            let width = CGFloat(actionCount) * HeaderControls.buttonWidth
            self.actions.frame = NSRect(x: bounds.width - width - 12, y: bounds.height - bar,
                                        width: width, height: bar)
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
        // drag (and counts), while the kind's action buttons keep their clicks.
        return hit === bar || hit === ext ? self : hit
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        if barHeight > 0 { onBarPress?() }
        if barHeight > 0, event.clickCount == 2 {
            window.performZoom(nil)
            return
        }
        window.performDrag(with: event)
    }

    /// The traffic lights on the bar's line while the bar shows (the standard
    /// 20 pt inset, 14 pt buttons centred 14 pt from the window's top edge); out
    /// of sight otherwise (immersive's dwell pill or fullscreen's overlay shows
    /// them when needed). The lights live in the title area above the
    /// full-size content, so they are placed there in window coordinates and
    /// converted.
    func placeTrafficLights() {
        guard let window else { return }
        let height = window.frame.height
        for (i, type) in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].enumerated() {
            guard let light = window.standardWindowButton(type) else { continue }
            guard let superview = light.superview else { continue }
            if barHeight > 0 {
                light.isHidden = false
                light.alphaValue = 1
                // x 20/43/66, y from the window's bottom edge (titlebar views do not
                // overlap the full-size content), measured by the demo.
                let frame = NSRect(x: 20 + CGFloat(i) * 23, y: height - 21, width: 14, height: 14)
                light.frame = superview.convert(frame, from: nil)
            } else {
                light.isHidden = true
                light.alphaValue = 1
            }
        }
    }
}
