// `--debug-deck-zoom FILE`: the Deck's double-click zoom, measured (e2e
// `deck`, NFR `deck_zoom_frame_p95_ms`). `NSWindow.zoom(nil)` is the path the
// title bar's double-click and the green button take; the frames the window
// server draws during it are sampled with a display link, so the numbers are
// the ones the person's eye sees. The grid's relayouts are counted beside them:
// a LazyVGrid that recomputes its columns on every frame shows up there.
//
// One shot at launch, when the Deck window exists: zoom in, settle, zoom back
// (the lag is worst on the way back), then write one JSON object.

import AppKit
import QuartzCore

@MainActor
final class DeckZoomProbe {
    /// How long a zoom may take to settle before the sample ends.
    private static let settle: TimeInterval = 1.2

    private let path: String
    private var displayLink: CADisplayLink?
    private var samples: [Double] = []
    private var started = Date()
    private var phase = 0
    private var report: [String: Any] = [:]
    private var timer: Timer?

    init(path: String) {
        self.path = path
    }

    /// Starts once, as soon as the Deck window is on screen.
    static func start(path: String) {
        let probe = DeckZoomProbe(path: path)
        Task { @MainActor in
            let deadline = Date(timeIntervalSinceNow: 30)
            while Date() < deadline, DeckWindow.window == nil {
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard let window = DeckWindow.window else { return }
            window.makeKeyAndOrderFront(nil)
            try? await Task.sleep(for: .milliseconds(800))
            probe.begin(on: window)
        }
    }

    private func begin(on window: NSWindow) {
        DeckGridMetrics.relayouts = 0
        zoom(window, label: "zoom")
    }

    private func zoom(_ window: NSWindow, label: String) {
        phase += 1
        samples.removeAll()
        started = Date()
        let link = window.contentView?.displayLink(target: self, selector: #selector(tick(_:)))
        link?.add(to: .main, forMode: .common)
        displayLink = link
        window.zoom(nil)
        // The zoom animates for a few hundred ms; the sample runs past it so
        // the last frames are counted too, then the next phase starts.
        let work = DispatchWorkItem { [weak self, weak window] in
            guard let self, let window else { return }
            self.finish(label)
            if label == "zoom" {
                self.zoom(window, label: "unzoom")
            } else {
                self.write()
            }
        }
        timer?.invalidate()
        let timer = Timer(timeInterval: Self.settle, repeats: false) { _ in work.perform() }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    @objc private func tick(_ link: CADisplayLink) {
        let now = CACurrentMediaTime()
        if lastTick > 0, now > lastTick {
            samples.append((now - lastTick) * 1000)
        }
        lastTick = now
    }

    private var lastTick: Double = 0

    private func finish(_ label: String) {
        displayLink?.invalidate()
        displayLink = nil
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
        report[label] = ["frames": samples.count,
                         "p50": percentile(0.5).rounded(),
                         "p95": percentile(0.95).rounded(),
                         "max": (sorted.last ?? 0).rounded(),
                         "settleMax": (settle.max() ?? 0).rounded()]
        Log.app.notice("deck zoom \(label, privacy: .public): p50=\(Int(percentile(0.5)), privacy: .public) ms p95=\(Int(percentile(0.95)), privacy: .public) ms frames=\(sorted.count, privacy: .public)")
    }

    private func write() {
        report["relayouts"] = DeckGridMetrics.relayouts
        guard let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]) else { return }
        try? data.write(to: URL(fileURLWithPath: path))
    }
}

/// Counters the grid writes and the zoom probe reads (one Deck window per app).
enum DeckGridMetrics {
    /// Every layout pass the grid took the window's width in (the number that
    /// a per-frame column recompute inflates).
    static var relayouts = 0
}
