// Hardware H.264 rendering: AVSampleBufferDisplayLayer fed with CMSampleBuffers.
// No CPU readback, no CGImage/NSImage, no draw(_:) — that path is what made the
// prototype feel laggy. All sample-buffer work happens on a dedicated serial
// queue; the layer only ever sees ready-to-enqueue buffers in order.

import AVFoundation
import AppKit

final class VideoLayerView: NSView, BarToneSource {
    /// Created on the first VIDEO_CONFIG, not at open: a window that never
    /// shows a picture holds no decoder surface (WIN-33), and a closed window
    /// drops its layer again.
    private var display: AVSampleBufferDisplayLayer?

    /// The layer, created now if this window has a picture to draw.
    private func displayLayer() -> AVSampleBufferDisplayLayer {
        if let display { return display }
        let layer = AVSampleBufferDisplayLayer()
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = NSColor.black.cgColor
        pictureClip.addSublayer(layer)
        display = layer
        placeDisplayLayer()
        return layer
    }
    private let videoQueue = DispatchQueue(label: "dev.pocketdeck.video")
    /// Touched only on `videoQueue`.
    private var formatDescription: CMVideoFormatDescription?
    /// The VIDEO_CONFIG the decoder runs on (videoQueue), for WIN-63.
    private var appliedConfig: VideoConfig?
    private var currentCodec: VideoCodec = .avc
    private var lastPtsUs: UInt64 = 0

    /// M1's waiting room (ISS-40), main-thread only: decoded samples wait for
    /// this window's display link when `present` is paced. With the default
    /// (immediate) the presenter is never fed.
    private struct PacedSample {
        var sample: CMSampleBuffer
        var ptsUs: UInt64
        var keyframe: Bool
    }
    private var presenter = PacedPresenter<PacedSample>()
    private var pacedLink: CADisplayLink?

    /// Size (px) of the picture the window shows: the frame's picture rect of the last
    /// VIDEO_CONFIG. Drives aspect-fit letterboxing, the window's aspect and the input map.
    private(set) var videoSize: CGSize = .zero

    /// Size (px) of the whole frame of the last VIDEO_CONFIG, and where the picture is in it
    /// (window.content). A frame may carry a band outside its picture, which is never drawn.
    private(set) var frameSize: CGSize = .zero
    private var picture = PictureRect.full(width: 0, height: 0)

    /// Clips the display layer to the drawn picture (PictureCrop.swift).
    private let pictureClip = CALayer()

    /// The phone window mirrors a fixed screen: a picture of the same shape
    /// fills its area (the encoder's rounding only, Letterbox.placement), and
    /// a clearly different shape is fitted. The app window stretches a
    /// same-shape frame.
    var isPhoneMode = false

    /// The window's strategy (ISS-40), read when the window opens or resizes.
    /// The presenter (M1) reads `present`; the pixel cap (M2) is applied where
    /// the window asks for its size.
    var strategy = MacStreamStrategy() {
        didSet {
            guard strategy.present != oldValue.present else { return }
            // Back to immediate: show what the paced queue holds, in order.
            if strategy.present == .immediate {
                stopPacedLink()
                drainPresenterNow()
            }
        }
    }

    /// The encoder's own limits (ISS-39), set when the window opens. nil keeps
    /// the old 16 px rule for a phone that reports none.
    var encoder: EncoderSpec?
    /// The alignment the phone actually snaps app streams to: the encoder's
    /// own (the larger axis, so either axis' strip counts as one step), or 16
    /// when it reports none.
    private var alignment: Int {
        guard let encoder else { return VideoSize.granularity }
        return max(encoder.widthAlign, encoder.heightAlign)
    }

    /// When the window last asked for a new size; until a config at that size
    /// arrives (or this passes) the last frame fills the view.
    private var resizeFillUntil: TimeInterval?
    private var resizeTimeout: DispatchWorkItem?

    /// The drag/answer/settle phases; the gravity holds fill through them.
    private var resizeLayout = ResizeLayout()
    private var settleWork: DispatchWorkItem?  // gcd: one cancellable main-queue beat

    /// The window is being resized right now (a drag, or the app's own zoom
    /// animation). A stale picture cannot answer a request at this size, even
    /// when the two aspects are close enough for the settled rule.
    var isWindowLiveResizing = false

    /// A phone that never answers must not leave a cropped picture up forever.
    static let resizeFillTimeout: TimeInterval = 2

    /// Posted on the main queue once a VIDEO_CONFIG size is applied (object: the view).
    static let videoSizeDidChange = Notification.Name("dev.pocketdeck.videoSizeDidChange")

    /// The decoder needs an IDR (window.keyframe) when the layer fails.
    var onRequestKeyframe: (() -> Void)?

    /// A frame reached the display layer, on the main queue: the stats
    /// window's "enqueued" side (the frame path itself is unchanged).
    var onFrameEnqueued: ((UInt64) -> Void)?
    /// A frame did not reach the layer, and why. `beforeConfig` also covers a
    /// payload with no access unit; the line only carries the count.
    var onFrameDiscarded: ((StatsDiscardReason) -> Void)?
    /// A delta reached the layer while the chain was known broken (WIN-61):
    /// the gate makes this impossible, and the stats line prints it as
    /// `chain_fed` so a field log would show a gate bug.
    var onChainFed: (() -> Void)?
    /// WIN-61's feed state: `flowing`, or waiting for a keyframe after a
    /// break. Main-thread state, like every layer call.
    private var chain = ChainGuard()
    /// The one follow-up keyframe request; cancelled by a restore or a close.
    private var chainRetry: Task<Void, Never>?
    /// A frame the phone flagged key: its NAL types and the stream's codec, for
    /// the IDR check.
    var onKeyFrame: (([UInt8], VideoCodec) -> Void)?

    /// A VIDEO_CONFIG named a codec this Mac cannot decode: refuse the stream
    /// (WIN-60). Runs on the main queue.
    var onCodecRefused: ((String) -> Void)?

    /// P0 (pmaxx): the input-to-photon probe's private decoder, model and
    /// continuations. Only alive while one probe runs (a few seconds); the
    /// decoder watches the stream's own frames, the model is pure.
    private var probeDecoder: InputProbeDecoder?
    private var probeModel: InputProbeModel?
    private var probeRegion: ProbeRegion = .whole
    private let probeLock = NSLock()
    private var probeArmedContinuation: CheckedContinuation<Bool, Never>?
    private var probeResultContinuation: CheckedContinuation<InputProbeOutcome, Never>?

    /// How the picture is placed in the view, by the name the stats line uses.
    var placementName: String {
        switch placement() {
        case .fit: return "fit"
        case .fill: return "fill"
        case .oneToOne: return "oneToOne"
        case .stretch: return "stretch"
        }
    }

    /// The view in backing pixels: what the window really draws on.
    var backingPixelSize: CGSize {
        let scale = Double(window?.backingScaleFactor ?? 1)
        return CGSize(width: (bounds.width * scale).rounded(),
                      height: (bounds.height * scale).rounded())
    }

    /// The frame's own pixel size from the last VIDEO_CONFIG (the stream's size).
    var framePixelSize: CGSize { frameSize }

    /// All AppKit events are handed to this mapper.
    var inputMapper: InputMapper?

    /// Where the Show Touches dots are drawn. The chrome sets this to a layer
    /// of its own, outside the extension view's mirror: a dot inside the
    /// mirrored content would be reflected into the framed bar. nil draws on
    /// the video's own layer (no chrome: tests and previews).
    var touchDotHost: CALayer?

    /// True at a window point that is Mac UI drawn over the video (the
    /// immersive pill): hovering there is not hovering the phone.
    var macUIAtWindowPoint: ((CGPoint) -> Bool)?

