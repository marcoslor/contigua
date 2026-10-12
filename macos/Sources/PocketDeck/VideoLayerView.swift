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

    /// The decoder needs an IDR (window.keyframe) when the layer fails.
    var onRequestKeyframe: (() -> Void)?

    /// All AppKit events are handed to this mapper.
    var inputMapper: InputMapper?

    var isPaused = false

    /// Height (pt) of the top strip that reveals hover chrome (0 = disabled).
    var hoverZoneHeight: CGFloat = 0
    var onHoverChange: ((Bool) -> Void)?
    private var hoverTrackingArea: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = NSColor.black.cgColor
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.addSublayer(displayLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { false }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func layout() {
        super.layout()
        displayLayer.frame = bounds
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
    override func scrollWheel(with event: NSEvent) { inputMapper?.scrollWheel(event) }
    override func keyDown(with event: NSEvent) { inputMapper?.keyDown(event) }
    override func keyUp(with event: NSEvent) { inputMapper?.keyUp(event) }

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
