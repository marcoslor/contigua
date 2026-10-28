// The cover an app window (and the phone window) shows from the moment it
// opens until its first frame (docs/UX.md "Opening a window"): the app's icon
// and name, a spinner, "Opening on your phone…", then "Still opening…", then
// "Couldn't open <app>." with Try Again and Close. It is a frozen mode: no
// input reaches the phone, and the stall watchdog does not run before the
// first frame (there is no live picture to be stale yet).
//
// The state is pure and driven by a clock, so the tests pin every edge: the
// 5 s and 20 s marks, the first frame ending it, and Try Again restarting it.

import AppKit

struct OpeningCover: Equatable {
    enum Phase: Equatable {
        case loading
        case stillLoading
        case failed
        /// The phone said it cannot do this at all: one sentence, Close only.
        case unavailable
    }

    /// A refusal the phone stated about the open itself. It is terminal: no
    /// clock moves it, Try Again cannot restart it and nothing is resent.
    enum Refusal: Equatable {
        case mirrorUnavailable

        /// The phone's `error` code for a refused open, or nil when the code
        /// is something else (a launch failure, a bad request).
        init?(errorCode: String) {
            switch errorCode {
            case "mirror_unavailable": self = .mirrorUnavailable
            default: return nil
            }
        }

        var sentence: String {
            switch self {
            case .mirrorUnavailable: return "This phone can't share its screen with PocketDeck."
            }
        }
    }

    static let stillAfter: TimeInterval = 5
    static let failAfter: TimeInterval = 20

    let startedAt: TimeInterval
    private(set) var firstFrameAt: TimeInterval?
    private(set) var refusal: Refusal?

    init(startedAt: TimeInterval) {
        self.startedAt = startedAt
    }

    var hasFirstFrame: Bool { firstFrameAt != nil }
    /// The cover is over the window while no frame has arrived.
    var isUp: Bool { firstFrameAt == nil }
    /// Try Again only exists for the 20 s failure: not before it, and never
    /// after the phone refused the open (MIRROR-2).
    var canRetry: Bool { firstFrameAt == nil && refusal == nil }

    /// The phone refused the open: the cover says why for good.
    @discardableResult
    mutating func refuse(_ refusal: Refusal) -> Bool {
        guard firstFrameAt == nil, self.refusal == nil else { return false }
        self.refusal = refusal
        return true
    }

    /// The first frame arrived; true when it ended the cover.
    @discardableResult
    mutating func firstFrame(at time: TimeInterval) -> Bool {
        guard firstFrameAt == nil else { return false }
        firstFrameAt = time
        return true
    }

    /// What the cover says now, or nil once the first frame is in.
    func phase(at time: TimeInterval) -> Phase? {
        guard firstFrameAt == nil else { return nil }
        if refusal != nil { return .unavailable }
        let elapsed = time - startedAt
        if elapsed >= Self.failAfter { return .failed }
        if elapsed >= Self.stillAfter { return .stillLoading }
        return .loading
    }

    /// Try Again: the open goes again; the cover starts its clock over. A
    /// window whose frame is already in has no cover to retry, and a phone
    /// that refused the open never gets a second request (MIRROR-2).
    mutating func retry(at time: TimeInterval) {
        guard canRetry else { return }
        self = OpeningCover(startedAt: time)
    }

    /// The sentence the cover carries. `name` is the app's label; the phone
    /// window passes its own wording.
    static func message(_ phase: Phase, name: String, phone: Bool) -> String {
        switch phase {
        case .loading:
            return phone ? "Opening your phone…" : "Opening on your phone…"
        case .stillLoading:
            return "Still opening…"
        case .failed:
            return phone ? "Couldn't open your phone." : "Couldn't open \(name)."
        case .unavailable:
            return Refusal.mirrorUnavailable.sentence
        }
    }
}

/// The glass/blurred cover, the same family as the screen-off and secure
/// covers (PhoneScreenOverlayView): material, dim, icon, name, spinner, the
/// sentence and, after 20 s, Try Again and Close. It swallows every click
/// except those buttons: the phone sees nothing while it is up.
final class OpeningCoverView: NSView {
    var onRetry: (() -> Void)?
    var onClose: (() -> Void)?

