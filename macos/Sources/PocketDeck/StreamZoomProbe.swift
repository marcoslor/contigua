// `--debug-stream-zoom FILE`: a live stream window's double-click zoom,
// measured (e2e `zoom`, NFR `stream_zoom_frame_p95_ms`). `NSWindow.zoom(nil)`
// is the path the title bar's double-click and the green button take on an app
// window. AppKit runs that animation in the window server and delivers one
// `windowDidResize` per step; those notifications are the animation's frames
// here, because a display link or timer is starved for the animation's whole
// life (measured on the e2e host: the link stalls for the ~350 ms the zoom
// runs). A scripted live drag drives the same notifications one per display
// frame, so the two ways of changing a window's shape are measured the same.
//
// Each animation step also carries the picture as drawn: the video view's
// bounds, the drawn picture's rect and its placement (fit, fill, stretch) and
// the gap between them. A picture that is re-laid out on every animation step,
// or that jumps between letterbox and fill, is a named step, not a
// description. Every VIDEO_CONFIG that arrives during a phase is recorded too:
// each one is the phone re-rendering its display at a new size.

import AppKit
import QuartzCore

@MainActor
final class StreamZoomProbe {
    /// The ways a stream window changes size. Every one is sampled, and the
    /// sample ends when the window has settled again.
    enum Phase: String, CaseIterable {
        case zoom, unzoom, drag

        var next: Phase? {
            let all = Phase.allCases
            guard let index = all.firstIndex(of: self), index + 1 < all.count else { return nil }
            return all[index + 1]
        }
    }

    /// How long a phase may take to settle before the sample ends.
    private static let settle: TimeInterval = 1.2
    /// Steps the scripted drag takes, at the display's frame interval.
    private static let dragSteps = 60
    /// How long to wait for the window's first frame before giving up.
    private static let firstFrameTimeout: TimeInterval = 40

    /// The run's one probe: the sample is a chain of timers, observers and
    /// display links, so something has to hold it while those are weak.
    private static var running: StreamZoomProbe?

    private let path: String
    private var displayLink: CADisplayLink?
    /// Intervals the display link saw after the animation: the settle's frame
    /// time, beside the animation's own step cadence.
    private var settleSamples: [Double] = []
    /// One entry per `windowDidResize`, in order: the animation's frames.
    private var stepTimes: [Double] = []
    private var stepWindows: [CGSize] = []
    private var stepDrawn: [CGSize] = []
    private var stepModes: [String] = []
    private var stepGaps: [CGFloat] = []
    /// Picture frames drained by the time of each animation step: a stalled
    /// main run loop leaves this at zero for the whole animation.
    private var stepFrames: [Int] = []
    /// Per step: ms since the phase's first step, window and drawn size, the
    /// fill rule's flags, the placement and the gap. The failing step's own
    /// evidence, small enough to log.
    private var stepTrace: [[Int]] = []
    private var firstStepUptime: Double = 0
    /// Picture frames handed to the display layer during the phase.
    private var framesAtStart = 0
    private var configs: [(size: CGSize, at: TimeInterval)] = []
    private var configObserver: NSObjectProtocol?
    private var resizeObserver: NSObjectProtocol?
    private var startedAt = Date()
    private var report: [String: Any] = [:]
    private var timer: Timer?
    /// The phase's action waits for the display link's first tick: the link
    /// is created with the sample, and an action started before it ticks has
    /// finished by the time the first frame is seen.
    private var pendingAction: Phase?
    private var dragStep = 0
    private var dragFrom: CGSize = .zero
    private var dragTo: CGSize = .zero
    private var currentPhase: Phase?
    private var originalFrame: NSRect = .zero
    private var zoomedFrame: NSRect = .zero
    private var refreshMs: Double = 0
    private var lastTick: Double = 0
    private var lastStep: Double = 0
    private weak var window: NSWindow?
    private weak var controller: StreamWindowController?

    init(path: String) {
        self.path = path
    }

