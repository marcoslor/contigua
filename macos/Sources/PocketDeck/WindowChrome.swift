// Stream window chrome: at rest the window shows only the stream (rounded
// corners and its shadow). The window's left, right and bottom edges are the
// stream's, so the system resize edges sit right at the visible picture. Above
// the stream is a header band, fully transparent at rest so clicks there fall
// through to whatever is behind. When the pointer comes to the stream's top
// edge or onto the band, the band fades in as glass with the traffic lights
// and the window's actions.
//
// The stream never moves, resizes or gets covered: the virtual display is sized
// from the stream rectangle alone, so hovering changes nothing on the phone.

import AppKit
import SwiftUI

enum WindowChrome {
    /// The band above the stream that holds the traffic lights and the actions:
    /// a standard toolbar window's title area, so the traffic lights sit where
    /// they do in every other app (centred 26 pt from the left and the top).
    static let headerHeight: CGFloat = 52
    /// Where the traffic lights' centre line is, from the window's top edge.
    static let trafficLightCentre: CGFloat = 26
    /// The stream's own corners, as a window's; the glass follows them.
    static let streamCornerRadius: CGFloat = 16
    /// How close to the stream's top edge the pointer has to come to bring the header in.
    static let hoverZone: CGFloat = 12
    static let fadeInDuration: TimeInterval = 0.1
    static let fadeOutDuration: TimeInterval = 0.15
    /// The header stays this long after the pointer leaves it (nothing holds it then).
    static let hideDelay: TimeInterval = 0

    /// The padding between the window's frame and the stream: the header band
    /// only (none in full screen).
    static func insets(fullScreen: Bool) -> NSEdgeInsets {
        fullScreen ? NSEdgeInsets() : NSEdgeInsets(top: headerHeight, left: 0, bottom: 0, right: 0)
    }

    /// The window that holds a stream `stream` big.
    static func windowSize(stream: CGSize, fullScreen: Bool = false) -> CGSize {
        let pad = insets(fullScreen: fullScreen)
        return CGSize(width: stream.width + pad.left + pad.right, height: stream.height + pad.top + pad.bottom)
    }

    /// The stream inside a window `window` big.
    static func streamSize(window: CGSize, fullScreen: Bool = false) -> CGSize {
        let pad = insets(fullScreen: fullScreen)
        return CGSize(width: max(window.width - pad.left - pad.right, 0),
                      height: max(window.height - pad.top - pad.bottom, 0))
    }

    /// True when a pointer `y` points above the bottom of a stream `height` tall is in the hover zone.
    static func isInHoverZone(y: CGFloat, height: CGFloat) -> Bool {
        y >= height - hoverZone && y <= height
    }
}

/// When the header shows. The pointer at the top brings it in; an open menu or
/// a drag only keeps it (a menu-bar menu must not summon it); once nothing
/// holds it, it goes `hideDelay` later (at once by default). Time is passed in, so tests need no clock.
struct HeaderHover: Equatable {
    var pointerOver = false
    var menuOpen = false
    var dragging = false
    private(set) var visible = false
    /// When the header hides unless something holds it before then.
    private(set) var hideAt: TimeInterval?

    let hideDelay: TimeInterval

    init(hideDelay: TimeInterval = WindowChrome.hideDelay) { self.hideDelay = hideDelay }

    private var held: Bool { pointerOver || (visible && (menuOpen || dragging)) }

    /// Folds the inputs and the time into `visible` / `hideAt`.
    mutating func update(now: TimeInterval) {
        if held {
            visible = true
            hideAt = nil
        } else if visible {
            let due = hideAt ?? now + hideDelay
            if now >= due {
                visible = false
                hideAt = nil
            } else {
                hideAt = due
            }
        }
    }
}

/// The buttons that live next to the traffic lights in the window kinds that
/// have them: plain icons in one row.
struct HeaderControls: View {
    static let buttonWidth: CGFloat = 32
    static let buttonHeight: CGFloat = 28
    let actions: [HeaderAction]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(actions) { action in
                Button(action: action.perform) {
                    Image(systemName: action.symbol)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)
                        .frame(width: Self.buttonWidth, height: Self.buttonHeight)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusable(false)
                .help(action.help)
                .accessibilityLabel(action.help)
            }
        }
    }
}

/// A button at the bar's right end (the phone window's Back/Home/Recents).
struct HeaderAction: Identifiable {
    let symbol: String
    let help: String
    let perform: () -> Void

    var id: String { symbol }
}