    private let blur = NSVisualEffectView()
    private let dim = NSView()
    private let iconView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()
    private let message = NSTextField(labelWithString: "")
    private let retry = NSButton(title: "Try Again", target: nil, action: nil)
    private let close = NSButton(title: "Close", target: nil, action: nil)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        blur.material = .hudWindow
        blur.blendingMode = .withinWindow
        blur.state = .active
        blur.autoresizingMask = [.width, .height]
        addSubview(blur)
        dim.wantsLayer = true
        dim.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.38).cgColor
        dim.autoresizingMask = [.width, .height]
        addSubview(dim)

        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.wantsLayer = true
        iconView.layer?.cornerRadius = 13
        iconView.layer?.cornerCurve = .continuous
        iconView.layer?.masksToBounds = true
        addSubview(iconView)

        nameLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        nameLabel.textColor = .white
        nameLabel.alignment = .center
        nameLabel.lineBreakMode = .byTruncatingTail
        addSubview(nameLabel)

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        addSubview(spinner)

        message.font = .systemFont(ofSize: 13, weight: .regular)
        message.textColor = NSColor.white.withAlphaComponent(0.78)
        message.alignment = .center
        // The refusal is a whole sentence: it wraps instead of being cut at the
        // narrow phone window's edge.
        message.maximumNumberOfLines = 0
        message.lineBreakMode = .byWordWrapping
        message.cell?.wraps = true
        addSubview(message)

        retry.bezelStyle = .rounded
        retry.controlSize = .large
        retry.target = self
        retry.action = #selector(retryPressed)
        addSubview(retry)
        close.bezelStyle = .rounded
        close.controlSize = .large
        close.target = self
        close.action = #selector(closePressed)
        addSubview(close)

        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isOpaque: Bool { false }

    /// Shows the cover for `phase`, or takes it away (nil: the first frame is
    /// in and the pane is gone).
    func show(_ phase: OpeningCover.Phase?, name: String, icon: NSImage?, phone: Bool) {
        guard let phase else {
            isHidden = true
            spinner.stopAnimation(nil)
            return
        }
        isHidden = false
        iconView.image = icon
        iconView.isHidden = icon == nil
        nameLabel.stringValue = name
        let failed = phase == .failed
        let terminal = failed || phase == .unavailable
        spinner.isHidden = terminal
        if terminal {
            spinner.stopAnimation(nil)
        } else {
            spinner.startAnimation(nil)
        }
        message.stringValue = OpeningCover.message(phase, name: name, phone: phone)
        // Try Again only for the 20 s failure: a phone that refused the open
        // gets Close and nothing that would ask it again (MIRROR-2).
        retry.isHidden = !failed
        close.isHidden = !terminal
        needsLayout = true
    }

    /// The sentence on screen: the e2e's proof that the refusal is the
    /// documented one, not a generic failure.
    var displayedMessage: String { message.stringValue }

    override func layout() {
        super.layout()
        blur.frame = bounds
        dim.frame = bounds
        let sideInset: CGFloat = 24
        let textWidth = max(bounds.width - sideInset * 2, 80)
        let iconSide: CGFloat = 64
        let gap: CGFloat = 10
        let spinnerSide: CGFloat = 16
        let nameHeight = nameLabel.intrinsicContentSize.height
        let messageHeight = message.sizeThatFits(NSSize(width: textWidth,
                                                        height: .greatestFiniteMagnitude)).height
        // The buttons that are up: Close alone for a refusal, Try Again and
        // Close for the 20 s failure, none before it.
        let buttons = [retry, close].filter { !$0.isHidden }
        let buttonHeight = buttons.map { $0.intrinsicContentSize.height }.max() ?? 0
        let total = iconSide + gap + nameHeight + gap + spinnerSide + gap + messageHeight
            + (buttons.isEmpty ? 0 : gap + buttonHeight)
        var y = (bounds.height + total) / 2
        y -= iconSide
        iconView.frame = NSRect(x: (bounds.width - iconSide) / 2, y: y, width: iconSide, height: iconSide)
        y -= gap + nameHeight
        nameLabel.frame = NSRect(x: sideInset, y: y, width: textWidth, height: nameHeight)
        y -= gap + spinnerSide
        spinner.frame = NSRect(x: (bounds.width - spinnerSide) / 2, y: y + 2,
                               width: spinnerSide, height: spinnerSide)
        y -= gap + messageHeight
        message.frame = NSRect(x: sideInset, y: y, width: textWidth, height: messageHeight)
        guard !buttons.isEmpty else { return }
        y -= gap + buttonHeight
        let widths = buttons.map { $0.intrinsicContentSize.width }
        let spacing: CGFloat = 12
        let rowWidth = widths.reduce(0, +) + CGFloat(buttons.count - 1) * spacing
        var x = (bounds.width - rowWidth) / 2
        for (button, width) in zip(buttons, widths) {
            button.frame = NSRect(x: x, y: y, width: width, height: buttonHeight)
            x += width + spacing
        }
    }

    /// The sentence's drawn frame and the buttons that are up: the layout tests
    /// read them (MIRROR-2's sentence wraps, and a refusal shows Close alone).
    var messageFrame: NSRect { message.frame }
    var messageText: String { message.stringValue }
    var visibleButtonFrames: [NSRect] { [retry, close].filter { !$0.isHidden }.map(\.frame) }

    /// The buttons keep their clicks; every other point is swallowed: the
    /// window must not send anything to the phone while the cover is up.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, let superview else { return nil }
        guard bounds.contains(convert(point, from: superview)) else { return nil }
        for button in [retry, close] where !button.isHidden {
            if let hit = button.hitTest(convert(point, from: superview)) { return hit }
        }
        return self
    }

    @objc private func retryPressed(_ sender: Any?) { onRetry?() }
    @objc private func closePressed(_ sender: Any?) { onClose?() }
}