    /// Starts once, as soon as a live stream window is on screen with a picture.
    static func start(path: String) {
        let probe = StreamZoomProbe(path: path)
        running = probe
        Task { @MainActor in
            let deadline = Date(timeIntervalSinceNow: firstFrameTimeout)
            while Date() < deadline {
                if let controller = firstLiveWindow() {
                    probe.begin(on: controller)
                    return
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
            Log.app.notice("stream zoom: no live window to measure")
        }
    }

    /// The first app window whose picture has arrived. A link or handoff
    /// window is not a person's double-click target in this check.
    private static func firstLiveWindow() -> StreamWindowController? {
        let manager = AppEnvironment.shared.controller.windows
        for stream in manager.openStreams {
            guard let controller = manager.controller(for: stream),
                  controller is AppWindowController,
                  controller.videoView.videoSize.width > 0,
                  !controller.isOpening,
                  let window = controller.window,
                  window.isVisible, !window.isMiniaturized else { continue }
            return controller
        }
        return nil
    }

    private func begin(on controller: StreamWindowController) {
        guard let window = controller.window else { return }
        self.window = window
        self.controller = controller
        originalFrame = window.frame
        window.makeKeyAndOrderFront(nil)
        configObserver = NotificationCenter.default.addObserver(
            forName: VideoLayerView.videoSizeDidChange, object: nil, queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, let view = note.object as? VideoLayerView else { return }
                self.configs.append((view.videoSize, Date().timeIntervalSince1970))
            }
        }
        resizeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.noteStep() }
        }
        // A person zooms a settled window: give the first picture's resize (if
        // the open itself asked for one) its debounce before measuring.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(800))
            guard let self else { return }
            self.run(.zoom)
        }
    }

    private func run(_ phase: Phase) {
        guard let window else { return }
        settleSamples.removeAll()
        stepTimes.removeAll()
        stepWindows.removeAll()
        stepDrawn.removeAll()
        stepModes.removeAll()
        stepGaps.removeAll()
        stepFrames.removeAll()
        stepTrace.removeAll()
        firstStepUptime = 0
        configs.removeAll()
        currentPhase = phase
        startedAt = Date()
        pendingAction = phase
        noteFrame(on: window)
        timer?.invalidate()
        let timer = Timer(timeInterval: Self.settle, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.advance(phase) }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func perform(_ phase: Phase) {
        startedAt = Date()
        lastStep = 0
        framesAtStart = controller?.videoView.framesDrained ?? 0
        switch phase {
        case .zoom, .unzoom:
            window?.zoom(nil)
        case .drag:
            startDrag()
        }
    }

    private func advance(_ phase: Phase) {
        finish(phase)
        if let next = phase.next {
            run(next)
        } else {
            write()
        }
    }

    /// A live resize the person would make by dragging the window's edge: the
    /// same size change as the zoom, one step per display frame, through the
    /// delegate calls AppKit makes for a mouse drag.
    private func startDrag() {
        guard let window, let controller else { return }
        dragFrom = window.frame.size
        dragTo = zoomedFrame.size
        dragStep = 0
        controller.windowWillStartLiveResize(
            Notification(name: NSWindow.willStartLiveResizeNotification, object: window))
    }

    /// One resize step, driven by the display link itself (one per frame, as a
    /// person's live drag is). A separate 1/60 s timer would compete with the
    /// link for the main thread and report its own collisions as dropped
    /// frames.
    private func stepDrag() {
        guard let controller else { return }
        dragStep += 1
        let progress = Double(min(dragStep, Self.dragSteps)) / Double(Self.dragSteps)
        let size = CGSize(width: dragFrom.width + (dragTo.width - dragFrom.width) * CGFloat(progress),
                          height: dragFrom.height + (dragTo.height - dragFrom.height) * CGFloat(progress))
        controller.liveResizeStep(to: size)
        if dragStep == Self.dragSteps {
            controller.windowDidEndLiveResize(
                Notification(name: NSWindow.didEndLiveResizeNotification, object: window))
        }
    }

    private func noteFrame(on window: NSWindow) {
        let link = window.contentView?.displayLink(target: self, selector: #selector(tick(_:)))
        link?.add(to: .main, forMode: .common)
        displayLink = link
    }

    @objc private func tick(_ link: CADisplayLink) {
        if refreshMs == 0, link.duration > 0 { refreshMs = link.duration * 1000 }
        if let pendingAction {
            self.pendingAction = nil
            // The tick that starts the animation is its first frame, not an
            // interval to measure.
            lastTick = 0
            perform(pendingAction)
        }
        let now = CACurrentMediaTime()
        if lastTick > 0, now > lastTick {
            settleSamples.append((now - lastTick) * 1000)
        }
        lastTick = now
        if currentPhase == .drag, dragStep < Self.dragSteps {
            stepDrag()
        }
    }

    /// One animation frame: AppKit's zoom calls this through its animation
    /// loop, the scripted drag through `setFrame`.
    private func noteStep() {
        guard currentPhase != nil, let controller, let window else { return }
        let now = CACurrentMediaTime()
        if lastStep > 0 {
            stepTimes.append((now - lastStep) * 1000)
        }
        lastStep = now
        if firstStepUptime == 0 { firstStepUptime = now }
        stepWindows.append(window.frame.size)
        let view = controller.videoView
        let rect = view.videoRect()
        let bounds = view.bounds.size
        stepDrawn.append(rect.size)
        stepGaps.append(view.videoGap())
        stepFrames.append(view.framesDrained - framesAtStart)
        let mode: String
        if abs(rect.width - bounds.width) < 0.5, abs(rect.height - bounds.height) < 0.5 {
            mode = "stretch"
        } else if rect.width >= bounds.width - 0.5, rect.height >= bounds.height - 0.5 {
            mode = "fill"
        } else {
            mode = "fit"
        }
        stepModes.append(mode)
        let fill = view.resizeFillState
        stepTrace.append([Int(((now - firstStepUptime) * 1000).rounded()),
                          Int(window.frame.width.rounded()), Int(window.frame.height.rounded()),
                          Int(rect.width.rounded()), Int(rect.height.rounded()),
                          fill.armed ? 1 : 0, fill.pending ? 1 : 0,
                          mode == "fill" ? 1 : (mode == "stretch" ? 2 : 0),
                          Int(view.videoGap().rounded())])
    }

    private func finish(_ phase: Phase) {
        displayLink?.invalidate()
        displayLink = nil
        currentPhase = nil
        lastTick = 0
        lastStep = 0
        if phase == .zoom { zoomedFrame = window?.frame ?? .zero }
        // The animation is what the eye follows. Its frames are the resize
        // notifications; the display link's own samples after it are the
        // settle, reported beside them.
        let animation = stepTimes
        let sorted = animation.sorted()
        func percentile(_ values: [Double], _ p: Double) -> Double {
            guard !values.isEmpty else { return 0 }
            let index = min(values.count - 1, Int((Double(values.count - 1) * p).rounded()))
            return values[index]
        }
        let settle = settleSamples.sorted()
        let windowSteps = transitions(in: stepWindows)
        let drawnSteps = transitions(in: stepDrawn)
        var modeChanges = 0
        for (previous, mode) in zip(stepModes, stepModes.dropFirst()) where previous != mode {
            modeChanges += 1
        }
        let phaseConfigs = configs.filter { $0.at >= startedAt.timeIntervalSince1970 }
        var uniqueModes: [String] = []
        for mode in stepModes where !uniqueModes.contains(mode) { uniqueModes.append(mode) }
        let frames = (controller?.videoView.framesDrained ?? 0) - framesAtStart
        var info: [String: Any] = ["frames": frames,
                                   "framesDuringSteps": stepFrames.last ?? 0,
                                   "steps": stepWindows.count,
                                   "windowSteps": windowSteps,
                                   "drawnSteps": drawnSteps,
                                   "modeChanges": modeChanges,
                                   "modes": uniqueModes,
                                   "gapFrames": stepGaps.filter { $0 > 1 }.count,
                                   "gapMax": (stepGaps.max() ?? 0).rounded(),
                                   "trace": stepTrace,
                                   "configs": phaseConfigs.map { [$0.size.width, $0.size.height] },
                                   "p50": percentile(sorted, 0.5).rounded(),
                                   "p95": percentile(sorted, 0.95).rounded(),
                                   "max": (sorted.last ?? 0).rounded(),
                                   "settleFrames": settleSamples.count,
                                   "settleP95": percentile(settle, 0.95).rounded(),
                                   "settleMax": (settle.last ?? 0).rounded(),
                                   "refreshMs": (refreshMs * 100).rounded() / 100,
                                   "histogram": histogram(of: animation),
                                   "startedAt": startedAt.timeIntervalSince1970,
                                   "endedAt": Date().timeIntervalSince1970,
                                   "windowStart": sizePair(stepWindows.first ?? .zero),
                                   "windowEnd": sizePair(stepWindows.last ?? .zero)]
        report[phase.rawValue] = info
        let steps = stepWindows.count
        let resizes = phaseConfigs.count
        Log.app.notice("stream zoom \(phase.rawValue, privacy: .public): p50=\(Int(percentile(sorted, 0.5)), privacy: .public) ms p95=\(Int(percentile(sorted, 0.95)), privacy: .public) ms steps=\(steps, privacy: .public) resizes=\(resizes, privacy: .public)")
    }

    private func transitions(in sizes: [CGSize]) -> Int {
        var count = 0
        for (previous, size) in zip(sizes, sizes.dropFirst())
        where abs(previous.width - size.width) > 0.5 || abs(previous.height - size.height) > 0.5 {
            count += 1
        }
        return count
    }

    private func sizePair(_ size: CGSize) -> [Int] {
        [Int(size.width.rounded()), Int(size.height.rounded())]
    }

    private func write() {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        if let resizeObserver { NotificationCenter.default.removeObserver(resizeObserver) }
        configObserver = nil
        resizeObserver = nil
        report["originalFrame"] = [Int(originalFrame.origin.x.rounded()), Int(originalFrame.origin.y.rounded()),
                                   Int(originalFrame.width.rounded()), Int(originalFrame.height.rounded())]
        report["zoomedFrame"] = [Int(zoomedFrame.origin.x.rounded()), Int(zoomedFrame.origin.y.rounded()),
                                 Int(zoomedFrame.width.rounded()), Int(zoomedFrame.height.rounded())]
        if let visible = window?.screen?.visibleFrame {
            report["visibleFrame"] = [Int(visible.origin.x.rounded()), Int(visible.origin.y.rounded()),
                                      Int(visible.width.rounded()), Int(visible.height.rounded())]
        }
        report["refreshMs"] = (refreshMs * 100).rounded() / 100
        defer { Self.running = nil }
        guard let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]) else { return }
        try? data.write(to: URL(fileURLWithPath: path))
    }

    /// Step intervals counted per whole millisecond, smallest first: the shape
    /// a p95 hides (one slow frame or a step at twice the refresh).
    private func histogram(of samples: [Double]) -> [[Int]] {
        var counts: [Int: Int] = [:]
        for sample in samples { counts[Int(sample.rounded()), default: 0] += 1 }
        let pairs: [(Int, Int)] = counts.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
        return pairs.map { [$0.0, $0.1] }
    }
}
