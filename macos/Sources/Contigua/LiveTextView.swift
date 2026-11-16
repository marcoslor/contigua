// Live Text mode's views (docs/design/livetext.md): the frame the display layer
// is showing, frozen into an image view, with VisionKit's
// ImageAnalysisOverlayView on top of it. The state machine is LiveTextMode;
// this file owns the pixel work and the overlay, the window controller owns
// pausing the phone and the chrome/menu state.
//
// The frame route is AVSampleBufferVideoRenderer.copyDisplayedPixelBuffer()
// (macOS 14.4+), read once per entry on the main thread. Nothing is read back
// on the normal path; nothing here logs text, pixels or file names.

import AppKit
import CoreImage
import CoreVideo
import ImageIO
import UniformTypeIdentifiers
import VideoToolbox
import VisionKit

/// Pixel-buffer to image helpers, shared by the freeze image, copy and drag.
enum LiveTextImage {
    /// CI's renderer keeps its own caches; one context is enough and is safe to
    /// use from the main thread only (all callers are).
    private static let context = CIContext(options: nil)

    static func cgImage(_ buffer: CVPixelBuffer) -> CGImage? {
        let image = CIImage(cvPixelBuffer: buffer)
        return context.createCGImage(image, from: image.extent)
    }

    static func nsImage(_ buffer: CVPixelBuffer) -> NSImage? {
        guard let cg = cgImage(buffer) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    /// PNG bytes of an already rasterised frame.
    static func pngData(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    static func pngData(_ buffer: CVPixelBuffer) -> Data? {
        guard let cg = cgImage(buffer) else { return nil }
        return pngData(cg)
    }

    /// A private 32BGRA copy of `buffer`, on the CPU side.
    ///
    /// The display layer's displayed buffer is a surface of its own: the
    /// picture renders from it (Metal) but a reader that goes through the
    /// buffer's memory address gets nothing back, which is how Live Text showed
    /// the right frame and recognised 0 characters. The copy is allocated here
    /// and written by the same renderer that draws the frame, so every reader
    /// (VisionKit, the PNG write, the drag) sees the pixels the person sees,
    /// and the layer is free to recycle its own buffer.
    static func snapshot(_ buffer: CVPixelBuffer) -> CVPixelBuffer? {
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        guard width > 0, height > 0, let image = cgImage(buffer) else { return nil }
        let attributes: [String: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
        ]
        var copy: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                  kCVPixelFormatType_32BGRA,
                                  attributes as CFDictionary, &copy) == kCVReturnSuccess,
              let copy else { return nil }
        context.render(CIImage(cgImage: image), to: copy,
                       bounds: CGRect(x: 0, y: 0, width: width, height: height),
                       colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        return copy
    }

    /// The buffer's four-character pixel format ("420v", "BGRA", …), for the
    /// entry diagnostics: a blank frame next time starts with the format.
    static func pixelFormat(_ buffer: CVPixelBuffer) -> String {
        let code = CVPixelBufferGetPixelFormatType(buffer)
        let bytes = [UInt8((code >> 24) & 0xFF), UInt8((code >> 16) & 0xFF),
                     UInt8((code >> 8) & 0xFF), UInt8(code & 0xFF)]
        let text = String(bytes: bytes, encoding: .ascii) ?? "?"
        return text.trimmingCharacters(in: .whitespaces)
    }

    /// Mean luma, 0–255 (one number, never pixels): a frame that arrives blank
    /// is visible in the person's log next time.
    static func meanLuma(_ buffer: CVPixelBuffer) -> Double {
        let image = CIImage(cvPixelBuffer: buffer)
        guard !image.extent.isEmpty,
              let filter = CIFilter(name: "CIAreaAverage",
                                    parameters: [kCIInputImageKey: image,
                                                 kCIInputExtentKey: CIVector(cgRect: image.extent)]),
              let average = filter.outputImage else { return -1 }
        var pixel = [UInt8](repeating: 0, count: 4)
        context.render(average, toBitmap: &pixel, rowBytes: 4,
                       bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                       format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        return 0.2126 * Double(pixel[0]) + 0.7152 * Double(pixel[1]) + 0.0722 * Double(pixel[2])
    }
}

/// Route two for the frozen frame: decode the phone's next keyframe with a
/// VTDecompressionSession of its own, only while a snapshot is pending. The
/// display layer's own pixel output is unavailable when the window is occluded
/// (a quiet e2e run, a half-covered window), and a keyframe decodes to the same
/// picture the phone is sending.
final class KeyframeSnapshotter {
    private let lock = NSLock()
    private var session: VTDecompressionSession?
    private var handler: ((CVPixelBuffer?, FrameStamp?) -> Void)?
    private var finished = true
    /// Samples counted at or before this seq are from before the request.
    private var after = 0
    /// A keyframe from after the request has been fed; deltas may follow it.
    private var started = false

    /// Prepares a decoder for `format`; `handler` gets the first decoded frame
    /// and its stamp (MCP-20) on an arbitrary queue (the video view hops to
    /// main). With `after`, only a keyframe counted later than that seq starts
    /// the decode (MCP-60: a frame from after the call).
    func begin(format: CMVideoFormatDescription, after: Int = 0,
               handler: @escaping (CVPixelBuffer?, FrameStamp?) -> Void) {
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
        ]
        var session: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault, formatDescription: format,
            decoderSpecification: nil, imageBufferAttributes: attributes as CFDictionary,
            outputCallback: nil, decompressionSessionOut: &session)
        guard status == noErr, let session else {
            handler(nil, nil)
            return
        }
        lock.lock()
        self.session = session
        self.handler = handler
        self.after = after
        self.started = false
        self.finished = false
        lock.unlock()
    }

    /// Feeds one sample (in decode order). Errors are ignored: a frame from
    /// before the requested keyframe cannot decode, and the keyframe follows.
    /// `stamp` is the sample's count; `keyframe` whether it can start a decode.
    func feed(_ sample: CMSampleBuffer, stamp: FrameStamp? = nil, keyframe: Bool = true) {
        lock.lock()
        guard !finished, let session else { lock.unlock(); return }
        if !started {
            guard keyframe, (stamp?.seq ?? Int.max) > after else { lock.unlock(); return }
            started = true
        }
        lock.unlock()
        let status = VTDecompressionSessionDecodeFrame(
            session, sampleBuffer: sample, flags: [._EnableAsynchronousDecompression],
            infoFlagsOut: nil
        ) { [weak self] status, _, image, _, _ in
            guard status == noErr, let image else { return }
            self?.finish(image, stamp: stamp)
        }
        if status != noErr {
            Log.video.debug("livetext: snapshot decode refused (\(status, privacy: .public))")
        }
    }

    func cancel() {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let session = self.session
        self.session = nil
        self.handler = nil
        lock.unlock()
        if let session {
            VTDecompressionSessionInvalidate(session)
        }
    }

    private func finish(_ image: CVPixelBuffer, stamp: FrameStamp?) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let handler = self.handler
        let session = self.session
        self.session = nil
        self.handler = nil
        lock.unlock()
        // Not from inside the decoder callback: the session is released once
        // its queue has drained.
        if let session {
            DispatchQueue.global(qos: .utility).async {
                VTDecompressionSessionWaitForAsynchronousFrames(session)
                VTDecompressionSessionInvalidate(session)
            }
        }
        handler?(image, stamp)
    }
}

