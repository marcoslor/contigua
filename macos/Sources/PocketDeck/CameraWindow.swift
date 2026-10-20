// The "Phone Camera" window (docs/design/camera.md, C2): the phone's camera in
// a normal stream window, decoded by the same H.264 path as every window. No
// camera extension and no Mac camera API: the window only decodes VIDEO_FRAMEs
// the phone sends on the stream id the Mac chose.
//
// The window is one per session. Opening it asks `cam.list` and then starts a
// capture (`cam.start`) with the back camera at 1280×720@30; closing it asks
// `cam.stop`. States the phone reports (off, busy, evicted, locked, disabled,
// error) become a plain-words message over the last frame, with "Try Again"
// only where a click may restart the capture. A person's own camera app always
// wins: after `evicted` nothing restarts on its own.

import AppKit

/// One camera the phone lists in `cam.cams`.
struct PhoneCamera: Equatable {
    var id: String
    var facing: String
    var width: Int
    var height: Int

    init?(json: [String: Any]) {
        guard let id = json["id"] as? String, !id.isEmpty else { return nil }
        self.id = id
        facing = json["facing"] as? String ?? ""
        width = (json["w"] as? NSNumber)?.intValue ?? 0
        height = (json["h"] as? NSNumber)?.intValue ?? 0
    }
}

/// What the camera window is showing right now.
enum CameraStatus: String, CaseIterable {
    /// Waiting for `cam.cams` / `cam.state`: a spinner.
    case opening
    /// `cam.state {state:"streaming"}`: frames follow; a spinner until the first.
    case streaming
    case off
    case busy
    case evicted
    case locked
    case disabled
    case error
    /// The phone never answered `cam.list` (a build that predates `cam.*`).
    case unsupported
    /// The session ended; nothing restarts until the person reopens a window.
    case disconnected

    /// `cam.state.state` from the wire; an unknown name is `error`.
    static func wire(_ name: String) -> CameraStatus {
        CameraStatus(rawValue: name) ?? .error
    }
}

/// The words and controls for one state.
struct CameraStatusCopy: Equatable {
    var message: String?
    var showsSpinner: Bool
    var showsRetry: Bool
}

enum CameraWindowCopy {
    static let off = "Camera sharing is off on your phone. Turn on \"Let Macs use the camera\" in PocketDeck on the phone."
    static let busy = "The phone's camera is in use by another Mac window."
    static let evicted = "Your phone's camera app is using the camera."
    static let unavailable = "The phone's camera is not available right now."
    static let unsupported = "This phone can't share its camera. Update PocketDeck on the phone."
    static let disconnected = "Phone disconnected"

    /// The state → message/button mapping. `hasFrame` is only read for
    /// `streaming`: before the first frame the window shows a spinner.
    static func copy(for status: CameraStatus, hasFrame: Bool) -> CameraStatusCopy {
        switch status {
        case .opening:
            return CameraStatusCopy(message: nil, showsSpinner: true, showsRetry: false)
        case .streaming:
            guard !hasFrame else { return CameraStatusCopy(message: nil, showsSpinner: false, showsRetry: false) }
            return CameraStatusCopy(message: nil, showsSpinner: true, showsRetry: false)
        case .off:
            return CameraStatusCopy(message: off, showsSpinner: false, showsRetry: true)
        case .busy:
            return CameraStatusCopy(message: busy, showsSpinner: false, showsRetry: false)
        case .evicted:
            return CameraStatusCopy(message: evicted, showsSpinner: false, showsRetry: true)
        case .locked, .disabled:
            return CameraStatusCopy(message: unavailable, showsSpinner: false, showsRetry: true)
        case .error, .unsupported:
            return CameraStatusCopy(message: unsupported, showsSpinner: false, showsRetry: false)
        case .disconnected:
            return CameraStatusCopy(message: disconnected, showsSpinner: false, showsRetry: false)
        }
    }
}

/// The centred message box over the stream: text, an optional spinner and the
/// "Try Again" button. It only covers its own box, never the whole stream.
final class CameraStateView: NSView {
    private let box = NSView()
    private let label = NSTextField(wrappingLabelWithString: "")
    private let spinner = NSProgressIndicator()
    private let retry = NSButton(title: "Try Again", target: nil, action: nil)
    var onRetry: (() -> Void)?

