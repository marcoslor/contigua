// The phone window's screen state and the overlay a sleeping panel puts over
// the last frame (docs/design/phone-mirror.md "Screen off and wake"). The model
// is pure: time and views stay outside, so the tests pin every transition.
// The view is only pixels and one button; it forwards no input to the phone.

import AppKit

/// `state.screen`: display 0's power state as the phone reports it.
enum PhoneScreen: String, Equatable {
    case on
    case off
}

/// What the phone window shows over the held frame while the panel sleeps.
struct PhoneScreenOverlay: Equatable {
    /// The last screen the phone reported; nil until a `state` carries it, and
    /// read as "on" (nothing is overlaid on a phone that does not report it).
    private(set) var screen: PhoneScreen?
    /// Every wake this window asked the phone for: one per open/reconnect and
    /// one per Wake Screen click while the overlay is up.
    private(set) var wakeRequests = 0

    init(screen: PhoneScreen? = nil) {
        self.screen = screen
    }

    /// True while the frozen frame is shown as "the screen is off".
    var isShowing: Bool { screen == .off }

    /// A `state` arrived; true when the picture state changed.
    @discardableResult
    mutating func set(screen: PhoneScreen?) -> Bool {
        guard screen != self.screen else { return false }
        self.screen = screen
        return true
    }

    /// The window opened, re-opened or reconnected: display 0 is woken once.
    mutating func opened() {
        wakeRequests += 1
    }

    /// A click on the frame: the Wake Screen button while the overlay is up,
    /// nil (an ordinary touch) on live video.
    mutating func click() -> Bool {
        guard isShowing else { return false }
        wakeRequests += 1
        return true
    }
}

/// The blurred, dimmed frame with the centred message and its Wake Screen
/// button. A click anywhere on it is the button: the view never reaches the
/// input mapper, and the window suspends input while it is up.
final class PhoneScreenOverlayView: NSView {
    /// The person wants the phone's screen back (the window sends `phone.wake`).
    var onWake: (() -> Void)?

    private let blur = NSVisualEffectView()
    private let dim = NSView()
    private let message = NSTextField(labelWithString: "The phone's screen is off")
    private let button = NSButton(title: "Wake Screen", target: nil, action: nil)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        // A strong material over the frozen frame, then a dim layer so white
        // text keeps its contrast over any picture.
        blur.material = .hudWindow
        blur.blendingMode = .withinWindow
        blur.state = .active
        blur.autoresizingMask = [.width, .height]
        addSubview(blur)
        dim.wantsLayer = true
        dim.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.38).cgColor
        dim.autoresizingMask = [.width, .height]
        addSubview(dim)
        message.font = .systemFont(ofSize: 15, weight: .medium)
        message.textColor = .white
        message.alignment = .center
        addSubview(message)
        button.bezelStyle = .rounded
        button.controlSize = .large
        button.target = self
        button.action = #selector(wakePressed)
        addSubview(button)
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isOpaque: Bool { false }

    override func layout() {
        super.layout()
        blur.frame = bounds
        dim.frame = bounds
        let messageSize = message.intrinsicContentSize
        let buttonSize = button.intrinsicContentSize
        let gap: CGFloat = 14
        let total = messageSize.height + gap + buttonSize.height
        let top = (bounds.height - total) / 2
        message.frame = NSRect(x: 0, y: top + gap + buttonSize.height,
                               width: bounds.width, height: messageSize.height)
        button.frame = NSRect(x: (bounds.width - buttonSize.width) / 2, y: top,
                              width: buttonSize.width, height: buttonSize.height)
    }

    /// The button keeps its own click; every other point in the overlay is the
    /// same Wake Screen action, so the whole blurred frame is clickable.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, let superview else { return nil }
        guard bounds.contains(convert(point, from: superview)) else { return nil }
        if let hit = button.hitTest(convert(point, from: superview)) { return hit }
        return self
    }

    override func mouseDown(with event: NSEvent) {
        onWake?()
    }

    @objc private func wakePressed(_ sender: Any?) {
        onWake?()
    }
}
