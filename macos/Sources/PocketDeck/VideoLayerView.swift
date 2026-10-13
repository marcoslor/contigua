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

    /// Size (px) of the last VIDEO_CONFIG; drives aspect-fit letterboxing.
    private(set) var videoSize: CGSize = .zero

    /// Posted on the main queue once a VIDEO_CONFIG size is applied (object: the view).
    static let videoSizeDidChange = Notification.Name("dev.pocketdeck.videoSizeDidChange")

    /// The decoder needs an IDR (window.keyframe) when the layer fails.
    var onRequestKeyframe: (() -> Void)?

    /// All AppKit events are handed to this mapper.
    var inputMapper: InputMapper?

    var isPaused = false

    /// Height (pt) of the top strip that reveals hover chrome (0 = disabled).
    var hoverZoneHeight: CGFloat = 0
    var onHoverChange: ((Bool) -> Void)?
    private var hoverTrackingArea: NSTrackingArea?

    /// Edge-swipe back gesture (two fingers from the left strip).
    private var edgeSwipe = EdgeSwipeClassifier()
    private var edgeSwipeTracking = false
    private let edgeHint = CAShapeLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = NSColor.black.cgColor
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.addSublayer(displayLayer)
        installEdgeHint()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { false }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func layout() {
        super.layout()
        displayLayer.frame = bounds
        edgeHint.position = CGPoint(x: edgeHint.position.x, y: bounds.midY)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        displayLayer.frame = bounds
    }

    /// Aspect-fit rect of the current video inside the view.
    func videoRect() -> CGRect {
        guard videoSize.width > 0, videoSize.height > 0 else { return bounds }
        return Letterbox.videoRect(video: videoSize, in: bounds)
    }

    // MARK: Video

    func configure(_ config: VideoConfig) {
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
            self.displayLayer.sampleBufferRenderer.flush()
            DispatchQueue.main.async {
                self.videoSize = size
                self.needsLayout = true
                self.needsDisplay = true
                NotificationCenter.default.post(name: Self.videoSizeDidChange, object: self)
            }
        }
    }

    func enqueue(_ frame: VideoFrameData) {
        videoQueue.async { [weak self] in
            guard let self, let format = self.formatDescription else { return }
            let avcc = AnnexB.avcc(fromAnnexB: frame.annexB)
            guard !avcc.isEmpty else { return }
            let pts = max(frame.ptsUs, self.lastPtsUs &+ 1)
            self.lastPtsUs = pts
            guard let sample = Self.makeSampleBuffer(avcc: avcc, format: format, ptsUs: pts) else { return }
            if self.displayLayer.sampleBufferRenderer.status == .failed || self.displayLayer.sampleBufferRenderer.requiresFlushToResumeDecoding {
                self.displayLayer.sampleBufferRenderer.flush()
            }
            self.displayLayer.sampleBufferRenderer.enqueue(sample)
            if self.displayLayer.sampleBufferRenderer.status == .failed {
                Log.video.error("display layer failed; flush + keyframe")
                self.displayLayer.sampleBufferRenderer.flush()
                DispatchQueue.main.async { self.onRequestKeyframe?() }
            }
        }
    }

    private static func makeFormatDescription(_ config: VideoConfig) -> CMVideoFormatDescription? {
        guard let (sps, pps) = AnnexB.parameterSets(from: config.parameterSets) else { return nil }
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

        var timing = CMSampleTimingInfo(duration: .invalid,
                                        presentationTimeStamp: CMTime(value: Int64(ptsUs), timescale: 1_000_000),
                                        decodeTimeStamp: .invalid)
        var sampleSize = count
        var sampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block,
                                        formatDescription: format, sampleCount: 1,
                                        sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                        sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize,
                                        sampleBufferOut: &sampleBuffer) == noErr,
              let sample = sampleBuffer else { return nil }

        CMSetAttachment(sample, key: kCMSampleAttachmentKey_DisplayImmediately,
                        value: kCFBooleanTrue, attachmentMode: kCMAttachmentMode_ShouldPropagate)
        return sample
    }

    // MARK: Events

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        inputMapper?.mouseDown(event)
    }

    override func mouseDragged(with event: NSEvent) { inputMapper?.mouseDragged(event) }
    override func mouseUp(with event: NSEvent) { inputMapper?.mouseUp(event) }
    override func rightMouseDown(with event: NSEvent) { inputMapper?.rightMouseDown(event) }
    override func otherMouseDown(with event: NSEvent) { inputMapper?.otherMouseDown(event) }
    override func keyDown(with event: NSEvent) { inputMapper?.keyDown(event) }
    override func keyUp(with event: NSEvent) { inputMapper?.keyUp(event) }

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

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        guard hoverZoneHeight > 0 else { return }
        let point = convert(event.locationInWindow, from: nil)
        onHoverChange?(point.y > bounds.height - hoverZoneHeight)
    }

    override func mouseExited(with event: NSEvent) {
        guard hoverZoneHeight > 0 else { return }
        onHoverChange?(false)
    }
}