    private var showsSpinner = false
    private var showsRetry = false

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        box.wantsLayer = true
        box.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.62).cgColor
        box.layer?.cornerRadius = 12
        addSubview(box)
        label.alignment = .center
        label.textColor = .white
        label.font = .systemFont(ofSize: 14)
        label.isEditable = false
        label.isSelectable = false
        label.isBordered = false
        label.drawsBackground = false
        label.cell?.wraps = true
        box.addSubview(label)
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        box.addSubview(spinner)
        retry.bezelStyle = .rounded
        retry.target = self
        retry.action = #selector(pressRetry)
        box.addSubview(retry)
        autoresizingMask = [.width, .height]
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    /// The scripted driver presses the same button the person clicks.
    @objc func pressRetry() {
        onRetry?()
    }

    func show(message: String?, spinner: Bool, retry: Bool) {
        label.stringValue = message ?? ""
        label.isHidden = message == nil
        showsSpinner = spinner
        showsRetry = retry
        self.retry.isHidden = !retry
        isHidden = message == nil && !spinner
        if spinner {
            self.spinner.startAnimation(nil)
        } else {
            self.spinner.stopAnimation(nil)
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        layoutBox()
    }

    private func layoutBox() {
        let width = min(420, max(240, bounds.width - 80))
        let textWidth = width - 40
        let textHeight = label.isHidden ? 0
            : label.sizeThatFits(NSSize(width: textWidth, height: .greatestFiniteMagnitude)).height
        var contentHeight: CGFloat = 0
        if showsSpinner { contentHeight += 22 }
        contentHeight += textHeight
        if showsRetry { contentHeight += 12 + 24 }
        let height = max(contentHeight, 8) + 36
        box.frame = NSRect(x: (bounds.width - width) / 2, y: (bounds.height - height) / 2,
                           width: width, height: height)
        var y: CGFloat = 18
        if showsSpinner {
            spinner.frame = NSRect(x: (width - 16) / 2, y: y, width: 16, height: 16)
            y += 22
        }
        if !label.isHidden {
            label.frame = NSRect(x: 20, y: y, width: textWidth, height: textHeight)
            y += textHeight
        }
        if showsRetry {
            let size = retry.fittingSize
            retry.frame = NSRect(x: (width - size.width) / 2, y: y + 12,
                                 width: size.width, height: max(size.height, 24))
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden else { return nil }
        let hit = super.hitTest(point)
        // The empty area around the box is not part of the message.
        guard let hit, hit !== self else { return nil }
        return hit
    }
}

final class CameraWindowController: StreamWindowController {
    private(set) var status: CameraStatus = .opening
    private(set) var cams: [PhoneCamera] = []
    private(set) var selectedCamera: PhoneCamera?
    private(set) var frames = 0

    private let stateView = CameraStateView()
    private var hasFrame = false
    /// `sendOpen` runs once; a reconnect (`ready` → `reopenAll`) never restarts
    /// a capture (docs/design/camera.md: the person reopens the window).
    private var started = false
    private var unsupportedWork: DispatchWorkItem?
    private var stateTimer: Timer?
    private var lastVideoSize = CGSize.zero
    private var lastLogLine = ""

    init(stream: UInt32, manager: WindowManager) {
        super.init(stream: stream, contentSize: NSSize(width: 1280, height: 720), manager: manager, styleKey: nil)
        // Not an Android surface: touches, keys and hover go nowhere, and the
        // camera answers keyframes on its own (every 2 s).
        videoView.inputMapper = nil
        videoView.onRequestKeyframe = nil
        videoView.learnsFormatFromFrames = true
        window?.title = Self.title(phone: manager.phoneName)
        window?.minSize = style.windowSize(stream: NSSize(width: 320, height: 180))
        stateView.onRetry = { [weak self] in self?.pressTryAgain() }
        stateView.frame = videoView.bounds
        videoView.addSubview(stateView)
        NotificationCenter.default.addObserver(self, selector: #selector(videoSizeChanged(_:)),
                                               name: VideoLayerView.videoSizeDidChange, object: videoView)
        updateStateView()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.logState() }
        RunLoop.main.add(timer, forMode: .common)
        stateTimer = timer
        logState()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private static func title(phone: String) -> String {
        phone.isEmpty ? "Phone Camera" : "Phone Camera — \(phone)"
    }

    override var frameKey: String { "camera" }

    override func retitle() {
        window?.title = Self.title(phone: manager.phoneName)
    }

    // MARK: Opening and closing

    /// The window was just opened: ask for the camera list. A reconnect never
    /// repeats this (the person reopens the window instead).
    override func sendOpen() {
        guard !started else { return }
        started = true
        setStatus(.opening)
        session.camList()
        // An older phone ignores `cam.list` like any unknown message.
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.status == .opening else { return }
            self.setStatus(.unsupported)
        }
        unsupportedWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
    }

    override func sendClose() {
        session.camStop(stream: stream)
    }

    /// Closing sends `cam.stop`, not `window.close`: the stream is a camera.
    override func sendResize() {}

    // MARK: Phone events

    func adopt(cams: [PhoneCamera]) {
        unsupportedWork?.cancel()
        unsupportedWork = nil
        self.cams = cams
        chrome.setActions(headerActions())
        guard status != .disconnected else { return }
        startCapture()
    }

    func handleCamState(stream: UInt32, state: String, reason: String?) {
        guard stream == self.stream else { return }
        unsupportedWork?.cancel()
        unsupportedWork = nil
        let next = CameraStatus.wire(state)
        if next == .streaming {
            setStatus(.streaming)
        } else if next == .error {
            Log.video.notice("camera capture error: \(reason ?? "unknown", privacy: .public)")
            setStatus(.error)
        } else {
            setStatus(next)
        }
    }

    /// Called by the window manager for every VIDEO_FRAME routed here. Video
    /// arrives on the session queue; the counter and the overlay are main
    /// thread work.
    override func receivedFrame() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.receivedFrame() }
            return
        }
        guard status == .streaming else { return }
        frames += 1
        if !hasFrame {
            hasFrame = true
            updateStateView()
        }
    }

    // MARK: Capture control

    private func startCapture() {
        frames = 0
        hasFrame = false
        let target = cams.first(where: { $0.facing == "back" }) ?? cams.first
        selectedCamera = target
        setStatus(.opening)
        chrome.setActions(headerActions())
        if let target {
            session.camStart(stream: stream, id: target.id, facing: target.facing,
                             width: 1280, height: 720, fps: 30)
        } else {
            // Nothing listed: the phone answers `off` (the setting is off).
            session.camStart(stream: stream, id: nil, facing: "back",
                             width: 1280, height: 720, fps: 30)
        }
        logState()
    }

    /// The bar's camera button (hidden with one camera): stop this capture and
    /// start the other camera on a fresh stream id.
    override func headerActions() -> [HeaderAction] {
        guard cams.count > 1 else { return [] }
        let front = selectedCamera?.facing == "front"
        return [HeaderAction(symbol: "camera.rotate",
                             help: front ? "Use the back camera" : "Use the front camera") { [weak self] in
            self?.switchCamera()
        }]
    }

    /// The person picked the other camera (or the scripted driver did).
    func switchCamera() {
        guard cams.count > 1, status != .disconnected else { return }
        let other = cams.first(where: { $0.id != selectedCamera?.id }) ?? cams[0]
        session.camStop(stream: stream)
        manager.rebind(self, to: manager.newStreamID())
        selectedCamera = other
        frames = 0
        hasFrame = false
        setStatus(.opening)
        session.camStart(stream: stream, id: other.id, facing: other.facing,
                         width: 1280, height: 720, fps: 30)
        logState()
    }

    /// The message's "Try Again" (the scripted driver presses the same).
    func pressTryAgain() {
        guard status != .disconnected else { return }
        manager.rebind(self, to: manager.newStreamID())
        startCapture()
    }

    // MARK: Session end

    /// The link went away: the window says so and stops. No reconnect pill and
    /// no restart on reconnect; the person reopens the window.
    override func setLinkDown(_ down: Bool) {
        guard down else { return }
        liveText.exit(.disconnect)
        frames = 0
        hasFrame = false
        setStatus(.disconnected)
    }

    // MARK: Window sizing

    @objc private func videoSizeChanged(_ note: Notification) {
        guard let view = note.object as? VideoLayerView, view === videoView else { return }
        let size = videoView.videoSize
        guard size.width > 0, size.height > 0, size != lastVideoSize else { return }
        lastVideoSize = size
        applyAspect(size)
        logState()
    }

    /// The window keeps the stream's aspect: the camera sends no size up front,
    /// so the first keyframe's dimensions decide it. Never larger than 85% of
    /// the visible screen.
    private func applyAspect(_ size: CGSize) {
        guard size.width >= 160, size.height >= 120 else { return }
        let visible = window?.screen?.visibleFrame ?? NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let scale = min(1, visible.width * 0.85 / size.width, visible.height * 0.85 / size.height)
        setContentSize(NSSize(width: (size.width * scale).rounded(),
                              height: (size.height * scale).rounded()))
    }

    // MARK: Overlay and state

    private func setStatus(_ next: CameraStatus) {
        status = next
        if next != .streaming { hasFrame = false }
        updateStateView()
        logState()
    }

    private func updateStateView() {
        let copy = CameraWindowCopy.copy(for: status, hasFrame: hasFrame)
        stateView.show(message: copy.message, spinner: copy.showsSpinner, retry: copy.showsRetry)
    }

    // MARK: Logging (e2e reads these lines from app.log)

    private func logState() {
        let line = "camera window: state=\(status.rawValue) frames=\(frames)"
            + " size=\(Int(videoView.videoSize.width))x\(Int(videoView.videoSize.height))"
        guard line != lastLogLine else { return }
        lastLogLine = line
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }

    // MARK: Close

    override func windowWillClose(_ notification: Notification) {
        stateTimer?.invalidate()
        stateTimer = nil
        unsupportedWork?.cancel()
        unsupportedWork = nil
        NotificationCenter.default.removeObserver(self)
        super.windowWillClose(notification)
    }
}