/// The band above the stream: the traffic lights sit over its left end, the
/// actions at its right. Dragging it moves the window.
final class HeaderView: NSView {
    private let controls: NSHostingView<HeaderControls>
    var onDrag: ((Bool) -> Void)?

    init(actions: [HeaderAction]) {
        controls = NSHostingView(rootView: HeaderControls(actions: actions))
        super.init(frame: .zero)
        controls.sizingOptions = []
        // The header sits under the toolbar area; its safe area would push the buttons down.
        controls.safeAreaRegions = []
        addSubview(controls)
        setAccessibilityElement(true)
        setAccessibilityRole(.toolbar)
        setAccessibilityIdentifier("stream-header")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func setActions(_ actions: [HeaderAction]) {
        controls.rootView = HeaderControls(actions: actions)
        needsLayout = true
    }

    /// The buttons at the right, for tests.
    var actionCount: Int { controls.rootView.actions.count }

    override func layout() {
        super.layout()
        // On the traffic lights' line, as far in from the right as they are from the left.
        let width = CGFloat(actionCount) * HeaderControls.buttonWidth
        let centre = bounds.height - WindowChrome.trafficLightCentre
        controls.frame = NSRect(x: bounds.width - width - 12, y: centre - HeaderControls.buttonHeight / 2,
                                width: width, height: HeaderControls.buttonHeight)
    }

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        if event.clickCount == 2 {
            window.performZoom(nil)
            return
        }
        onDrag?(true)
        window.performDrag(with: event)
        onDrag?(false)
    }
}

/// The window's content: the stream below the header band, the glass behind
/// both, and the header band on top. At rest the glass and the header are fully
/// transparent, so the window shows only the stream and clicks in the band fall
/// through to what is behind.
final class StreamContainerView: NSView {
    let video: VideoLayerView
    let header: HeaderView
    let glass = NSGlassEffectView()
    /// A click reached the header band (the e2e check wants none at rest).
    var onPaddingClick: (() -> Void)?

    init(video: VideoLayerView, header: HeaderView) {
        self.video = video
        self.header = header
        super.init(frame: NSRect(origin: .zero, size: WindowChrome.windowSize(stream: video.frame.size)))
        glass.cornerRadius = WindowChrome.streamCornerRadius
        glass.style = .clear
        addSubview(glass)
        video.wantsLayer = true
        video.layer?.cornerRadius = WindowChrome.streamCornerRadius
        video.layer?.cornerCurve = .continuous
        video.layer?.masksToBounds = true
        addSubview(video)
        addSubview(header)
        layoutChrome()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Where a window point is, for the hover and the click pass-through.
    enum Region { case outside, streamTop, stream, header }

    func region(of point: NSPoint) -> Region {
        guard bounds.contains(point) else { return .outside }
        if video.frame.contains(point) {
            return WindowChrome.isInHoverZone(y: point.y - video.frame.minY, height: video.frame.height) ? .streamTop : .stream
        }
        return .header
    }

    /// The views that fade in and out.
    var chromeViews: [NSView] { [glass, header] }

    override var isOpaque: Bool { false }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        layoutChrome()
    }

    func layoutChrome() {
        let pad = WindowChrome.insets(fullScreen: window?.styleMask.contains(.fullScreen) ?? false)
        glass.frame = bounds
        video.frame = NSRect(x: pad.left, y: pad.bottom, width: max(bounds.width - pad.left - pad.right, 0),
                             height: max(bounds.height - pad.top - pad.bottom, 0))
        header.frame = NSRect(x: 0, y: bounds.height - pad.top, width: bounds.width, height: pad.top)
        header.isHidden = pad.top == 0
    }

    override func mouseDown(with event: NSEvent) {
        onPaddingClick?()
        window?.performDrag(with: event)
    }
}

/// Runs `HeaderHover` for one window: feeds it the pointer, menus and drags,
/// re-checks it when a hide is due and fades the header and traffic lights.
final class HeaderController {
    private weak var window: NSWindow?
    private let container: StreamContainerView
    private(set) var paddingClicks = 0
    private(set) var state: HeaderHover
    private let now: () -> TimeInterval
    private var hideTimer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var monitors: [Any] = []
    /// `--debug-chrome-state FILE`: the e2e check reads the header's state here.
    var stateFile: URL? { didSet { writeState() } }

