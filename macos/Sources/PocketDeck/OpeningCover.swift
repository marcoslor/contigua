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
    }

    static let stillAfter: TimeInterval = 5
    static let failAfter: TimeInterval = 20

    let startedAt: TimeInterval
    private(set) var firstFrameAt: TimeInterval?

    init(startedAt: TimeInterval) {
        self.startedAt = startedAt
    }

    var hasFirstFrame: Bool { firstFrameAt != nil }
    /// The cover is over the window while no frame has arrived.
    var isUp: Bool { firstFrameAt == nil }

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
        let elapsed = time - startedAt
        if elapsed >= Self.failAfter { return .failed }
        if elapsed >= Self.stillAfter { return .stillLoading }
        return .loading
    }

    /// Try Again: the open goes again; the cover starts its clock over. A
    /// window whose frame is already in has no cover to retry.
    mutating func retry(at time: TimeInterval) {
        guard firstFrameAt == nil else { return }
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
        spinner.isHidden = phase == .failed
        if phase == .failed {
            spinner.stopAnimation(nil)
        } else {
            spinner.startAnimation(nil)
        }
        message.stringValue = OpeningCover.message(phase, name: name, phone: phone)
        let failed = phase == .failed
        retry.isHidden = !failed
        close.isHidden = !failed
        needsLayout = true
    }

    override func layout() {
        super.layout()
        blur.frame = bounds
        dim.frame = bounds
        let iconSide: CGFloat = 64
        let nameHeight = nameLabel.intrinsicContentSize.height
        let messageHeight = message.intrinsicContentSize.height
        let spinnerSide: CGFloat = 16
        let buttons = retry.isHidden ? 0 : retry.intrinsicContentSize.height
        let gap: CGFloat = 10
        let total = iconSide + gap + nameHeight + gap + spinnerSide + gap + messageHeight
            + (buttons > 0 ? gap + buttons : 0)
        var y = (bounds.height + total) / 2
        y -= iconSide
        iconView.frame = NSRect(x: (bounds.width - iconSide) / 2, y: y, width: iconSide, height: iconSide)
        y -= gap + nameHeight
        nameLabel.frame = NSRect(x: 24, y: y, width: bounds.width - 48, height: nameHeight)
        y -= gap + spinnerSide
        spinner.frame = NSRect(x: (bounds.width - spinnerSide) / 2, y: y + 2,
                               width: spinnerSide, height: spinnerSide)
        y -= gap + messageHeight
        message.frame = NSRect(x: 24, y: y, width: bounds.width - 48, height: messageHeight)
        if buttons > 0 {
            y -= gap + buttons
            let retryWidth = retry.intrinsicContentSize.width
            let closeWidth = close.intrinsicContentSize.width
            let spacing: CGFloat = 12
            let x = (bounds.width - retryWidth - closeWidth - spacing) / 2
            retry.frame = NSRect(x: x, y: y, width: retryWidth, height: buttons)
            close.frame = NSRect(x: x + retryWidth + spacing, y: y, width: closeWidth, height: buttons)
        }
    }

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