/// A window's one snapshot decoder (MCP-60).
final class SnapshotSlot: @unchecked Sendable {
    struct Token: Hashable { let id: Int }
    private let lock = NSLock()
    private var counter = 0
    private var current: KeyframeSnapshotter?

    func reserve() -> Token {
        lock.lock(); defer { lock.unlock() }
        counter += 1
        return Token(id: counter)
    }

    @discardableResult
    func begin(format: CMVideoFormatDescription, after: Int,
               handler: @escaping (CVPixelBuffer?, FrameStamp?) -> Void) -> Token {
        let token = reserve()
        begin(token, format: format, after: after, handler: handler)
        return token
    }

    func begin(_ token: Token, format: CMVideoFormatDescription, after: Int,
               handler: @escaping (CVPixelBuffer?, FrameStamp?) -> Void) {
        current?.cancel()
        let snapshotter = KeyframeSnapshotter()
        current = snapshotter
        snapshotter.begin(format: format, after: after, handler: handler)
    }

    func cancel(_ token: Token) {
        current?.cancel()
        current = nil
    }

    func feed(_ sample: CMSampleBuffer, stamp: FrameStamp?, keyframe: Bool) {
        current?.feed(sample, stamp: stamp, keyframe: keyframe)
    }
}

/// One stream window's Live Text mode: freeze image, analysis overlay and the
/// captured frame.
@MainActor
final class LiveTextSession {
    private(set) var mode = LiveTextMode()
    private(set) var frame: CVPixelBuffer?
    /// VisionKit finished (text may still be empty: an image with no words).
    private(set) var analysisReady = false
    /// The frozen frame's size, pixel format and mean luma (counts only): a
    /// frame that arrives blank is then visible in the person's log.
    struct FrameStats: Equatable {
        let width: Int
        let height: Int
        let format: String
        let mean: Int
    }
    private(set) var frameStats: FrameStats?
    /// Analysis diagnostics (counts only): the characters each attempt read,
    /// how long each took, and the applied analysis's own transcript length.
    /// The scripted check reports them; no text ever leaves this type.
    private(set) var attemptChars: [Int] = []
    private(set) var attemptMs: [Int] = []
    private(set) var analysisChars = 0
    /// Why the last enter did nothing (the scripted check reports it; state
    /// only, never pixels).
    private(set) var lastFailure = ""