    init(window: NSWindow, container: StreamContainerView, hideDelay: TimeInterval = WindowChrome.hideDelay,
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.window = window
        self.container = container
        self.state = HeaderHover(hideDelay: hideDelay)
        self.now = now
        container.onPaddingClick = { [weak self] in
            self?.paddingClicks += 1
            self?.writeState()
        }
        container.header.onDrag = { [weak self] dragging in self?.setDragging(dragging) }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil,
                                            queue: .main) { [weak self] _ in self?.setMenuOpen(true) })
        observers.append(center.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil,
                                            queue: .main) { [weak self] _ in self?.setMenuOpen(false) })
        apply(animated: false)
    }

    deinit {
        hideTimer?.invalidate()
        observers.forEach(NotificationCenter.default.removeObserver)
        monitors.forEach(NSEvent.removeMonitor)
    }

    /// Follows the pointer wherever it is. At rest the window ignores the mouse
    /// while the pointer is over the invisible band (a transparent titled
    /// window still takes those clicks), so it gets no events there: the global
    /// monitor sees the moves instead. Mouse moves need no special permission.
    func start() {
        guard monitors.isEmpty else { return }
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            self?.pointerMoved(toScreen: NSEvent.mouseLocation)
            return event
        }) { monitors.append(local) }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in
            self?.pointerMoved(toScreen: NSEvent.mouseLocation)
        }) { monitors.append(global) }
        pointerMoved(toScreen: NSEvent.mouseLocation)
    }

    func pointerMoved(toScreen point: NSPoint) {
        guard let window, window.isVisible else { return }
        pointerMoved(toWindowPoint: window.convertPoint(fromScreen: point))
    }

    private var region = StreamContainerView.Region.outside

    /// The pointer is at `point` in window coordinates (also the scripted driver's hover).
    func pointerMoved(toWindowPoint point: NSPoint) {
        region = container.region(of: container.convert(point, from: nil))
        state.pointerOver = region == .streamTop || region == .header
        refresh()
    }

    /// Clicks over the invisible band belong to whatever is behind the window.
    private func updateClickThrough() {
        guard let window else { return }
        let through = !state.visible && region == .header
        if window.ignoresMouseEvents != through { window.ignoresMouseEvents = through }
    }

    var isVisible: Bool { state.visible }

    func setMenuOpen(_ open: Bool) {
        state.menuOpen = open
        refresh()
    }

    /// A header drag or a live resize.
    func setDragging(_ dragging: Bool) {
        state.dragging = dragging
        refresh()
    }

    func stop() {
        hideTimer?.invalidate()
        hideTimer = nil
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
    }

    /// Re-evaluates the state now; also what the hide timer calls.
    func refresh() {
        let wasVisible = state.visible
        state.update(now: now())
        hideTimer?.invalidate()
        hideTimer = nil
        if let hideAt = state.hideAt {
            let timer = Timer(timeInterval: max(hideAt - now(), 0), repeats: false) { [weak self] _ in
                self?.refresh()
            }
            RunLoop.main.add(timer, forMode: .common)
            hideTimer = timer
        }
        if wasVisible != state.visible { apply(animated: true) }
        updateClickThrough()
    }

    private func apply(animated: Bool) {
        let visible = state.visible
        let buttons = trafficLights
        // At rest the traffic lights are hidden, so a click at the top of the
        // stream cannot close the window by accident. Their alpha goes back to 1
        // once hidden: ⌘W and ⌘M "click" them, and AppKit ignores a transparent button.
        if visible {
            buttons.filter(\.isHidden).forEach {
                $0.alphaValue = 0
                $0.isHidden = false
            }
        }
        let alpha: CGFloat = visible ? 1 : 0
        let views: [NSView] = container.chromeViews + buttons
        let finish = { [weak self] in
            guard let self, self.state.visible == visible else { return }
            if !visible {
                buttons.forEach {
                    $0.isHidden = true
                    $0.alphaValue = 1
                }
            }
            // The shadow follows the visible shape: the stream alone at rest.
            self.window?.invalidateShadow()
            self.writeState()
        }
        guard animated else {
            views.forEach { $0.alphaValue = alpha }
            finish()
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = visible ? WindowChrome.fadeInDuration : WindowChrome.fadeOutDuration
            views.forEach { $0.animator().alphaValue = alpha }
        }, completionHandler: finish)
    }

    private var trafficLights: [NSButton] {
        guard let window else { return [] }
        return [.closeButton, .miniaturizeButton, .zoomButton].compactMap { window.standardWindowButton($0) }
    }

    private func writeState() {
        guard let stateFile else { return }
        let lights = trafficLights.contains { !$0.isHidden }
        let line = "header=\(state.visible ? "shown" : "hidden") lights=\(lights ? "shown" : "hidden") clicks=\(paddingClicks)\n"
        try? Data(line.utf8).write(to: stateFile, options: .atomic)
    }
}