    private var trackingArea: NSTrackingArea?

    /// Finder drags land here (`dropfile` scripting and the NSDraggingDestination
    /// end on the same call; e2e drives it either way). SHARE-18's three new
    /// sources arrive through `onDroppedDrag`; `onDroppedFiles` stays the
    /// simple file-only seam tests and the old debug verb use.
    var onDroppedFiles: (([URL]) -> Void)?
    var onDroppedDrag: ((DropDrag) -> Void)?
    /// A press on the picture (the phone's touch): the keyboard goes back to
    /// the phone, away from the bar (MIRROR-13).
    var onPointerDown: (() -> Void)?

    /// The window is paused (hidden, minimized or covered): the phone is told to
    /// stop, and paced presentation stops its display link with it.
    var isPaused = false {
        didSet {
            guard isPaused != oldValue else { return }
            if isPaused { runPresenter(.pause) }
        }
    }

    /// Live Text mode (LiveTextView.swift): the frozen frame and the VisionKit
    /// overlay over this view. Created here so input, layout and the frame
    /// route stay in one place; the window controller drives it.
    private(set) var liveText: LiveTextSession!


    /// Edge-swipe back gesture (two fingers from the left strip).
    private var edgeSwipe = EdgeSwipeClassifier()
    private var edgeSwipeTracking = false
    private let edgeHint = CAShapeLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        liveText = LiveTextSession(host: self)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        pictureClip.masksToBounds = true
        layer?.addSublayer(pictureClip)
        installEdgeHint()
        // Raw fingers of the trackpad (not the screen: there is none) for the
        // pinch and rotate pointers; resting palms and thumbs are not reported.
        allowedTouchTypes = [.indirect]
        wantsRestingTouches = false
        // A Finder drag onto the window delivers files, image data, promises or
        // a link (docs/design/dragdrop.md, SHARE-18).
        registerForDraggedTypes([.fileURL] + DropDragReader.imageTypes
                                + DropDragReader.promiseTypes + [.URL])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// The window closed: it keeps no picture. AppKit holds a closed window in
    /// `NSApp.windows`, so the layer tree and the decoded frame are dropped
    /// here rather than when the window object finally goes (WIN-33).
    func releasePicture() {
        runPresenter(.close)
        runChain(.reset)
        display?.flushAndRemoveImage()
        display?.removeFromSuperlayer()
        display = nil
        pictureClip.removeFromSuperlayer()
        liveText.release()
        layer?.sublayers?.forEach { $0.removeFromSuperlayer() }
        layer?.contents = nil
    }

    override var isFlipped: Bool { false }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Hover (docs/PROTOCOL.md HOVER)

