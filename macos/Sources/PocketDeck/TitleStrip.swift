// The title strip: a band of titlebar height above the video, so the Android
// app lays out fully below the traffic lights instead of under them.
//
// The window keeps its full-size content view and transparent titlebar. With
// the strip on, the video view sits in the safe area below the titlebar and the
// titlebar shows one colour: the average of the video's top rows, sampled a few
// times a second (StripColor.swift) and eased to over a quarter of a second, so
// the app seems to continue up under the traffic lights. The title and the
// controls take the light or dark appearance that suits that colour. With the
// strip off the video ignores the safe area and the titlebar floats over it.
//
// Everything that sizes the virtual display or maps input goes through the
// video view's bounds, so the strip is excluded by construction; `TitleStrip`
// holds the same arithmetic as plain functions for the window code and tests.

import AppKit
import Observation
import SwiftUI

enum TitleStrip {
    /// The titlebar of a window without a toolbar on macOS 26, used until the
    /// window can be asked. In full screen the titlebar is gone and so is the strip.
    static let fallbackHeight: CGFloat = 32

    /// The band reserved above the video.
    static func reservedHeight(titlebar: CGFloat, enabled: Bool) -> CGFloat {
        enabled ? max(titlebar, 0) : 0
    }

    /// The video area of a window whose content, titlebar included, is `content`.
    static func videoSize(content: CGSize, titlebar: CGFloat, enabled: Bool) -> CGSize {
        CGSize(width: content.width,
               height: max(content.height - reservedHeight(titlebar: titlebar, enabled: enabled), 0))
    }

    /// The content height that gives a video area `videoHeight` tall.
    static func contentHeight(videoHeight: CGFloat, titlebar: CGFloat, enabled: Bool) -> CGFloat {
        videoHeight + reservedHeight(titlebar: titlebar, enabled: enabled)
    }

    /// A phone window keeps its phone's aspect ratio in the *video*, not in the
    /// frame: the strip is not part of the picture. The dimension the user moved
    /// more leads; the other follows.
    static func phoneFrame(proposed: CGSize, current: CGSize, phone: CGSize, reserved: CGFloat) -> CGSize {
        guard phone.width > 0, phone.height > 0 else { return proposed }
        let ratio = phone.height / phone.width
        let widthMoved = abs(proposed.width - current.width)
        let heightMoved = abs(proposed.height - current.height)
        if widthMoved * ratio >= heightMoved {
            return CGSize(width: proposed.width, height: (proposed.width * ratio).rounded() + reserved)
        }
        let videoHeight = max(proposed.height - reserved, 0)
        return CGSize(width: (videoHeight / ratio).rounded(), height: proposed.height)
    }
}

/// Per-window strip state the SwiftUI content reads.
@Observable
final class StripState {
    var titleStrip: Bool
    /// The colour the strip is easing to.
    var color = StripColor.black

    init(titleStrip: Bool) { self.titleStrip = titleStrip }
}

private struct VideoHost: NSViewRepresentable {
    let view: VideoLayerView

    func makeNSView(context: Context) -> VideoLayerView { view }
    func updateNSView(_ nsView: VideoLayerView, context: Context) {}
}

struct StreamContent: View {
    let strip: StripState
    let video: VideoLayerView

    var body: some View {
        // One expression for both states, so the video view is never re-made
        // when the strip is toggled. The colour is painted behind the video and
        // reaches up into the titlebar's safe area.
        VideoHost(view: video)
            .ignoresSafeArea(.container, edges: strip.titleStrip ? [] : .top)
            .background {
                if strip.titleStrip {
                    strip.color.color.ignoresSafeArea(.container, edges: .top)
                }
            }
            .animation(.easeInOut(duration: StripColor.easeDuration), value: strip.color)
    }
}

/// With the strip off the traffic lights float over the app: they fade out after
/// two seconds without the pointer near the top edge and fade back in when it
/// comes close, like the controls of full-screen video.
final class TitlebarFader {
    static let idleDelay: TimeInterval = 2
    /// How close to the top edge counts as "near" (points).
    static let nearEdge: CGFloat = 48

    private weak var window: NSWindow?
    private var monitor: Any?
    private var hideWork: DispatchWorkItem?
    private(set) var isShown = true
    private let idleDelay: TimeInterval
    /// Where the pointer is, in screen coordinates.
    private let pointerLocation: () -> NSPoint

    init(window: NSWindow, idleDelay: TimeInterval = TitlebarFader.idleDelay,
         pointerLocation: @escaping () -> NSPoint = { NSEvent.mouseLocation }) {
        self.window = window
        self.idleDelay = idleDelay
        self.pointerLocation = pointerLocation
    }

    deinit { stop() }

    /// True when a pointer at `y` in window coordinates is near the top edge.
    static func isNearTop(y: CGFloat, windowHeight: CGFloat) -> Bool {
        y >= windowHeight - nearEdge
    }

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .mouseEntered, .leftMouseDragged]) { [weak self] event in
            if let self, event.window === self.window { self.pointerMoved(toWindowY: event.locationInWindow.y) }
            return event
        }
        scheduleHide()
    }

    /// Turns the fader off and brings the controls back for good.
    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        hideWork?.cancel()
        hideWork = nil
        fade(to: true, animated: false)
    }

    /// The pointer is at `y` in the window's coordinates.
    func pointerMoved(toWindowY y: CGFloat) {
        guard let window, monitor != nil else { return }
        if Self.isNearTop(y: y, windowHeight: window.frame.height) {
            fade(to: true, animated: true)
            scheduleHide()
        }
    }

    /// Hides after the idle delay unless the pointer is still near the top edge.
    private func scheduleHide() {
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.hideIfIdle() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + idleDelay, execute: work)
    }

    private func hideIfIdle() {
        guard let window, monitor != nil else { return }
        if window.styleMask.contains(.fullScreen) { return }
        let pointer = window.convertPoint(fromScreen: pointerLocation())
        if window.isVisible, Self.isNearTop(y: pointer.y, windowHeight: window.frame.height),
           pointer.x >= 0, pointer.x <= window.frame.width {
            scheduleHide()
            return
        }
        fade(to: false, animated: true)
    }

    private func fade(to visible: Bool, animated: Bool) {
        guard let view = titlebarContainer else { return }
        isShown = visible
        let alpha: CGFloat = visible ? 1 : 0
        guard animated else {
            view.alphaValue = alpha
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = visible ? 0.2 : 0.4
            view.animator().alphaValue = alpha
        }
    }

    /// 1 while the traffic lights and title are shown, 0 once faded out.
    var titlebarAlpha: CGFloat { titlebarContainer?.alphaValue ?? 1 }

    /// The titlebar's container: the ancestor of the traffic lights that hangs
    /// directly off the window's frame view. Fading it fades the title with them.
    private var titlebarContainer: NSView? {
        guard let window, let frameView = window.contentView?.superview else { return nil }
        var view: NSView? = window.standardWindowButton(.closeButton)
        while let current = view, current.superview !== frameView { view = current.superview }
        return view
    }
}