    /// What the overlay offers while the mode is up (see init).
    static let interactions: ImageAnalysisOverlayView.InteractionTypes =
        [.textSelection, .dataDetectors, .imageSubject, .visualLookUp]

    /// Every state change, with the reason for a move to idle.
    var onStateChange: ((LiveTextState, LiveTextExitReason?) -> Void)?

    private weak var host: VideoLayerView?
    private let imageView = NSImageView()
    /// The VisionKit overlay, made on the first Live Text entry: an idle
    /// window has no analyser surface behind it, and a closed one drops it
    /// again (WIN-33).
    private var overlayStore: ImageAnalysisOverlayView?

    /// Every interaction the mode promises: the overlay, created now if this
    /// window has not entered the mode yet.
    var overlay: ImageAnalysisOverlayView {
        if let overlayStore { return overlayStore }
        let view = ImageAnalysisOverlayView(frame: .zero)
        view.preferredInteractionTypes = Self.interactions
        view.trackingImageView = imageView
        view.isHidden = true
        view.layer?.zPosition = 6
        host?.addSubview(view)
        overlayStore = view
        return view
    }
    /// A late analysis result from an earlier entry is dropped: the mode may
    /// have been left and entered again while it ran.
    private var generation = 0
    /// Esc and ⌘C while the mode is on. VisionKit's overlay owns the first
    /// responder (it is final, so its keys cannot be subclassed); a local
    /// monitor reads the two keys before AppKit dispatches them, and only
    /// while the mode is up.
    private var keyMonitor: Any?
    private var snapshotTimeout: DispatchWorkItem?

    var state: LiveTextState { mode.state }
    var isActive: Bool { mode.isActive }

    init(host: VideoLayerView) {
        self.host = host
        imageView.imageScaling = .scaleAxesIndependently
        imageView.imageAlignment = .alignCenter
        imageView.isEditable = false
        imageView.animates = false
        imageView.imageFrameStyle = .none
        imageView.layer?.zPosition = 5
        imageView.isHidden = true
        // Every interaction the mode promises (docs/design/livetext.md) is set
        // on the overlay when it is made; the image alone waits here, hidden.
        host.addSubview(imageView)
    }

