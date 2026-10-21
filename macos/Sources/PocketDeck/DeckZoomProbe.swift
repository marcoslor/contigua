// `--debug-deck-zoom FILE`: the Deck's double-click zoom, measured (e2e
// `deck`, NFR `deck_zoom_frame_p95_ms`). `NSWindow.zoom(nil)` is the path the
// title bar's double-click and the green button take; the frames the window
// server draws during it are sampled with a display link, so the numbers are
// the ones the person's eye sees. A live drag-resize (scripted `setFrame`
// steps) is sampled the same way: it is the other way a window changes width
// without a relaunch.
//
// Each sampled frame also carries the grid as drawn: the cells' frames, the
// grid's visible bounds and the width it was given. `DeckFrameFit` turns them
// into the e2e check's per-frame assertion, so a layout that lags the window
// (the person's clipped edges) is a named failing frame, not a description.
//
// One shot at launch, when the Deck window exists: zoom in, settle, zoom back
// (the lag is worst on the way back), drag the window narrower in steps, then
// write one JSON object.

import AppKit
import QuartzCore

@MainActor
final class DeckZoomProbe {
    /// The three ways a window changes width while the Deck is up. Every one is
    /// sampled, and the sample ends when the window has settled again.
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
    /// Steps a live drag takes, at the display's frame interval.
    private static let dragSteps = 60
    /// The width the drag ends on: the Deck's default size.
    private static let dragEndWidth: CGFloat = 760

    private let path: String
    private var displayLink: CADisplayLink?
    private var samples: [Double] = []
    private var fits: [DeckFrameFit] = []
    private var started = Date()
    private var report: [String: Any] = [:]
    private var timer: Timer?
    private var dragTimer: Timer?
    private var dragStep = 0
    private var dragFrom: CGFloat = 0
    private var dragTo: CGFloat = 0
    private weak var window: NSWindow?

    init(path: String) {
        self.path = path
    }

    /// Starts once, as soon as the Deck window is on screen with the grid drawn.
    static func start(path: String) {
        DeckGridMetrics.recording = true
        let probe = DeckZoomProbe(path: path)
        Task { @MainActor in
            let deadline = Date(timeIntervalSinceNow: 30)
            while Date() < deadline, DeckWindow.window == nil {
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard let window = DeckWindow.window else { return }
            window.makeKeyAndOrderFront(nil)
            // The grid draws once the app list and the icons arrive; sampling
            // an empty grid would measure nothing.
            let gridDeadline = Date(timeIntervalSinceNow: 20)
            while Date() < gridDeadline, !DeckGridMetrics.hasCells {
                try? await Task.sleep(for: .milliseconds(100))
            }
            try? await Task.sleep(for: .milliseconds(800))
            probe.begin(on: window)
        }
    }

    private func begin(on window: NSWindow) {
        self.window = window
        DeckGridMetrics.relayouts = 0
        run(.zoom)
    }

    private func run(_ phase: Phase) {
        guard let window else { return }
        samples.removeAll()
        fits.removeAll()
        started = Date()
        noteFrame(on: window)
        timer?.invalidate()
        let timer = Timer(timeInterval: Self.settle, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.advance(phase) }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        switch phase {
        case .zoom, .unzoom:
            window.zoom(nil)
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
    /// frame moves one step per display frame, from the widest the screen
    /// allows down to the default width.
    private func startDrag() {
        guard let window else { return }
        let screen = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        let frame = window.frame
        let wide = min(max(frame.width, screen.width - 80), 1400)
        dragFrom = wide
        dragTo = min(Self.dragEndWidth, wide)
        dragStep = 0
        window.setFrame(NSRect(x: frame.minX, y: frame.minY, width: wide, height: frame.height),
                        display: true)
        dragTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.dragStep(on: frame) }
        }
        self.dragTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func dragStep(on frame: NSRect) {
        guard let window else { return }
        dragStep += 1
        let progress = Double(min(dragStep, Self.dragSteps)) / Double(Self.dragSteps)
        let width = dragFrom + (dragTo - dragFrom) * CGFloat(progress)
        window.setFrame(NSRect(x: frame.minX, y: frame.minY, width: width, height: frame.height),
                        display: true)
        if dragStep >= Self.dragSteps { dragTimer?.invalidate() }
    }

    private func noteFrame(on window: NSWindow) {
        let link = window.contentView?.displayLink(target: self, selector: #selector(tick(_:)))
        link?.add(to: .main, forMode: .common)
        displayLink = link
    }

    @objc private func tick(_ link: CADisplayLink) {
        let now = CACurrentMediaTime()
        if lastTick > 0, now > lastTick {
            samples.append((now - lastTick) * 1000)
        }
        lastTick = now
        if let fit = frameFit() { fits.append(fit) }
    }

    /// The grid as drawn in this frame, against the window's own content
    /// bounds: those are what clips the Deck while the window resizes, and the
    /// grid's frame cannot be trusted to be the visible width (the stale
    /// layout keeps its old, wider frame and is centred inside the window).
    private func frameFit() -> DeckFrameFit? {
        guard let window, let content = window.contentView?.bounds,
              let shot = DeckGridMetrics.snapshot() else { return nil }
        let left = max(shot.viewport.minX, content.minX)
        let right = min(shot.viewport.maxX, content.maxX)
        guard right - left > 1 else { return nil }
        let visible = CGRect(x: left, y: shot.viewport.minY, width: right - left,
                             height: shot.viewport.height)
        return DeckFrameFit.measure(width: visible.width, visible: visible, cells: shot.cells)
    }

    private var lastTick: Double = 0

    private func finish(_ phase: Phase) {
        displayLink?.invalidate()
        displayLink = nil
        dragTimer?.invalidate()
        dragTimer = nil
        lastTick = 0
        // The animation is what the eye follows; the last frame or two after
        // the window stops changing size are the settle (one layout pass, not
        // a stutter). The p95 covers the animation, the settle is reported
        // beside it.
        let animation = samples.prefix(max(1, Int(Double(samples.count) * 0.85)))
        let settle = samples.dropFirst(animation.count)
        let sorted = animation.sorted()
        func percentile(_ p: Double) -> Double {
            guard !sorted.isEmpty else { return 0 }
            let index = min(sorted.count - 1, Int((Double(sorted.count - 1) * p).rounded()))
            return sorted[index]
        }
        let bad = fits.filter { !$0.ok }
        var info: [String: Any] = ["frames": samples.count,
                                   "p50": percentile(0.5).rounded(),
                                   "p95": percentile(0.95).rounded(),
                                   "max": (sorted.last ?? 0).rounded(),
                                   "settleMax": (settle.max() ?? 0).rounded(),
                                   "measured": fits.count,
                                   "badFrames": bad.count,
                                   "clippedCells": fits.map(\.clipped).reduce(0, +)]
        // The widest frame's evidence: what the check prints when it fails.
        info["examples"] = bad.prefix(3).map(\.summary)
        report[phase.rawValue] = info
        Log.app.notice("deck zoom \(phase.rawValue, privacy: .public): p50=\(Int(percentile(0.5)), privacy: .public) ms p95=\(Int(percentile(0.95)), privacy: .public) ms frames=\(sorted.count, privacy: .public) bad=\(bad.count, privacy: .public)")
    }

    private func write() {
        report["relayouts"] = DeckGridMetrics.relayouts
        guard let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]) else { return }
        try? data.write(to: URL(fileURLWithPath: path))
    }
}

/// One drawn frame's horizontal fit, as the eye judges it: every cell inside
/// the width it was drawn in, one inset on both sides, and the column count
/// that width asks for. `width` is the width the grid was given that frame;
/// `visible` is where the ScrollView clips it.
struct DeckFrameFit: Equatable {
    let width: CGFloat
    let cells: Int
    let columns: Int
    let expectedColumns: Int
    let leftInset: CGFloat
    let rightInset: CGFloat
    let clipped: Int

