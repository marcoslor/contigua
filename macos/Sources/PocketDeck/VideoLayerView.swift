// Hardware H.264 rendering: AVSampleBufferDisplayLayer fed with CMSampleBuffers.
// No CPU readback, no CGImage/NSImage, no draw(_:) — that path is what made the
// prototype feel laggy. All sample-buffer work happens on a dedicated serial
// queue; the layer only ever sees ready-to-enqueue buffers in order.

import AVFoundation
import AppKit

final class VideoLayerView: NSView {
    private let displayLayer = AVSampleBufferDisplayLayer()
    private let videoQueue = DispatchQueue(label: "dev.pocketdeck.video")
    /// Touched only on `videoQueue`.
    private var formatDescription: CMVideoFormatDescription?
    private var lastPtsUs: UInt64 = 0

    /// Size (px) of the picture the window shows: the frame's picture rect of the last
    /// VIDEO_CONFIG. Drives aspect-fit letterboxing, the window's aspect and the input map.
    private(set) var videoSize: CGSize = .zero

    /// Size (px) of the whole frame of the last VIDEO_CONFIG, and where the picture is in it
    /// (window.content). A frame may carry a band outside its picture, which is never drawn.
    private(set) var frameSize: CGSize = .zero
    private var picture = PictureRect.full(width: 0, height: 0)

    /// Clips the display layer to the drawn picture (PictureCrop.swift).
    private let pictureClip = CALayer()

    /// The phone window mirrors a fixed screen: its letterbox is never filled
    /// (Letterbox.placement). The app window's is.
    var isPhoneMode = false

    /// When the window last asked for a new size; until a config at that size
    /// arrives (or this passes) the last frame fills the view.
    private var resizeFillUntil: TimeInterval?
    private var resizeTimeout: DispatchWorkItem?

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

    /// All AppKit events are handed to this mapper.
    var inputMapper: InputMapper?

    /// Where the Show Touches dots are drawn. The chrome sets this to a layer
    /// of its own, outside the extension view's mirror: a dot inside the
    /// mirrored content would be reflected into the framed bar. nil draws on
    /// the video's own layer (no chrome: tests and previews).
    var touchDotHost: CALayer?

    /// The window's own pointer feed already reports every move (the immersive
    /// dwell feed), so the tracking area leaves hover to it.
    var hoverFeedActive: () -> Bool = { false }

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

    var isPaused = false

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
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = NSColor.black.cgColor
        layer?.backgroundColor = NSColor.black.cgColor
        pictureClip.masksToBounds = true
        layer?.addSublayer(pictureClip)
        pictureClip.addSublayer(displayLayer)
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
        guard !hoverFeedActive() else { return }
        hoverPointerMoved(toWindowPoint: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) { inputMapper?.hoverExit() }

    /// The scripted driver's `hover`/`hoverout` and the immersive dwell feed
    /// reach the same decision: the pill is Mac UI, the rest is the phone.
    func hoverPointerMoved(toWindowPoint point: CGPoint) {
        if macUIAtWindowPoint?(point) == true {
            inputMapper?.hoverExit()
        } else {
            inputMapper?.hoverMove(at: point)
        }
    }