    /// Enter from the shortcut, the menu or the bar button. A second enter is
    /// ignored; with no displayed frame the window keeps showing live video
    /// and nothing happens.
    @discardableResult
    func enter() -> Bool {
        guard mode.state == .idle else { lastFailure = "already active"; return false }
        guard let host else { lastFailure = "no view"; return false }
        // Route one: the layer's displayed buffer, the exact frame on screen.
        if captureDisplayed(on: host) { return true }
        // Route two: the window is occluded (or the layer has no current
        // buffer), so decode the next keyframe in parallel.
        if lastFailure.isEmpty {
            lastFailure = "waiting for a keyframe: " + host.frameDiagnostics()
        }
        mode.handle(.enter)
        onStateChange?(.capturing, nil)
        host.beginFrameSnapshot { [weak self] buffer, _ in
            guard let self else { return }
            guard self.mode.state == .capturing, let buffer,
                  self.adopt(buffer, source: "a decoded keyframe", on: host) else {
                self.captureFailed()
                return
            }
        }
        let work = DispatchWorkItem { [weak self] in self?.captureFailed() }
        snapshotTimeout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: work)
        return true
    }

    /// Route one, and the frame preparation both routes share. A buffer whose
    /// raster fails falls through to the keyframe route rather than freezing a
    /// blank picture.
    private func captureDisplayed(on host: VideoLayerView) -> Bool {
        guard let displayed = host.copyDisplayedFrame() else { return false }
        return adopt(displayed, source: "the displayed frame", on: host)
    }

    /// Freezes `buffer` after moving it onto our side. What the layer shows is
    /// a GPU surface: it draws correctly but a reader that addresses the
    /// buffer's memory gets no pixels back, so VisionKit found 0 characters on
    /// a frame that was visibly full of text. The snapshot is a 32BGRA buffer
    /// this process owns, and the analysis runs on the rasterised image, so
    /// overlays, PNG copies and the analyser all see the same picture.
    private func adopt(_ buffer: CVPixelBuffer, source: String, on host: VideoLayerView) -> Bool {
        let size = "\(CVPixelBufferGetWidth(buffer))x\(CVPixelBufferGetHeight(buffer))"
        let format = LiveTextImage.pixelFormat(buffer)
        let luma = Int(LiveTextImage.meanLuma(buffer).rounded())
        guard let image = LiveTextImage.cgImage(buffer),
              let snapshot = LiveTextImage.snapshot(buffer) else {
            let why = "did not rasterise"
            lastFailure = "the \(source) \(why) (format=\(format) size=\(size) mean=\(luma))"
            Log.video.error("livetext: \(source, privacy: .public) \(why, privacy: .public) (format=\(format, privacy: .public) size=\(size, privacy: .public) mean=\(luma, privacy: .public))")
            return false
        }
        lastFailure = ""
        freeze(snapshot, image: image, on: host)
        Log.video.notice("livetext: entered on \(source, privacy: .public) (format=\(format, privacy: .public) size=\(size, privacy: .public) mean=\(luma, privacy: .public))")
        return true
    }

    /// The frame is in hand (either route): freeze it, analyze it, put the
    /// overlay up. Internal, so the view-tree test can present a synthetic
    /// frame without a live session (the production entries call it too).
    func freeze(_ buffer: CVPixelBuffer, image: CGImage, on host: VideoLayerView) {
        snapshotTimeout?.cancel()
        snapshotTimeout = nil
        freezeImage(buffer, image: image, on: host)
    }

    private func freezeImage(_ buffer: CVPixelBuffer, image: CGImage, on host: VideoLayerView) {
        if mode.state == .idle { mode.handle(.enter) }
        guard mode.state == .capturing else { return }
        frame = buffer
        frameStats = FrameStats(width: CVPixelBufferGetWidth(buffer),
                                height: CVPixelBufferGetHeight(buffer),
                                format: LiveTextImage.pixelFormat(buffer),
                                mean: Int(LiveTextImage.meanLuma(buffer).rounded()))
        imageView.image = NSImage(cgImage: image,
                                  size: NSSize(width: image.width, height: image.height))
        imageView.isHidden = false
        overlay.isHidden = false
        overlay.analysis = nil
        analysisReady = false
        generation += 1
        layout(in: host.videoRect())
        mode.handle(.frameCaptured)
        onStateChange?(.analyzing, nil)
        host.window?.makeFirstResponder(overlay)
        installKeyMonitor()
        analyze(image, generation: generation)
    }

    /// No frame in time: leave the mode (the window shows live video again).
    private func captureFailed() {
        guard mode.state == .capturing else { return }
        if lastFailure.isEmpty { lastFailure = "no keyframe after 5 s" }
        exit(.captureFailed)
    }

    /// The window closed: drop the frozen frame, the analysis and the overlay's
    /// views, so a closed window keeps no picture (WIN-33).
    func release() {
        generation += 1
        removeKeyMonitor()
        snapshotTimeout?.cancel()
        snapshotTimeout = nil
        frame = nil
        frameStats = nil
        overlayStore?.analysis = nil
        overlayStore?.removeFromSuperview()
        overlayStore = nil
        imageView.image = nil
        imageView.removeFromSuperview()
    }

    /// Leave for any reason; a no-op while idle. The frame and the overlay go
    /// away at once, so the live video is visible again.
    @discardableResult
    func exit(_ reason: LiveTextExitReason) -> Bool {
        guard mode.exit(reason) else { return false }
        generation += 1
        removeKeyMonitor()
        snapshotTimeout?.cancel()
        snapshotTimeout = nil
        host?.cancelFrameSnapshot()
        frame = nil
        frameStats = nil
        attemptChars = []
        attemptMs = []
        analysisChars = 0
        analysisReady = false
        overlay.analysis = nil
        overlay.isHidden = true
        imageView.image = nil
        imageView.isHidden = true
        // The analyser surface goes with the mode: an idle window keeps none.
        if let overlayStore {
            overlayStore.analysis = nil
            if host?.window?.firstResponder === overlayStore { host?.window?.makeFirstResponder(host) }
            overlayStore.removeFromSuperview()
            self.overlayStore = nil
        }
        imageView.removeFromSuperview()
        onStateChange?(.idle, reason)
        Log.video.notice("livetext: left (\(reason.rawValue, privacy: .public))")
        return true
    }

    /// The video rect changed (layout, resize, style): the freeze and the
    /// overlay track the picture the same way the display layer does.
    func layout(in rect: CGRect) {
        guard isActive else { return }
        imageView.frame = rect
        overlay.frame = rect
    }

    /// A new VIDEO_CONFIG: the picture under the overlay may be gone or a
    /// different shape. Leaving drops back to live video.
    func noteStreamConfig(size: CGSize? = nil) {
        // A keyframe request is answered by a fresh encoder, so a config while
        // the snapshot is still on its way is ours, not a window change.
        guard mode.state != .capturing else { return }
        // The answering config can land just after the keyframe it belongs to,
        // i.e. after the freeze: at the frozen picture's own size it is still
        // our request's echo, and leaving would drop the mode the person just
        // entered (16 ms after entering, in one run).
        if let size, let frame,
           CGSize(width: CVPixelBufferGetWidth(frame), height: CVPixelBufferGetHeight(frame)) == size {
            Log.video.notice("livetext: config at the frozen size, kept")
            return
        }
        exit(.streamConfig)
    }

    // MARK: Analysis

    /// Attempts per entry: VisionKit's service answers "no text" now and then
    /// for a frame full of words (the same picture reads on the next call), so
    /// an empty answer is asked again. The count is logged, never the text.
    static let analysisAttempts = 3

    private func analyze(_ image: CGImage, generation: Int) {
        let configuration = ImageAnalyzer.Configuration([.text, .machineReadableCode, .visualLookUp])
        let analyzer = ImageAnalyzer()
        Task { [weak self] in
            var analysis: ImageAnalysis?
            var lastError: Error?
            var attempts = 0
            var chars: [Int] = []
            var timings: [Int] = []
            while attempts < Self.analysisAttempts {
                attempts += 1
                let started = Date()
                do {
                    let result = try await analyzer.analyze(image, orientation: .up,
                                                            configuration: configuration)
                    analysis = result
                    chars.append(result.transcript.count)
                    timings.append(Int(Date().timeIntervalSince(started) * 1000))
                    if result.hasResults(for: .text) { break }
                } catch {
                    lastError = error
                    chars.append(-1)
                    timings.append(Int(Date().timeIntervalSince(started) * 1000))
                }
                if attempts < Self.analysisAttempts {
                    try? await Task.sleep(for: .milliseconds(120))
                }
            }
            let (attemptChars, attemptMs) = (chars, timings)
            await MainActor.run {
                guard let self, self.generation == generation, self.mode.state == .analyzing else { return }
                self.attemptChars = attemptChars
                self.attemptMs = attemptMs
                self.analysisChars = analysis?.transcript.count ?? 0
                if let analysis {
                    self.overlay.analysis = analysis
                    // Entering the mode starts with VisionKit's Live Text button
                    // on: every recognised item is highlighted. The button and
                    // its toggle stay the person's afterwards (set once here,
                    // never re-applied while the mode is up).
                    self.overlay.selectableItemsHighlighted = true
                    // VisionKit re-resolves the interactions when the
                    // highlight flag changes; keep the explicit set.
                    self.overlay.preferredInteractionTypes = LiveTextSession.interactions
                    self.analysisReady = true
                    self.mode.handle(.analysisFinished)
                    self.onStateChange?(.shown, nil)
                    Log.video.notice("livetext: analysis ready, \(analysis.transcript.count, privacy: .public) characters, \(attempts, privacy: .public) attempt(s)")
                    return
                }
                self.analysisReady = true
                self.mode.handle(.analysisFailed)
                self.onStateChange?(.shown, nil)
                let why = lastError?.localizedDescription ?? "no result"
                Log.video.error("livetext: analysis failed (\(why, privacy: .public))")
            }
        }
    }

    /// Esc leaves; ⌘C without a Live Text selection copies the frame (with a
    /// selection VisionKit's own copy runs). True means the key was consumed.
    func handleKey(_ event: NSEvent) -> Bool {
        guard isActive else { return false }
        if event.keyCode == 53 {
            exit(.escape)
            return true
        }
        if event.modifierFlags.contains(.command),
           event.charactersIgnoringModifiers?.lowercased() == "c",
           !overlay.hasActiveTextSelection {
            copyFrameToPasteboard()
            return true
        }
        return false
    }

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handleKey(event) ? nil : event
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    /// VisionKit's supplementary Live Text button state: true from the first
    /// analysis, and whatever the person's toggle made it afterwards.
    var selectableItemsHighlighted: Bool { overlay.selectableItemsHighlighted }

    /// The analysed transcript's length, never the text itself (the debug hook
    /// reports lengths and one token's presence).
    var transcriptLength: Int { overlay.text.count }

    func contains(_ token: String) -> Bool {
        guard !token.isEmpty else { return false }
        return overlay.text.localizedCaseInsensitiveContains(token)
    }

    var hasText: Bool { !overlay.text.isEmpty }

    // MARK: Copy and drag

    /// ⌘C without a selection: the whole frozen frame, PNG and TIFF.
    func copyFrameToPasteboard() {
        guard let frame, let png = LiveTextImage.pngData(frame) else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(png, forType: .png)
        if let image = LiveTextImage.nsImage(frame), let tiff = image.tiffRepresentation {
            pasteboard.setData(tiff, forType: .tiff)
        }
        Log.video.notice("livetext: frame copied (\(png.count, privacy: .public) bytes)")
    }

    /// The bar button's drag: a temporary PNG of the frozen frame, as a file.
    /// nil while the mode is off (nothing to drag).
    func dragFileURL() -> URL? {
        guard isActive, let frame, let png = LiveTextImage.pngData(frame) else { return nil }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Contigua-LiveText", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("window.png")
        do {
            try png.write(to: url, options: .atomic)
        } catch {
            Log.video.error("livetext: could not write the drag file")
            return nil
        }
        return url
    }

    /// `--debug-livetext copy-image`: the frozen frame as PNG on disk. Returns
    /// the byte count, nil when nothing is frozen or the write failed.
    @discardableResult
    func writePNG(to path: String) -> Int? {
        guard isActive, let frame, let png = LiveTextImage.pngData(frame) else { return nil }
        do {
            try png.write(to: URL(fileURLWithPath: path), options: .atomic)
            return png.count
        } catch {
            return nil
        }
    }
}