    /// The video is the phone's surface: the pointer over it is a mouse over
    /// Android. `.inVisibleRect` follows the letterbox and resizes for free.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseMoved, .mouseEnteredAndExited,
                                            .activeInActiveApp, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        hoverPointerMoved(toWindowPoint: event.locationInWindow)
    }

    override func mouseExited(with event: NSEvent) { inputMapper?.hoverExit() }

    /// The scripted driver's `hover`/`hoverout`
    /// reach the same decision: the chrome's own points are Mac UI, the rest is
    /// the phone. The point is in the window's base coordinates.
    func hoverPointerMoved(toWindowPoint point: CGPoint) {
        if macUIAtWindowPoint?(point) == true {
            inputMapper?.hoverExit()
        } else {
            inputMapper?.hoverMove(at: convert(point, from: nil))
        }
    }

    /// The window went away: the phone must not keep a hover it cannot end.
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { inputMapper?.hoverExit() }
        super.viewWillMove(toWindow: newWindow)
    }

    /// No window means no display link: a paced queue must not hold frames no
    /// refresh will release.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window == nil else { return }
        runPresenter(.close)
    }

    // MARK: File drops (docs/design/dragdrop.md)

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        canReadFiles(in: sender) ? .copy : []
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        canReadFiles(in: sender) ? .copy : []
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard let drag = DropDragReader.read(sender.draggingPasteboard) else { return false }
        Log.app.info("drop: \(drag.kind, privacy: .public) on the window")
        if let onDroppedDrag {
            onDroppedDrag(drag)
        } else if !drag.files.isEmpty {
            onDroppedFiles?(drag.files)
        } else {
            return false
        }
        return true
    }

    private func canReadFiles(in sender: any NSDraggingInfo) -> Bool {
        DropDragReader.canRead(sender.draggingPasteboard)
    }

    override func layout() {
        super.layout()
        placeDisplayLayer()
        updateGravity()
        edgeHint.position = CGPoint(x: edgeHint.position.x, y: bounds.midY)
        liveText.layout(in: videoRect())
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        placeDisplayLayer()
        updateGravity()
        liveText.layout(in: videoRect())
    }

    /// The first drag event, before the first size change: the pending-fill rule
    /// is up from the start of a live resize, not from the first did-resize.
    override func viewWillStartLiveResize() {
        super.viewWillStartLiveResize()
        liveResizeBegan()
    }

    /// The first drag event and the app's own zoom both begin here; a second
    /// begin is the same phase.
    func liveResizeBegan() {
        applyResizeLayout(.dragBegan)
        noteResizeRequested()
    }

    /// The shape change is over; the phone is asked once and its answer will
    /// settle the picture.
    func liveResizeEnded() {
        applyResizeLayout(.dragEnded)
    }

    private func applyResizeLayout(_ event: ResizeLayoutEvent) {
        let before = resizeLayout.phase
        resizeLayout.apply(event)
        guard resizeLayout.phase != before else { return }
        Log.video.info("resize-layout: \(before.state, privacy: .public) --\(event.kind, privacy: .public)--> \(self.resizeLayout.phase.state, privacy: .public)")
        updateGravity()
    }

    /// The display layer follows the view exactly. A plain `frame = bounds` in
    /// a resize is an implicit ~0.25 s CALayer animation (the layer's delegate
    /// is nil), so the picture trails the window edge on a fast drag and the
    /// new area shows the layer's black background: the reported black bands.
    private func placeDisplayLayer() {
        placeDisplayLayer(in: bounds.size)
    }

    /// Sets both picture layers for a size, in one committed transaction. A
    /// live resize calls it for the *coming* size before the window frame
    /// changes: WindowServer can show the new window against the last
    /// committed surface, so that surface must already cover it (WIN-58).
    private func placeDisplayLayer(in size: CGSize) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let rect = videoRect(in: size)
        pictureClip.frame = rect
        display?.frame = frameSize.width > 0
            ? PictureCrop.layerFrame(frame: frameSize, content: picture, picture: rect.size)
            : rect
        CATransaction.commit()
    }

    /// A live-resize step's target stream size, before the window takes it.
    func prepareLiveResize(to size: CGSize) {
        placeDisplayLayer(in: size)
        // The frame change reaches WindowServer from the same runloop turn;
        // the layer transaction must be there first, not at the next flush.
        CATransaction.flush()
        updateGravity()
    }

    /// The display layer, for the resize tests: after a size change it must
    /// have no animation and its presentation frame must be the new bounds.
    var displayLayerForTesting: AVSampleBufferDisplayLayer { displayLayer() }

    /// Whether this window holds a display layer at all: the picture's home
    /// (WIN-33), nil before the first VIDEO_CONFIG and after a close.
    var hasPictureLayer: Bool { display != nil }

    /// Tests: the size a VIDEO_CONFIG would set, without a decoder or a real
    /// parameter set (the rotation rule only needs the orientation).
    func setVideoSizeForTesting(_ size: CGSize) {
        videoSize = size
    }

    /// How far the drawn picture falls short of the view's bounds, in points:
    /// 0 when the picture covers the content (fill/stretch or an exact fit),
    /// more while the display layer trails a resize or a real letterbox shows.
    /// The e2e samples this through the chrome state on every resize step.
    func videoGap() -> CGFloat {
        // No picture yet: there is no drawn rect to be short of the content.
        guard videoSize.width > 0, videoSize.height > 0,
              bounds.width > 0, bounds.height > 0 else { return 0 }
        // A layer with an animation in flight is drawn where its presentation
        // is, not where its model frame says. With no animation the model frame
        // is the truth (the presentation can lag the last commit by a frame).
        guard let display else { return 0 }
        let animating = !(display.animationKeys()?.isEmpty ?? true)
        let layerRect = animating ? (display.presentation()?.frame ?? display.frame) : display.frame
        // The picture is the layer seen through its clip (layer coordinates are the clip's).
        let drawn = pictureClip.frame.intersection(
            layerRect.offsetBy(dx: pictureClip.frame.minX, dy: pictureClip.frame.minY))
        guard !drawn.isNull else { return max(bounds.width, bounds.height) }
        let gap = max(0, drawn.minX - bounds.minX, bounds.maxX - drawn.maxX,
                      drawn.minY - bounds.minY, bounds.maxY - drawn.maxY)
        return gap
    }

    /// Stretches over the 16 px quantisation instead of showing thin black bars;
    /// `videoRect()` follows the same rule, so input maps to what is drawn.
    private func updateGravity() {
        let placement = Self.drawnPlacement(placement(), holdsFill: resizeLayout.holdsFillGravity)
        let gravity = Self.gravity(for: placement)
        let layer = displayLayer()
        if layer.videoGravity != gravity { layer.videoGravity = gravity }
    }

    /// The placement the layer actually draws. Holding fill through the answer
    /// keeps the layer from re-laying its contents mid-drag; the input map and
    /// the crop must follow the same rule or a click would miss the picture
    /// during the settle (WIN-58).
    static func drawnPlacement(_ placement: Letterbox.Placement, holdsFill: Bool) -> Letterbox.Placement {
        guard holdsFill else { return placement }
        switch placement {
        case .oneToOne, .stretch: return .fill
        case .fit, .fill: return placement
        }
    }

    private func placement() -> Letterbox.Placement {
        Letterbox.placement(video: videoSize, bounds: bounds.size,
                            backingScale: Double(window?.backingScaleFactor ?? 1),
                            alignment: alignment,
                            resizePending: resizeIsPending, phoneMode: isPhoneMode)
    }

    /// The gravity that draws `placement`. `oneToOne` still uses `resize`: the
    /// layer's frame is already the video's own pixel size, so no resampling
    /// happens (a stretch would be exactly 1:1).
    static func gravity(for placement: Letterbox.Placement) -> AVLayerVideoGravity {
        switch placement {
        case .fit: return .resizeAspect
        case .fill: return .resizeAspectFill
        case .oneToOne: return .resize
        case .stretch: return .resize
        }
    }

    /// The window asked for a new size (a drag or the resize message itself):
    /// the last frame fills the view until a VIDEO_CONFIG at that size arrives.
    /// The timeout falls back to aspect-fit, so a phone that never answers does
    /// not leave a crop up.
    func noteResizeRequested() {
        resizeFillUntil = ProcessInfo.processInfo.systemUptime + Self.resizeFillTimeout
        resizeTimeout?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.resizeFillUntil = nil
            self.resizeTimeout = nil
            self.applyResizeLayout(.timedOut)
            self.updateGravity()
        }
        resizeTimeout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.resizeFillTimeout, execute: work)
        updateGravity()
    }

    /// The pending-fill rule's two flags, for the zoom probe
    /// (`--debug-stream-zoom`): whether the fill is armed and whether it still
    /// applies at this size.
    var resizeFillState: (armed: Bool, pending: Bool) { (resizeFillUntil != nil, resizeIsPending) }

    /// Frames handed to the display layer, for the zoom probe: the picture's
    /// liveness across a window animation (an animation that holds the main
    /// run loop stops these).
    private(set) var framesDrained = 0
    /// Changes when a frame reaches the display layer: the bar's tone
    /// sampler skips a still picture instead of reading it twice (WIN-69).
    private(set) var frameStamp: UInt64 = 0
    /// Samples handed over since the last flush, so a flush that discards some
    /// is counted once (not once per frame).
    private var samplesSinceFlush = 0
    /// The bar-tone sampler's queue: the band's tiny readback never runs on
    /// the frame path or on main.
    private let toneQueue = DispatchQueue(label: "dev.pocketdeck.bartone", qos: .utility)  // gcd: one utility lane for the band readback, never the frame path

    /// A resize is pending while the window has asked and the last frame is not
    /// the size it asked for.
    private var resizeIsPending: Bool {
        guard let until = resizeFillUntil, ProcessInfo.processInfo.systemUptime < until else { return false }
        return Letterbox.resizeStillPending(video: videoSize, request: requestedPixels,
                                            liveResizing: isWindowLiveResizing || window?.inLiveResize == true,
                                            alignment: alignment)
    }

    /// What the window's own size asks the phone for (the same number
    /// `window.resize` carries). The window supplies the full rule (its stream
    /// area, encoder limits, panel cap) when it has one.
    private var requestedPixels: CGSize {
        if let requestedPixelsOverride { return requestedPixelsOverride() }
        let scale = Double(window?.backingScaleFactor ?? 1)
        return VideoSize.displayPixels(bounds: bounds.size, backingScale: scale, encoder: encoder)
    }

    /// The window's request rule, set when the view joins the window; nil keeps
    /// the view-only rule (tests and previews).
    var requestedPixelsOverride: (() -> CGSize)?

    /// Drawn rect of the current video inside the view: the same rule as the
    /// gravity, so a click lands on the pixel under the pointer, even mid-resize.
    func videoRect() -> CGRect {
        videoRect(in: bounds.size)
    }

    /// The drawn rect for a view of `size`, for a live resize that wants the
    /// layers placed before the view takes its new size.
    private func videoRect(in size: CGSize) -> CGRect {
        guard videoSize.width > 0, videoSize.height > 0, size.width > 0, size.height > 0 else {
            return CGRect(origin: .zero, size: size)
        }
        let backingScale = Double(window?.backingScaleFactor ?? 1)
        let placement = Self.drawnPlacement(Letterbox.placement(video: videoSize, bounds: size,
                                                                backingScale: backingScale,
                                                                alignment: alignment,
                                                                resizePending: resizeIsPending,
                                                                phoneMode: isPhoneMode),
                                            holdsFill: resizeLayout.holdsFillGravity)
        return Letterbox.videoRect(video: videoSize, in: CGRect(origin: .zero, size: size),
                                   placement: placement, backingScale: backingScale)
    }

    // MARK: Video

    /// The frame the display layer is showing right now (Live Text's freeze
    /// source). Main thread only, like the rest of the layer's work; the copy
    /// is one buffer per entry, never per frame.
    ///
    /// `displayedPixelBuffer()` answers only while the renderer's timebase is
    /// stopped ("NULL if the rate is non-zero"), so the rate is paused around
    /// the copy and put back at once: the layer keeps showing what it showed,
    /// and the next enqueued frame paints as before.
    func copyDisplayedFrame() -> CVPixelBuffer? {
        guard let display else { return nil }
        let renderer = display.sampleBufferRenderer
        let timebase = renderer.timebase
        let rate = CMTimebaseGetRate(timebase)
        if rate != 0 { CMTimebaseSetRate(timebase, rate: 0) }
        defer { if rate != 0 { CMTimebaseSetRate(timebase, rate: rate) } }
        return renderer.displayedPixelBuffer()
    }

    /// The luminance range of the picture's top band, the source the Framed
    /// bar mirrors (WIN-69). The displayed buffer is taken on main (the
    /// renderer's own rule) and read on `toneQueue`, a few dozen samples:
    /// no full-frame copy and no work on the frame path.
    func topBandRange(xFrom: CGFloat, xTo: CGFloat, bandFraction: CGFloat,
                      completion: @escaping (BandRange?) -> Void) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in  // gcd: the renderer's buffer is main's
                self?.topBandRange(xFrom: xFrom, xTo: xTo, bandFraction: bandFraction,
                                   completion: completion)
            }
            return
        }
        guard picture.w > 0, picture.h > 0, frameSize.width > 0, frameSize.height > 0,
              let buffer = copyDisplayedFrame() else {
            completion(nil)
            return
        }
        let bufferWidth = CGFloat(CVPixelBufferGetWidth(buffer))
        let bufferHeight = CGFloat(CVPixelBufferGetHeight(buffer))
        guard bufferWidth > 0, bufferHeight > 0 else {
            completion(nil)
            return
        }
        // `picture` is in the frame's pixels; the buffer is that frame.
        let scaleX = bufferWidth / frameSize.width
        let scaleY = bufferHeight / frameSize.height
        let x0 = CGFloat(picture.x) + CGFloat(picture.w) * min(max(xFrom, 0), 1)
        let x1 = CGFloat(picture.x) + CGFloat(picture.w) * min(max(xTo, 0), 1)
        let y = CGFloat(picture.y)
        let height = max(1, CGFloat(picture.h) * min(max(bandFraction, 0), 1))
        let rect = CGRect(x: x0 * scaleX, y: y * scaleY,
                          width: max(1, (x1 - x0) * scaleX), height: height * scaleY).integral
        toneQueue.async { [weak self] in
            guard let self else { return }
            let value = BandLuminance.range(of: buffer, rect: rect)
            DispatchQueue.main.async { completion(value) }  // gcd: the completion's main-queue contract
        }
    }

    // MARK: Input-to-photon probe (P0, pmaxx)

    /// Arms a probe: the frame on screen now is the baseline when the display
    /// layer has one, else the first frame the private decoder delivers is.
    /// Either way a private decoder starts and a keyframe is requested, so the
    /// first frame after the tap can be decoded even on an idle stream (the
    /// phone sends nothing while the picture is still). Returns true once a
    /// baseline is in; the caller then sends the tap and calls
    /// `inputProbeTapSent`. A window with no format or no frame in 1.5 s fails.
    @MainActor
    func beginInputProbe(region: ProbeRegion) async -> Bool {
        await withCheckedContinuation { continuation in
            probeLock.lock()
            probeArmedContinuation = continuation
            probeRegion = region
            var model = InputProbeModel { line in
                Log.video.info("\(line, privacy: .public)")  // log-ok: closed states and ms only
            }
            _ = model.handle(.arm)
            probeModel = model
            probeLock.unlock()
            videoQueue.async { [weak self] in
                guard let self else { return }
                self.probeDecoder?.cancel()
                guard let format = self.formatDescription else {
                    Log.video.info("input probe: no video format yet")  // log-ok: a state, no pixels
                    DispatchQueue.main.async { self.inputProbeBaselineFailed() }  // gcd: probe state is main's
                    return
                }
                let decoder = InputProbeDecoder()
                decoder.begin(format: format) { [weak self] image, atMs in
                    self?.inputProbeFrame(image, atMs: atMs)
                }
                self.probeDecoder = decoder
                Log.video.info("input probe: decoder armed for \(format.mediaSubType, privacy: .public)")  // log-ok: a codec fourcc
                DispatchQueue.main.async {  // gcd: the layer and the probe state are main's
                    self.onRequestKeyframe?()
                    self.inputProbeArmDisplayedBaseline()
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in  // gcd: resumes a main-actor continuation
                self?.inputProbeBaselineFailed()
            }
        }
    }

    /// The visible frame is the honest baseline for an idle stream. Only when
    /// the layer has nothing to show yet does the probe wait for its decoder.
    @MainActor
    private func inputProbeArmDisplayedBaseline() {
        var armed: CheckedContinuation<Bool, Never>?
        let frame = copyDisplayedFrame()
        let signature = frame.flatMap { ProbeSignal.signature(of: $0, region: probeRegion) }
        probeLock.lock()
        if let signature, var model = probeModel {
            let action = model.handle(.frame(signature, atMs: ProcessInfo.processInfo.systemUptime * 1000))
            probeModel = model
            if case .armed? = action {
                armed = probeArmedContinuation
                probeArmedContinuation = nil
            }
        } else {
            // The layer has no drawn frame yet (or a format the grid cannot
            // read): the probe still waits for its own decoder's first frame.
            if let frame {
                Log.video.info("input probe: displayed baseline unsupported \(CVPixelBufferGetPixelFormatType(frame), privacy: .public)")  // log-ok: a codec fourcc
            } else {
                Log.video.info("input probe: no displayed frame yet")  // log-ok: a state, no pixels
            }
        }
        probeLock.unlock()
        armed?.resume(returning: true)
    }

    /// The tap went out at this Mac-monotonic millisecond.
    @MainActor
    func inputProbeTapSent(atMs: Double) {
        probeLock.lock()
        if var model = probeModel {
            _ = model.handle(.tapSent(atMs: atMs))
            probeModel = model
        }
        probeLock.unlock()
    }

    /// The first changed frame, or a timing-out answer. The caller ends the
    /// probe either way.
    @MainActor
    func awaitInputProbe(timeout: TimeInterval) async -> InputProbeOutcome {
        await withCheckedContinuation { continuation in
            probeLock.lock()
            probeResultContinuation = continuation
            probeLock.unlock()
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in  // gcd: resumes a main-actor continuation
                self?.inputProbeDeadline()
            }
        }
    }

    @MainActor
    func endInputProbe() {
        videoQueue.async { [weak self] in
            self?.probeDecoder?.cancel()
            self?.probeDecoder = nil
        }
        probeLock.lock()
        let armed = probeArmedContinuation
        let result = probeResultContinuation
        let frames = probeModel?.frames ?? 0
        probeArmedContinuation = nil
        probeResultContinuation = nil
        probeModel = nil
        probeLock.unlock()
        armed?.resume(returning: false)
        result?.resume(returning: InputProbeOutcome(armed: false, changedMs: nil, frames: frames))
    }

    private func inputProbeBaselineFailed() {
        probeLock.lock()
        let armed = probeArmedContinuation
        probeArmedContinuation = nil
        // A baseline that already arrived cancels this timer's meaning: the
        // model is watching and must not be marked done 1.5 s into the probe.
        if armed != nil, var model = probeModel {
            _ = model.handle(.deadline)
            probeModel = model
        }
        probeLock.unlock()
        armed?.resume(returning: false)
    }

    @MainActor
    private func inputProbeDeadline() {
        probeLock.lock()
        var outcome: InputProbeOutcome?
        let result = probeResultContinuation
        if var model = probeModel, model.handle(.deadline) != nil {
            outcome = InputProbeOutcome(armed: true, changedMs: nil, frames: model.frames)
            probeModel = model
            probeResultContinuation = nil
        }
        probeLock.unlock()
        if let outcome {
            result?.resume(returning: outcome)
        }
    }

    /// Runs on the decoder's queue. The model is pure; the continuations are
    /// resumed outside the lock.
    private func inputProbeFrame(_ image: CVPixelBuffer, atMs: Double) {
        var armed: CheckedContinuation<Bool, Never>?
        var result: CheckedContinuation<InputProbeOutcome, Never>?
        var outcome: InputProbeOutcome?
        probeLock.lock()
        if var model = probeModel,
           let signature = ProbeSignal.signature(of: image, region: probeRegion) {
            let action = model.handle(.frame(signature, atMs: atMs))
            probeModel = model
            switch action {
            case .armed?:
                armed = probeArmedContinuation
                probeArmedContinuation = nil
            case .changed(let ms)?:
                outcome = InputProbeOutcome(armed: true, changedMs: ms, frames: model.frames)
                result = probeResultContinuation
                probeResultContinuation = nil
            case .timedOut?:
                outcome = InputProbeOutcome(armed: true, changedMs: nil, frames: model.frames)
                result = probeResultContinuation
                probeResultContinuation = nil
            case .none:
                break
            }
        }
        probeLock.unlock()
        armed?.resume(returning: true)
        if let outcome {
            result?.resume(returning: outcome)
        }
    }

    // MARK: Frame snapshot (Live Text's second route)

    /// Touched only on `videoQueue`.
    private var snapshotter: KeyframeSnapshotter?

    /// Asks the phone for a keyframe and decodes it with a private
    /// decompression session, only until the first frame arrives. This is the
    /// route for windows whose display layer reports no displayed buffer
    /// (occluded windows, quiet e2e runs). `handler(nil)` when there is no
    /// format yet or the decoder cannot start.
    func beginFrameSnapshot(_ handler: @escaping (CVPixelBuffer?) -> Void) {
        videoQueue.async { [weak self] in
            guard let self else { return }
            self.snapshotter?.cancel()
            guard let format = self.formatDescription else {
                DispatchQueue.main.async { handler(nil) }
                return
            }
            let snapshotter = KeyframeSnapshotter()
            self.snapshotter = snapshotter
            snapshotter.begin(format: format) { buffer in
                DispatchQueue.main.async { handler(buffer) }
            }
            DispatchQueue.main.async { [weak self] in self?.onRequestKeyframe?() }
        }
    }

    /// The mode left before a frame arrived: drop the decoder.
    func cancelFrameSnapshot() {
        videoQueue.async { [weak self] in
            self?.snapshotter?.cancel()
            self?.snapshotter = nil
        }
    }

    /// Why there is no frame to freeze, for the scripted check (state only, no
    /// pixels). "renderer=…" is the API's own status; the rest is the layer and
    /// its window.
    func frameDiagnostics() -> String {
        guard let display else {
            return "renderer=none (no picture yet) bounds=\(Int(bounds.width))x\(Int(bounds.height))"
        }
        let renderer = display.sampleBufferRenderer
        let rate = CMTimebaseGetRate(renderer.timebase)
        let visible = window?.isVisible ?? false
        let occluded = !(window?.occlusionState.contains(.visible) ?? false)
        return "renderer=\(renderer.status.rawValue) rate=\(rate) ready=\(renderer.isReadyForMoreMediaData)"
            + " bounds=\(Int(bounds.width))x\(Int(bounds.height)) video=\(Int(videoSize.width))x\(Int(videoSize.height))"
            + " window=\(visible) occluded=\(occluded) paused=\(isPaused)"
    }

    func configure(_ config: VideoConfig, picture: PictureRect) {
        let codec: VideoCodec
        switch VideoCodecPolicy.decision(for: config.codec) {
        case .refuse(let token):
            // Never hand the bytes to another codec's decoder: the window
            // refuses the stream through its existing refusal state.
            DispatchQueue.main.async { [weak self] in self?.onCodecRefused?(token) }  // gcd: the refusal reaches the window on main, like every other picture state
            return
        case .decode(let accepted):
            codec = accepted
        }
        guard let format = Self.makeFormatDescription(config, codec: codec) else {
            Log.video.error("VIDEO_CONFIG without its codec's parameter sets")
            onRequestKeyframe?()
            return
        }
        let size = CGSize(width: CGFloat(config.width), height: CGFloat(config.height))
        videoQueue.async { [weak self] in
            guard let self else { return }
            let needsFlush = self.formatDescription == nil
                || Self.configNeedsFlush(applied: self.appliedConfig, next: config)
            self.appliedConfig = config
            self.formatDescription = format
            self.currentCodec = codec
            if needsFlush {
                self.lastPtsUs = 0
                // The flush rides the same ordered hand-off as the samples, so a
                // drain can never put new-format samples ahead of it.
                self.handOff(.flush)
            }
            DispatchQueue.main.async {
                self.frameSize = size
                self.picture = picture
                self.videoSize = picture.size
                // The phone answered at the size the window asked for: the
                // fill (if one was up) ends now, before the timeout.
                if self.resizeFillUntil != nil,
                   Letterbox.answers(config: size, request: self.requestedPixels,
                                     alignment: self.alignment) {
                    self.resizeFillUntil = nil
                    self.resizeTimeout?.cancel()
                    self.resizeTimeout = nil
                    self.applyResizeLayout(.answered)
                    // One beat after the answer before the settled gravity:
                    // the layer's contents re-layout is visible for ~0.2 s if
                    // it lands while the window server still shows the drag.
                    self.settleWork?.cancel()
                    let settle = DispatchWorkItem { [weak self] in  // gcd: the resizeTimeout pattern
                        self?.applyResizeLayout(.settleElapsed)
                    }
                    self.settleWork = settle
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: settle)  // gcd: same queue and delay as resizeTimeout
                }
                self.updateGravity()
                self.needsLayout = true
                self.needsDisplay = true
                NotificationCenter.default.post(name: Self.videoSizeDidChange, object: self)
                self.liveText.noteStreamConfig(size: picture.size)
            }
        }
    }

    /// R6: the session's chunk assembler threw an incomplete access unit away
    /// (a different pts arrived, a bad payload, or the stream closed). Those
    /// bytes never reached this view, so the feed breaks here and holds every
    /// delta until a keyframe — the discarded sample is one the decoder needed.
    func incompleteChunkedUnit() {
        videoQueue.async { [weak self] in
            guard let self else { return }
            self.onFrameDiscarded?(.incomplete)
            self.handOff(.chainBreak(.incomplete))
        }
    }

    func enqueue(_ frame: VideoFrameData) {
        videoQueue.async { [weak self] in
            guard let self else { return }
            // Every stream sends VIDEO_CONFIG before its frames; without one
            // there is nothing to decode.
            guard let format = self.formatDescription else {
                self.onFrameDiscarded?(.beforeConfig)
                self.handOff(.chainBreak(.beforeConfig))
                return
            }
            let units = AnnexB.units(frame.annexB)
            let codec = self.currentCodec
            let avcc = AnnexB.avcc(from: units, codec: codec)
            guard !avcc.isEmpty else {
                self.onFrameDiscarded?(.beforeConfig)
                self.handOff(.chainBreak(.beforeConfig))
                return
            }
            // The presenter must not drop a keyframe while a delta can go:
            // without one the decoder cannot restart (M1's queue cap).
            let keyframe = AnnexB.isIdr(units, codec: codec)
            if frame.isKeyframe {
                // The wire flag, not this IDR test: the stats must count what
                // the phone claimed, including the frames that cannot restart.
                self.onKeyFrame?(units.map { AnnexB.nalType($0, codec: codec) }, codec)
            }
            let pts = max(frame.ptsUs, self.lastPtsUs &+ 1)
            self.lastPtsUs = pts
            guard let sample = Self.makeSampleBuffer(avcc: avcc, format: format, ptsUs: pts) else { return }
            self.snapshotter?.feed(sample)
            self.probeDecoder?.feed(sample)
            // The byte work above is the expensive part and stays off the main
            // thread, but CALayer is main-thread-only: reading or mutating the
            // display layer from here is undefined and leaves it accepting
            // buffers it never composites (the window stays black until a resize
            // dirties the layer). Hand the finished buffer over and enqueue there.
            self.handOff(.sample(sample, ptsUs: pts, keyframe: keyframe))
        }
    }

    private enum PendingVideo {
        case flush
        case sample(CMSampleBuffer, ptsUs: UInt64, keyframe: Bool)
        /// The frame path dropped a sample before the layer saw it (no
        /// config, or an empty access unit): the chain is broken until the
        /// next keyframe.
        case chainBreak(ChainGuard.Reason)
    }

    /// Filled on `videoQueue`, drained on main; guarded by `pendingLock`.
    private var pendingVideo: [PendingVideo] = []
    private var drainScheduled = false
    private let pendingLock = NSLock()

    /// Queues work for the display layer with at most one main-queue block in
    /// flight: a burst of frames (the first second of a window, a fast scroll)
    /// costs main one drain, not one block per frame. Samples are never dropped:
    /// each H.264 frame depends on the one before it.
    private func handOff(_ item: PendingVideo) {
        pendingLock.lock()
        pendingVideo.append(item)
        let schedule = !drainScheduled
        drainScheduled = true
        pendingLock.unlock()
        if schedule {
            DispatchQueue.main.async { [weak self] in self?.drainPendingVideo() }
        }
    }

    private func drainPendingVideo() {
        pendingLock.lock()
        let items = pendingVideo
        pendingVideo.removeAll(keepingCapacity: true)
        drainScheduled = false
        pendingLock.unlock()
        let renderer = displayLayer().sampleBufferRenderer
        for item in items {
            switch item {
            case .flush:
                // The layer's own queue goes with the flush; a count, not the
                // frame sizes, is what the stats line needs. Paced waiters are
                // old-format samples and go with it.
                if samplesSinceFlush > 0 || presenter.hasWaiting { onFrameDiscarded?(.flush) }
                samplesSinceFlush = 0
                runPresenter(.flush)
                renderer.flush()
                if framesDrained > 0 { runChain(.breakChain(.config, now: now())) }
            case .chainBreak(let reason):
                // R6: an incomplete chunked unit breaks the chain even before
                // the first frame is drained: the unit was to be the next
                // picture's reference, and only a keyframe can restart it.
                if framesDrained > 0 || reason == .incomplete {
                    runChain(.breakChain(reason, now: now()))
                }
            case .sample(let sample, let ptsUs, let keyframe):
                let paced = PacedSample(sample: sample, ptsUs: ptsUs, keyframe: keyframe)
                if strategy.present == .paced, !isPaused {
                    runPresenter(.arrive(paced, isKeyframe: keyframe))
                } else {
                    handToLayer(paced, renderer: renderer)
                }
            }
        }
    }

    /// The one place a frame reaches the display layer, in both modes. The
    /// stats hand-off is here, so paced presentation shows its added delay.
    private func handToLayer(_ item: PacedSample, renderer: AVSampleBufferVideoRenderer) {
        if renderer.status == .failed || renderer.requiresFlushToResumeDecoding {
            if samplesSinceFlush > 0 { onFrameDiscarded?(.flush) }
            samplesSinceFlush = 0
            renderer.flush()
            if framesDrained > 0 { runChain(.breakChain(.flush, now: now())) }
        }
        let wasAwaiting = chain.isAwaitingKey
        for action in chain.handle(.sample(isKeyframe: item.keyframe, now: now())) {
            switch action {
            case .feed:
                // A delta in a broken chain is the ISS-54 corruption; the
                // guard never returns one, so a count here is a gate bug.
                if wasAwaiting && !item.keyframe { onChainFed?() }
                feedToLayer(item, renderer: renderer)
            case .drop:
                // Held: the last good picture stays up (a freeze, no garbage).
                onFrameDiscarded?(.awaitingKey)
            default:
                perform(action)
            }
        }
    }

    private func feedToLayer(_ item: PacedSample, renderer: AVSampleBufferVideoRenderer) {
        if !renderer.isReadyForMoreMediaData { onFrameDiscarded?(.notReady) }
        renderer.enqueue(item.sample)
        samplesSinceFlush += 1
        framesDrained += 1
        frameStamp &+= 1
        onFrameEnqueued?(item.ptsUs)
        if renderer.status == .failed {
            Log.video.error("display layer failed; flush + keyframe")
            renderer.flush()
            runChain(.breakChain(.layerFailed, now: now()))
        }
    }

    private func now() -> TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }

    /// Feeds the chain machine and performs its actions. Main-thread only,
    /// like every display-layer call.
    private func runChain(_ event: ChainGuard.Event) {
        for action in chain.handle(event) { perform(action) }
    }

    private func perform(_ action: ChainGuard.Action) {
        switch action {
        case .logBroken(let reason):
            Log.video.notice("chain broken reason=\(reason.rawValue, privacy: .public)")  // log-ok: a closed token
        case .logRestored(let ms):
            Log.video.notice("chain restored after \(ms, privacy: .public)")  // log-ok: a duration
        case .requestKeyframe:
            onRequestKeyframe?()
        case .scheduleRetry:
            scheduleChainRetry()
        case .cancelRetry:
            chainRetry?.cancel()
            chainRetry = nil
        case .feed, .drop:
            break
        }
    }

    private func scheduleChainRetry() {
        chainRetry?.cancel()
        chainRetry = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(ChainGuard.retryDelay))
            guard !Task.isCancelled, let self else { return }
            self.chainRetry = nil
            self.runChain(.retryDue)
        }
    }

    // MARK: Paced presentation (M1)

    /// Feeds the presenter and performs its actions. The transition log is
    /// info at the queue's start and end, debug inside it: a tick's show would
    /// otherwise write 60 lines a second.
    private func runPresenter(_ event: PacedPresenter<PacedSample>.Event) {
        let before = presenter.phase
        let actions = presenter.handle(event)
        let after = presenter.phase
        logPresenter(before, event, after)
        var linkFailed = false
        for action in actions {
            switch action {
            case .startLink:
                linkFailed = !startPacedLink()
            case .stopLink:
                stopPacedLink()
            case .caughtUp(let skipped):
                // Shown without their own refresh, but decoded: the chain
                // holds and no keyframe is asked for.
                for _ in 0..<skipped { onFrameDiscarded?(.paced) }
            case .show(let item):
                handToLayer(item, renderer: displayLayer().sampleBufferRenderer)
            }
        }
        // A view not in a window yet has no display link: show what waits now
        // rather than hold frames no refresh will ever release.
        if linkFailed { drainPresenterNow() }
    }

    /// Shows everything waiting, in order: the immediate path when a paced
    /// queue is switched off, and the fallback when no display link exists.
    private func drainPresenterNow() {
        while presenter.hasWaiting {
            runPresenter(.tick)
        }
    }

    @discardableResult
    private func startPacedLink() -> Bool {
        if pacedLink != nil { return true }
        guard window != nil else { return false }
        let link = displayLink(target: self, selector: #selector(pacedTick(_:)))
        link.add(to: .main, forMode: .common)
        pacedLink = link
        return true
    }

    private func stopPacedLink() {
        pacedLink?.invalidate()
        pacedLink = nil
    }

    @objc private func pacedTick(_ link: CADisplayLink) {
        // Nothing waiting: no queue work at all this refresh (the link stays up
        // until the window pauses or closes, as the strategy says).
        guard presenter.hasWaiting || presenter.phase != .idle else { return }
        runPresenter(.tick)
    }

    private func logPresenter(_ before: PacedPresenter<PacedSample>.Phase,
                              _ event: PacedPresenter<PacedSample>.Event,
                              _ after: PacedPresenter<PacedSample>.Phase) {
        guard before != after else { return }
        let line = "paced: \(before.token) --\(event.token)--> \(after.token)"
        if before == .idle || after == .idle {
            Log.video.info("\(line, privacy: .public)")  // log-ok: closed state tokens
        } else {
            Log.video.debug("\(line, privacy: .public)")  // log-ok: closed state tokens
        }
    }

    /// WIN-63: a config byte for byte equal to the applied one (an older
    /// phone forwards the encoder's per-frame statistics as a new format)
    /// keeps the decoder and its reference chain: no flush, no chain break,
    /// no keyframe request. Anything else flushes.
    static func configNeedsFlush(applied: VideoConfig?, next: VideoConfig) -> Bool {
        applied != next
    }

    static func makeFormatDescription(_ config: VideoConfig) -> CMVideoFormatDescription? {
        guard let codec = VideoCodec(rawValue: config.codec) else { return nil }
        return makeFormatDescription(config, codec: codec)
    }

    static func makeFormatDescription(_ config: VideoConfig,
                                      codec: VideoCodec) -> CMVideoFormatDescription? {
        switch codec {
        case .avc:
            guard let (sps, pps) = AnnexB.parameterSets(from: config.parameterSets) else { return nil }
            return makeFormatDescription(sps: sps, pps: pps)
        case .hevc:
            guard let sets = AnnexB.hevcParameterSets(from: config.parameterSets) else { return nil }
            return makeHEVCFormatDescription(vps: sets.vps, sps: sets.sps, pps: sets.pps)
        }
    }

    private static func makeFormatDescription(sps: [UInt8], pps: [UInt8]) -> CMVideoFormatDescription? {
        var format: CMVideoFormatDescription?
        let status = sps.withUnsafeBufferPointer { spsBuffer in
            pps.withUnsafeBufferPointer { ppsBuffer in
                CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: 2,
                    parameterSetPointers: [spsBuffer.baseAddress!, ppsBuffer.baseAddress!],
                    parameterSetSizes: [sps.count, pps.count],
                    nalUnitHeaderLength: 4,
                    formatDescriptionOut: &format)
            }
        }
        return status == noErr ? format : nil
    }

    private static func makeHEVCFormatDescription(vps: [UInt8], sps: [UInt8],
                                                  pps: [UInt8]) -> CMVideoFormatDescription? {
        var format: CMVideoFormatDescription?
        let status = vps.withUnsafeBufferPointer { vpsBuffer in
            sps.withUnsafeBufferPointer { spsBuffer in
                pps.withUnsafeBufferPointer { ppsBuffer in
                    CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                        allocator: kCFAllocatorDefault,
                        parameterSetCount: 3,
                        parameterSetPointers: [vpsBuffer.baseAddress!, spsBuffer.baseAddress!,
                                               ppsBuffer.baseAddress!],
                        parameterSetSizes: [vps.count, sps.count, pps.count],
                        nalUnitHeaderLength: 4,
                        extensions: nil,
                        formatDescriptionOut: &format)
                }
            }
        }
        return status == noErr ? format : nil
    }

    static func makeSampleBuffer(avcc: [UInt8], format: CMVideoFormatDescription,
                                 ptsUs: UInt64) -> CMSampleBuffer? {
        let count = avcc.count
        var blockBuffer: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: count,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
            dataLength: count, flags: 0, blockBufferOut: &blockBuffer) == noErr,
            let block = blockBuffer else { return nil }

        let copyStatus = avcc.withUnsafeBytes { raw -> OSStatus in
            CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: block,
                                          offsetIntoDestination: 0, dataLength: count)
        }
        guard copyStatus == noErr else { return nil }

        // The phone stamps frames with its own uptime, which has no relation to
        // this Mac's host clock (the layer's default timebase) and drifts from
        // it whenever either side sleeps. A frame stamped in the host clock's
        // future is held until then, so the window stays black, or repaints
        // only now and then. Present every frame at the host time it arrives;
        // the phone's PTS only kept them ordered, which arrival order already is.
        _ = ptsUs
        var timing = CMSampleTimingInfo(duration: .invalid,
                                        presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
                                        decodeTimeStamp: .invalid)
        var sampleSize = count
        var sampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block,
                                        formatDescription: format, sampleCount: 1,
                                        sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                        sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize,
                                        sampleBufferOut: &sampleBuffer) == noErr,
              let sample = sampleBuffer else { return nil }

        // DisplayImmediately is a per-sample attachment: set on the buffer
        // itself (CMSetAttachment) the renderer does not read it.
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict,
                                 Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return sample
    }

    /// The sample's own DisplayImmediately attachment, for K2: both paths
    /// (arrival and paced) hand the layer samples built here.
    static func carriesDisplayImmediately(_ sample: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false),
              CFArrayGetCount(attachments) > 0 else { return false }
        let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFDictionary.self)
        guard let value = CFDictionaryGetValue(
            dictionary,
            Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque())
        else { return false }
        return CFBooleanGetValue(unsafeBitCast(value, to: CFBoolean.self))
    }

    // MARK: Events

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        // A press on the picture is a touch on the phone: the keyboard belongs
        // to the phone again, not to the bar (MIRROR-13).
        onPointerDown?()
        inputMapper?.mouseDown(event)
    }

    override func mouseDragged(with event: NSEvent) { inputMapper?.mouseDragged(event) }
    override func mouseUp(with event: NSEvent) { inputMapper?.mouseUp(event) }
    override func rightMouseDown(with event: NSEvent) { inputMapper?.rightMouseDown(event) }
    override func rightMouseDragged(with event: NSEvent) { inputMapper?.rightMouseDragged(event) }
    override func rightMouseUp(with event: NSEvent) { inputMapper?.rightMouseUp(event) }
    override func otherMouseDown(with event: NSEvent) { inputMapper?.otherMouseDown(event) }
    // An extra button held down only drags and releases from here: the nav
    // fired on the down must not repeat and none of it may become a touch.
    override func otherMouseDragged(with event: NSEvent) {}
    override func otherMouseUp(with event: NSEvent) {}
    override func keyDown(with event: NSEvent) {
        // The mode's own keys (Esc, ⌘C) are read by a local monitor while it
        // is on; the mapper's gate drops everything else.
        inputMapper?.keyDown(event)
    }
    override func keyUp(with event: NSEvent) { inputMapper?.keyUp(event) }

    // Mouse utilities deliver a side Back button as a swipe event rather than
    // otherMouseDown (deltaX = +1 back, −1 forward stays inert).
    override func swipe(with event: NSEvent) { inputMapper?.swipe(deltaX: event.deltaX) }

    // MARK: Trackpad fingers

    override func touchesBegan(with event: NSEvent) { reportTouches(of: event) }
    override func touchesMoved(with event: NSEvent) { reportTouches(of: event) }
    override func touchesEnded(with event: NSEvent) { reportTouches(of: event) }
    override func touchesCancelled(with event: NSEvent) { reportTouches(of: event) }

    private var seenIndirectTouches = false

    private func reportTouches(of event: NSEvent) {
        let touching = event.touches(matching: .touching, in: self).filter { $0.type == .indirect && !$0.isResting }
        if !seenIndirectTouches, !touching.isEmpty {
            seenIndirectTouches = true
            Log.input.info("trackpad touches reach the stream view: pinch and rotate use the raw fingers")
        }
        let surface = touching.first.map {
            TrackpadSurface(widthPoints: Double($0.deviceSize.width), heightPoints: Double($0.deviceSize.height))
        } ?? .fallback
        let fingers = touching.map {
            TrackpadFinger(id: $0.identity.hash, x: Double($0.normalizedPosition.x), y: Double($0.normalizedPosition.y))
        }
        trackpadFingers(fingers, surface: surface, cursor: cursorLocation())
    }

    private func cursorLocation() -> CGPoint {
        guard let window else { return .zero }
        return convert(window.mouseLocationOutsideOfEventStream, from: nil)
    }

    /// The scripted-input driver reaches the same path with a model of the
    /// fingers, since AppKit cannot synthesize NSTouch events.
    func trackpadFingers(_ fingers: [TrackpadFinger], surface: TrackpadSurface, cursor: CGPoint) {
        inputMapper?.trackpadFingers(fingers, surface: surface, cursor: cursor)
    }

    /// The window lost focus: a gesture in flight must not outlive it.
    func windowResignedKey() {
        inputMapper?.hoverExit()
        inputMapper?.cancelTrackpadGestures()
    }

    // MARK: Show Touches

    /// View → Show Touches: a dot where the phone is being touched by a
    /// trackpad gesture.
    var showsTouches = false {
        didSet {
            guard !showsTouches else { return }
            showTouchPoints([])
        }
    }

    private var touchDots: [UInt8: CALayer] = [:]
    private static let dotSize: CGFloat = 34

    /// The dots changed (the chrome state records how many are up).
    var onTouchDotsChanged: (() -> Void)?

    /// `points` are normalized video coordinates; none removes every dot.
    func showTouchPoints(_ points: [InputMapper.TouchPoint]) {
        let shown = showsTouches ? points : []
        let live = Set(shown.map(\.id))
        for (id, dot) in touchDots where !live.contains(id) {
            touchDots[id] = nil
            fadeOut(dot)
        }
        let rect = videoRect()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for point in shown {
            let dot = touchDots[point.id] ?? makeDot(id: point.id)
            dot.position = Letterbox.viewPoint(nx: point.nx, ny: point.ny, videoRect: rect, flipped: isFlipped)
            dot.opacity = 1
        }
        CATransaction.commit()
        onTouchDotsChanged?()
    }

    private func makeDot(id: UInt8) -> CALayer {
        let dot = CALayer()
        dot.bounds = CGRect(x: 0, y: 0, width: Self.dotSize, height: Self.dotSize)
        dot.cornerRadius = Self.dotSize / 2
        dot.backgroundColor = NSColor.white.withAlphaComponent(0.32).cgColor
        dot.borderColor = NSColor.white.withAlphaComponent(0.85).cgColor
        dot.borderWidth = 1.5
        dot.shadowColor = NSColor.black.cgColor
        dot.shadowOpacity = 0.25
        dot.shadowRadius = 3
        dot.shadowOffset = .zero
        dot.zPosition = 20
        (touchDotHost ?? layer)?.addSublayer(dot)
        touchDots[id] = dot
        return dot
    }

    private func fadeOut(_ dot: CALayer) {
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = dot.opacity
        fade.toValue = 0
        fade.duration = 0.2
        dot.opacity = 0
        CATransaction.begin()
        CATransaction.setCompletionBlock { dot.removeFromSuperlayer() }
        dot.add(fade, forKey: "fadeOut")
        CATransaction.commit()
    }

    // MARK: Trackpad gestures

    // AppKit has no public way to synthesize a magnify/rotate NSEvent, so the
    // scripted-input driver calls these seams; the overrides below only unwrap
    // the event (location conversion included).

    func magnifyGesture(phase: NSEvent.Phase, magnification: Double, at point: CGPoint) {
        inputMapper?.magnify(phase: phase, magnification: CGFloat(magnification), at: point)
    }

    func rotateGesture(phase: NSEvent.Phase, rotation: Double, at point: CGPoint) {
        inputMapper?.rotate(phase: phase, rotation: CGFloat(rotation), at: point)
    }

    func smartMagnifyGesture(at point: CGPoint) {
        inputMapper?.smartMagnify(at: point)
    }

    override func magnify(with event: NSEvent) {
        magnifyGesture(phase: event.phase, magnification: Double(event.magnification),
                       at: convert(event.locationInWindow, from: nil))
    }

    override func rotate(with event: NSEvent) {
        rotateGesture(phase: event.phase, rotation: Double(event.rotation),
                      at: convert(event.locationInWindow, from: nil))
    }

    override func smartMagnify(with event: NSEvent) {
        smartMagnifyGesture(at: convert(event.locationInWindow, from: nil))
    }

    // MARK: Edge swipe

    /// Two-finger trackpad scrolls arrive with phases; only a gesture that
    /// starts in the left 24 pt is considered, and a mostly-vertical one falls
    /// back to plain scrolling. Momentum and phase-less (wheel) events pass
    /// straight through to the app.
    override func scrollWheel(with event: NSEvent) {
        if trackEdgeSwipe(event) { return }
        inputMapper?.scrollWheel(event)
    }

    /// Returns true when the event was consumed by the back gesture.
    private func trackEdgeSwipe(_ event: NSEvent) -> Bool {
        if event.phase.contains(.began) {
            let point = convert(event.locationInWindow, from: nil)
            edgeSwipeTracking = edgeSwipe.begin(at: point, in: bounds)
            return edgeSwipeTracking
        }
        if event.phase.contains(.changed) {
            guard edgeSwipeTracking else { return false }
            switch edgeSwipe.update(horizontal: event.scrollingDeltaX, vertical: event.scrollingDeltaY) {
            case .trigger:
                flashEdgeHint()
                inputMapper?.edgeSwipeBack()
                return true
            case .hold:
                return true
            case .passThrough, .ignore:
                edgeSwipeTracking = false
                return false
            }
        }
        if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
            let wasTracking = edgeSwipeTracking
            edgeSwipe.end()
            edgeSwipeTracking = false
            return wasTracking
        }
        return false
    }

    private func installEdgeHint() {
        let size = CGSize(width: 14, height: 26)
        let path = CGMutablePath()
        path.move(to: CGPoint(x: size.width, y: 0))
        path.addLine(to: CGPoint(x: 0, y: size.height / 2))
        path.addLine(to: CGPoint(x: size.width, y: size.height))
        edgeHint.path = path
        edgeHint.bounds = CGRect(origin: .zero, size: size)
        edgeHint.position = CGPoint(x: 4, y: bounds.midY)
        edgeHint.strokeColor = NSColor.white.withAlphaComponent(0.9).cgColor
        edgeHint.fillColor = nil
        edgeHint.lineWidth = 3
        edgeHint.lineCap = .round
        edgeHint.lineJoin = .round
        edgeHint.opacity = 0
        edgeHint.zPosition = 10
        layer?.addSublayer(edgeHint)
    }

    /// 150 ms slide-in chevron: feedback that the swipe was taken as back.
    private func flashEdgeHint() {
        if edgeHint.superlayer == nil { layer?.addSublayer(edgeHint) }
        edgeHint.removeAnimation(forKey: "edgeSwipeHint")
        let from = CGPoint(x: 2, y: bounds.midY)
        let to = CGPoint(x: 34, y: bounds.midY)
        edgeHint.position = to
        let slide = CABasicAnimation(keyPath: "position")
        slide.fromValue = NSValue(point: from)
        slide.toValue = NSValue(point: to)
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [0.0, 1.0, 1.0, 0.0]
        fade.keyTimes = [0, 0.2, 0.7, 1]
        let group = CAAnimationGroup()
        group.animations = [slide, fade]
        group.duration = 0.15
        edgeHint.add(group, forKey: "edgeSwipeHint")
    }
}
