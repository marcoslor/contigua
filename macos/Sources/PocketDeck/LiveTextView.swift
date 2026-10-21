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

    static func pngData(_ buffer: CVPixelBuffer) -> Data? {
        guard let cg = cgImage(buffer) else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, cg, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
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
    private var handler: ((CVPixelBuffer?) -> Void)?
    private var finished = true

    /// Prepares a decoder for `format`; `handler` gets the first decoded frame
    /// on an arbitrary queue (the video view hops to main).
    func begin(format: CMVideoFormatDescription, handler: @escaping (CVPixelBuffer?) -> Void) {
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
            handler(nil)
            return
        }
        lock.lock()
        self.session = session
        self.handler = handler
        self.finished = false
        lock.unlock()
    }

    /// Feeds one sample (in decode order). Errors are ignored: a frame from
    /// before the requested keyframe cannot decode, and the keyframe follows.
    func feed(_ sample: CMSampleBuffer) {
        lock.lock()
        guard !finished, let session else { lock.unlock(); return }
        lock.unlock()
        let status = VTDecompressionSessionDecodeFrame(
            session, sampleBuffer: sample, flags: [._EnableAsynchronousDecompression],
            infoFlagsOut: nil
        ) { [weak self] status, _, image, _, _ in
            guard status == noErr, let image else { return }
            self?.finish(image)
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

    private func finish(_ image: CVPixelBuffer) {
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
        handler?(image)
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
    /// Why the last enter did nothing (the scripted check reports it; state
    /// only, never pixels).
    private(set) var lastFailure = ""

    /// Every state change, with the reason for a move to idle.
    var onStateChange: ((LiveTextState, LiveTextExitReason?) -> Void)?

    private weak var host: VideoLayerView?
    private let imageView = NSImageView()
    let overlay = ImageAnalysisOverlayView(frame: .zero)
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
        overlay.preferredInteractionTypes = .automatic
        overlay.trackingImageView = imageView
        overlay.isHidden = true
        overlay.layer?.zPosition = 6
        host.addSubview(imageView)
        host.addSubview(overlay)
    }

    /// Enter from the shortcut, the menu or the bar button. A second enter is
    /// ignored; with no displayed frame the window keeps showing live video
    /// and nothing happens.
    @discardableResult
    func enter() -> Bool {
        guard mode.state == .idle else { lastFailure = "already active"; return false }
        guard let host else { lastFailure = "no view"; return false }
        // Route one: the layer's displayed buffer, the exact frame on screen.
        if let displayed = host.copyDisplayedFrame(), let image = LiveTextImage.nsImage(displayed) {
            lastFailure = ""
            freeze(displayed, image: image, on: host)
            Log.video.notice("livetext: entered on the displayed frame")
            return true
        }
        // Route two: the window is occluded (or the layer has no current
        // buffer), so decode the next keyframe in parallel.
        lastFailure = "waiting for a keyframe: " + host.frameDiagnostics()
        mode.handle(.enter)
        onStateChange?(.capturing, nil)
        host.beginFrameSnapshot { [weak self] buffer in
            guard let self else { return }
            guard self.mode.state == .capturing, let buffer,
                  let image = LiveTextImage.nsImage(buffer) else {
                self.captureFailed()
                return
            }
            self.lastFailure = ""
            self.freeze(buffer, image: image, on: host)
            Log.video.notice("livetext: entered on a decoded keyframe")
        }
        let work = DispatchWorkItem { [weak self] in self?.captureFailed() }
        snapshotTimeout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: work)
        return true
    }

    /// The frame is in hand (either route): freeze it, analyze it, put the
    /// overlay up.
    private func freeze(_ buffer: CVPixelBuffer, image: NSImage, on host: VideoLayerView) {
        snapshotTimeout?.cancel()
        snapshotTimeout = nil
        freezeImage(buffer, image: image, on: host)
    }

    private func freezeImage(_ buffer: CVPixelBuffer, image: NSImage, on host: VideoLayerView) {
        if mode.state == .idle { mode.handle(.enter) }
        guard mode.state == .capturing else { return }
        frame = buffer
        imageView.image = image
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
        analyze(buffer, generation: generation)
    }

    /// No frame in time: leave the mode (the window shows live video again).
    private func captureFailed() {
        guard mode.state == .capturing else { return }
        lastFailure = "no keyframe after 5 s"
        exit(.captureFailed)
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
        analysisReady = false
        overlay.analysis = nil
        overlay.isHidden = true
        imageView.image = nil
        imageView.isHidden = true
        if let host {
            overlay.removeFromSuperview()
            imageView.removeFromSuperview()
            host.addSubview(imageView)
            host.addSubview(overlay)
            if host.window?.firstResponder === overlay { host.window?.makeFirstResponder(host) }
        }
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
    func noteStreamConfig() {
        // A keyframe request is answered by a fresh encoder, so a config while
        // the snapshot is still on its way is ours, not a window change.
        guard mode.state != .capturing else { return }
        exit(.streamConfig)
    }

    // MARK: Analysis

    private func analyze(_ buffer: CVPixelBuffer, generation: Int) {
        let configuration = ImageAnalyzer.Configuration([.text, .machineReadableCode, .visualLookUp])
        let analyzer = ImageAnalyzer()
        Task { [weak self] in
            do {
                let analysis = try await analyzer.analyze(buffer, orientation: .up,
                                                          configuration: configuration)
                await MainActor.run {
                    guard let self, self.generation == generation, self.mode.state == .analyzing else { return }
                    self.overlay.analysis = analysis
                    // Entering the mode starts with VisionKit's Live Text button
                    // on: every recognised item is highlighted. The button and
                    // its toggle stay the person's afterwards (set once here,
                    // never re-applied while the mode is up).
                    self.overlay.selectableItemsHighlighted = true
                    self.analysisReady = true
                    self.mode.handle(.analysisFinished)
                    self.onStateChange?(.shown, nil)
                    Log.video.notice("livetext: analysis ready, \(analysis.transcript.count, privacy: .public) characters")
                }
            } catch {
                await MainActor.run {
                    guard let self, self.generation == generation, self.mode.state == .analyzing else { return }
                    self.analysisReady = true
                    self.mode.handle(.analysisFailed)
                    self.onStateChange?(.shown, nil)
                    Log.video.error("livetext: analysis failed (\(error.localizedDescription, privacy: .public))")
                }
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
            .appendingPathComponent("PocketDeck-LiveText", isDirectory: true)
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
