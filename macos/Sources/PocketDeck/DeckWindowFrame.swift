// The Deck's frame across launches (DECK-19, CONV-MAC-12): SwiftUI opens the
// scene at its default size and remembers nothing, so this view places the
// window from the profile's defaults as soon as the content is in a window, and
// saves the frame whenever the person moves or resizes it. The rules themselves
// are pure (DeckPlacement), the same pattern Settings uses (SET-WIN-09).

import AppKit
import SwiftUI

struct DeckWindowFrame: NSViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = AnchorView()
        let coordinator = context.coordinator
        // The earliest moment the window exists: SwiftUI has added the content
        // to it, and nothing has been displayed yet.
        view.onWindow = { [weak coordinator] window in coordinator?.attach(to: window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.placeIfNeeded(nsView.window)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.saveNow()
    }

    /// A zero-sized view that reports the window it lands in.
    private final class AnchorView: NSView {
        var onWindow: ((NSWindow?) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onWindow?(window)
        }
    }

    @MainActor
    final class Coordinator {
        private weak var window: NSWindow?
        private var notices: [NSObjectProtocol] = []
        private var saveTask: Task<Void, Never>?
        private var placed = false

        func attach(to window: NSWindow?) {
            guard let window, self.window !== window else { return }
            detach()
            self.window = window
            let centre = NotificationCenter.default
            for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification,
                         NSWindow.willCloseNotification] {
                notices.append(centre.addObserver(forName: name, object: window, queue: .main) {
                    [weak self] _ in
                    MainActor.assumeIsolated { self?.saveSoon() }
                })
            }
            notices.append(centre.addObserver(forName: NSApplication.willTerminateNotification,
                                             object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.saveNow() }
            })
            placeIfNeeded(window)
        }

        func detach() {
            saveNow()
            for notice in notices { NotificationCenter.default.removeObserver(notice) }
            notices = []
            window = nil
            placed = false
        }

        /// Place the window once per open. Nothing is placed afterwards, so a
        /// person's drag is never undone.
        func placeIfNeeded(_ window: NSWindow?) {
            guard !placed, let window else { return }
            placed = true
            // Full screen is not the Deck's frame: the stored frame stays the
            // window's own one.
            guard !window.styleMask.contains(.fullScreen) else { return }
            let frames = screenFrames(around: window)
            let minimum = window.minSize.width > 0 ? window.minSize
                : CGSize(width: 640, height: 420)
            let saved = DeckPlacement.saved(in: Profile.active.defaults)
            let frame = DeckPlacement.frame(saved: saved, screens: frames, minimum: minimum)
            let before = window.frame
            window.setFrame(frame, display: false)
            let home = frames.first ?? .zero
            Log.app.notice("deck placement: screens=\(frames.count, privacy: .public) home=\(Int(home.minX.rounded()), privacy: .public),\(Int(home.minY.rounded()), privacy: .public) \(Int(home.width.rounded()), privacy: .public)x\(Int(home.height.rounded()), privacy: .public) was=\(Int(before.minX.rounded()), privacy: .public),\(Int(before.minY.rounded()), privacy: .public) \(Int(before.width.rounded()), privacy: .public)x\(Int(before.height.rounded()), privacy: .public) frame=\(Int(frame.minX.rounded()), privacy: .public),\(Int(frame.minY.rounded()), privacy: .public) \(Int(frame.width.rounded()), privacy: .public)x\(Int(frame.height.rounded()), privacy: .public)")
        }

        /// The visible frames, the window's own screen first: that is the one a
        /// saved frame is restored on, and the one a lost frame is centred on.
        private func screenFrames(around window: NSWindow) -> [CGRect] {
            let screens = NSScreen.screens
            let home = window.screen ?? NSScreen.main ?? screens.first
            var frames = screens.map(\.visibleFrame)
            if let home, let index = screens.firstIndex(where: { $0 === home }), index < frames.count {
                frames.insert(frames.remove(at: index), at: 0)
            }
            return frames
        }

        /// A live resize sends a notification per frame: one save a fraction of
        /// a second after the person stops, not one per frame.
        private func saveSoon() {
            guard window != nil else { return }
            saveTask?.cancel()
            saveTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
                self?.saveNow()
            }
        }

        func saveNow() {
            saveTask?.cancel()
            saveTask = nil
            guard let window, !window.styleMask.contains(.fullScreen) else { return }
            DeckPlacement.save(window.frame, in: Profile.active.defaults)
        }
    }
}