    static let empty = DeckFrameFit(width: 0, cells: 0, columns: 0, expectedColumns: 0,
                                    leftInset: 0, rightInset: 0, clipped: 0)

    /// Cells may be half a point outside a rounded edge before it is the bug:
    /// the person's frames lose more than half a tile per side.
    static let tolerance: CGFloat = 1

    static func measure(width: CGFloat, visible: CGRect, cells frames: [CGRect]) -> DeckFrameFit {
        guard width > 0, !frames.isEmpty else { return .empty }
        let minX = frames.map(\.minX).min() ?? visible.minX
        let maxX = frames.map(\.maxX).max() ?? visible.maxX
        // Columns are the distinct left edges the cells were drawn at.
        var edges: [CGFloat] = []
        for x in frames.map(\.minX).sorted() where edges.last.map({ abs(x - $0) > tolerance }) ?? true {
            edges.append(x)
        }
        return DeckFrameFit(width: width,
                            cells: frames.count,
                            columns: edges.count,
                            expectedColumns: GridMetrics.columns(forWidth: width),
                            leftInset: minX - visible.minX,
                            rightInset: visible.maxX - maxX,
                            clipped: frames.filter { $0.minX < visible.minX - tolerance || $0.maxX > visible.maxX + tolerance }.count)
    }

    /// The check's per-frame assertion.
    var ok: Bool {
        cells > 0 && clipped == 0 && abs(leftInset - rightInset) <= Self.tolerance
            && columns == expectedColumns
    }

    /// The line the e2e check prints for a failing frame.
    var summary: String {
        let format = { (value: CGFloat) in String(format: "%.1f", value) }
        return "w=\(format(width)) cols=\(columns)/\(expectedColumns) left=\(format(leftInset)) right=\(format(rightInset)) clipped=\(clipped)/\(cells)"
    }
}

/// Counters and the drawn grid the zoom probe reads (one Deck window per app).
/// Nothing is recorded unless `--debug-deck-zoom` asked for a measurement, so
/// a normal run pays nothing.
@MainActor
enum DeckGridMetrics {
    /// Every layout pass the grid took the window's width in.
    static var relayouts = 0
    static var recording = false

    /// The ScrollView's frame (window coordinates) and the cells' drawn frames.
    private static var viewport: CGRect = .zero
    private static var cellFrames: [String: CGRect] = [:]

    static var hasCells: Bool { !cellFrames.isEmpty && viewport.width > 0 }

    static func noteViewport(_ rect: CGRect) {
        guard recording else { return }
        viewport = rect
    }

    static func noteCell(_ id: String, _ frame: CGRect) {
        guard recording else { return }
        cellFrames[id] = frame
    }

    /// The drawn grid of the last layout pass, for the probe's frame sample.
    struct Snapshot {
        let viewport: CGRect
        let cells: [CGRect]
    }

    static func snapshot() -> Snapshot? {
        guard recording, !cellFrames.isEmpty else { return nil }
        return Snapshot(viewport: viewport, cells: Array(cellFrames.values))
    }
}