    /// The window went away: the phone must not keep a hover it cannot end.
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { inputMapper?.hoverExit() }
        super.viewWillMove(toWindow: newWindow)
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
        noteResizeRequested()
    }

    /// The display layer follows the view exactly. A plain `frame = bounds` in
    /// a resize is an implicit ~0.25 s CALayer animation (the layer's delegate
    /// is nil), so the picture trails the window edge on a fast drag and the
    /// new area shows the layer's black background: the reported black bands.
    private func placeDisplayLayer() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pictureClip.frame = videoRect()
        displayLayer.frame = frameSize.width > 0
            ? PictureCrop.layerFrame(frame: frameSize, content: picture, picture: pictureClip.bounds.size)
            : pictureClip.bounds
        CATransaction.commit()
    }

    /// The display layer, for the resize tests: after a size change it must
    /// have no animation and its presentation frame must be the new bounds.
    var displayLayerForTesting: AVSampleBufferDisplayLayer { displayLayer }

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
        let animating = !(displayLayer.animationKeys()?.isEmpty ?? true)
        let layerRect = animating ? (displayLayer.presentation()?.frame ?? displayLayer.frame) : displayLayer.frame
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
        let gravity = Self.gravity(for: placement())
        if displayLayer.videoGravity != gravity { displayLayer.videoGravity = gravity }
    }

    private func placement() -> Letterbox.Placement {
        Letterbox.placement(video: videoSize, bounds: bounds.size,
                            resizePending: resizeIsPending, phoneMode: isPhoneMode)
    }

    /// The gravity that draws `placement`.
    static func gravity(for placement: Letterbox.Placement) -> AVLayerVideoGravity {
        switch placement {
        case .fit: return .resizeAspect
        case .fill: return .resizeAspectFill
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

    /// A resize is pending while the window has asked and the last frame is not
    /// the size it asked for.
    private var resizeIsPending: Bool {
        guard let until = resizeFillUntil, ProcessInfo.processInfo.systemUptime < until else { return false }
        return Letterbox.resizeStillPending(video: videoSize, request: requestedPixels,
                                            liveResizing: isWindowLiveResizing || window?.inLiveResize == true)
    }

    /// What the window's own size asks the phone for (the same number
    /// `window.resize` carries).
    private var requestedPixels: CGSize {
        let scale = Double(window?.backingScaleFactor ?? 1)
        return VideoSize.displayPixels(bounds: bounds.size, backingScale: scale)
    }

    /// Drawn rect of the current video inside the view: the same rule as the
    /// gravity, so a click lands on the pixel under the pointer, even mid-resize.
    func videoRect() -> CGRect {
        guard videoSize.width > 0, videoSize.height > 0 else { return bounds }
        return Letterbox.videoRect(video: videoSize, in: bounds, placement: placement())
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
        let renderer = displayLayer.sampleBufferRenderer
        let timebase = renderer.timebase
        let rate = CMTimebaseGetRate(timebase)
        if rate != 0 { CMTimebaseSetRate(timebase, rate: 0) }
        defer { if rate != 0 { CMTimebaseSetRate(timebase, rate: rate) } }
        return renderer.displayedPixelBuffer()
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
        let renderer = displayLayer.sampleBufferRenderer
        let rate = CMTimebaseGetRate(renderer.timebase)
        let visible = window?.isVisible ?? false
        let occluded = !(window?.occlusionState.contains(.visible) ?? false)
        return "renderer=\(renderer.status.rawValue) rate=\(rate) ready=\(renderer.isReadyForMoreMediaData)"
            + " bounds=\(Int(bounds.width))x\(Int(bounds.height)) video=\(Int(videoSize.width))x\(Int(videoSize.height))"
            + " window=\(visible) occluded=\(occluded) paused=\(isPaused)"
    }

    func configure(_ config: VideoConfig, picture: PictureRect) {
        guard let format = Self.makeFormatDescription(config) else {
            Log.video.error("VIDEO_CONFIG without SPS/PPS")
            onRequestKeyframe?()
            return
        }
        let size = CGSize(width: CGFloat(config.width), height: CGFloat(config.height))
        videoQueue.async { [weak self] in
            guard let self else { return }
            self.formatDescription = format
            self.lastPtsUs = 0
            // The flush rides the same ordered hand-off as the samples, so a
            // drain can never put new-format samples ahead of it.
            self.handOff(.flush)
            DispatchQueue.main.async {
                self.frameSize = size
                self.picture = picture
                self.videoSize = picture.size
                // The phone answered at the size the window asked for: the
                // fill (if one was up) ends now, before the timeout.
                if self.resizeFillUntil != nil,
                   Letterbox.answers(config: size, request: self.requestedPixels) {
                    self.resizeFillUntil = nil
                    self.resizeTimeout?.cancel()
                    self.resizeTimeout = nil
                }
                self.updateGravity()
                self.needsLayout = true
                self.needsDisplay = true
                NotificationCenter.default.post(name: Self.videoSizeDidChange, object: self)
                self.liveText.noteStreamConfig(size: picture.size)
            }
        }
    }

    func enqueue(_ frame: VideoFrameData) {
        videoQueue.async { [weak self] in
            guard let self else { return }
            // Every stream sends VIDEO_CONFIG before its frames; without one
            // there is nothing to decode.
            guard let format = self.formatDescription else { return }
            let avcc = AnnexB.avcc(fromAnnexB: frame.annexB)
            guard !avcc.isEmpty else { return }
            let pts = max(frame.ptsUs, self.lastPtsUs &+ 1)
            self.lastPtsUs = pts
            guard let sample = Self.makeSampleBuffer(avcc: avcc, format: format, ptsUs: pts) else { return }
            self.snapshotter?.feed(sample)
            // The byte work above is the expensive part and stays off the main
            // thread, but CALayer is main-thread-only: reading or mutating the
            // display layer from here is undefined and leaves it accepting
            // buffers it never composites (the window stays black until a resize
            // dirties the layer). Hand the finished buffer over and enqueue there.
            self.handOff(.sample(sample))
        }
    }

    private enum PendingVideo {
        case flush
        case sample(CMSampleBuffer)
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
        let renderer = displayLayer.sampleBufferRenderer
        for item in items {
            switch item {
            case .flush:
                renderer.flush()
            case .sample(let sample):
                if renderer.status == .failed || renderer.requiresFlushToResumeDecoding {
                    renderer.flush()
                }
                renderer.enqueue(sample)
                framesDrained += 1
                if renderer.status == .failed {
                    Log.video.error("display layer failed; flush + keyframe")
                    renderer.flush()
                    onRequestKeyframe?()
                }
            }
        }
    }

    private static func makeFormatDescription(_ config: VideoConfig) -> CMVideoFormatDescription? {
        guard let (sps, pps) = AnnexB.parameterSets(from: config.parameterSets) else { return nil }
        return makeFormatDescription(sps: sps, pps: pps)
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

    private static func makeSampleBuffer(avcc: [UInt8], format: CMVideoFormatDescription,
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
