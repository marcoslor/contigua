// The cover a stream window shows from the moment it opens until its first
// frame (docs/UX.md "Opening a window", the L1 design): a large app icon on the
// window's dark background, a 2 pt accent line sweeping under the title bar and
// the title "<App> — opening on <phone>". At 5 s a secondary line and Cancel
// join it; the phone's refusal or 20 s brings the grey icon, one sentence and a
// reason line, with Close alone. The phone window wears the same cover with
// "phone screen" wording.
//
// One explicit machine: a closed set of states, the events it accepts and a
// pure transition that returns actions (AGENTS.md). The controller runs the
// actions, logs each transition and drives the view.

import AppKit
import CoreImage

struct OpeningCover: Equatable {
    /// What the cover shows now.
    enum Phase: Equatable {
        case opening
        case slow
        case failed(reason: String?)
    }

    /// The machine's closed states. `live` and `closed` both mean the cover is
    /// over, but one is the first frame and the other the person's Cancel.
    enum State: Equatable {
        case opening
        case slow
        case failed(reason: String?)
        case live
        case closed
    }

    enum Event: Equatable {
        /// The clock moved.
        case tick(TimeInterval)
        /// The stream's first frame arrived.
        case firstFrame
        /// The phone refused the open with this `error` code.
        case refused(String)
        /// The person pressed Cancel.
        case cancel
    }

    /// Side effects the caller runs; the transition performs none.
    enum Action: Equatable {
        case closeWindow
    }

    static let slowAfter: TimeInterval = 5
    static let failAfter: TimeInterval = 20

    let startedAt: TimeInterval
    private(set) var state: State = .opening

    init(startedAt: TimeInterval) {
        self.startedAt = startedAt
    }

    var isUp: Bool {
        switch state {
        case .opening, .slow, .failed: return true
        case .live, .closed: return false
        }
    }

    /// The phase on screen, or nil once the cover is over. The clock-driven
    /// part is derived from `startedAt` as well as from the machine's ticks, so
    /// a state read between two ticks is never a stale phase.
    func phase(at time: TimeInterval) -> Phase? {
        switch state {
        case .opening, .slow:
            let elapsed = time - startedAt
            if elapsed >= Self.failAfter { return .failed(reason: nil) }
            if elapsed >= Self.slowAfter { return .slow }
            return .opening
        case .failed(let reason):
            return .failed(reason: reason)
        case .live, .closed:
            return nil
        }
    }

    /// The machine's one transition. `nil` means the event is ignored in this
    /// state (the same state and no actions): the caller then logs nothing.
    @discardableResult
    mutating func handle(_ event: Event, at now: TimeInterval) -> [Action]? {
        let (next, actions) = Self.transition(state, event, startedAt: startedAt, now: now)
        guard next != state else { return nil }
        state = next
        return actions
    }

    static func transition(_ state: State, _ event: Event,
                           startedAt: TimeInterval, now: TimeInterval) -> (State, [Action]) {
        switch state {
        case .live, .closed:
            // A finished window has no cover to move.
            return (state, [])
        case .failed:
            switch event {
            case .firstFrame:
                // The picture came after all: the cover goes.
                return (.live, [])
            case .refused:
                // The first refusal is the one the window reports.
                return (state, [])
            case .tick, .cancel:
                return (state, [])
            }
        case .opening:
            switch event {
            case .tick(let time):
                let elapsed = time - startedAt
                if elapsed >= failAfter { return (.failed(reason: nil), []) }
                if elapsed >= slowAfter { return (.slow, []) }
                return (state, [])
            case .firstFrame:
                return (.live, [])
            case .refused(let code):
                return (.failed(reason: reason(for: code)), [])
            case .cancel:
                return (.closed, [.closeWindow])
            }
        case .slow:
            switch event {
            case .tick(let time):
                if time - startedAt >= failAfter { return (.failed(reason: nil), []) }
                return (state, [])
            case .firstFrame:
                return (.live, [])
            case .refused(let code):
                return (.failed(reason: reason(for: code)), [])
            case .cancel:
                return (.closed, [.closeWindow])
            }
        }
    }

    /// The reason line for a phone `error` code, or nil when the code is not
    /// one the cover can explain (no reason line, never a raw code).
    static func reason(for code: String) -> String? {
        switch code {
        case "app_disabled": return "The app is disabled on the phone."
        case "app_missing", "not_installed": return "The app isn't installed any more."
        case "mirror_unavailable": return "This phone can't share its screen with PocketDeck."
        case "launch_failed", "bad_request", "bad_size", "no_stream", "internal": return nil
        default: return nil
        }
    }

    /// "<App> — opening on <phone>": what the cover's own title says.
    static func title(name: String, phone: String, phoneMode: Bool) -> String {
        let subject = phoneMode ? "Phone" : name
        let place = phone.isEmpty ? "your phone" : phone
        return "\(subject) — opening on \(place)"
    }

    /// The failure's one sentence, in the app's or the mirror's wording.
    static func lead(name: String, phone: String, phoneMode: Bool) -> String {
        let place = phone.isEmpty ? "your phone" : phone
        return phoneMode ? "\(place) can't open the phone screen."
                         : "\(place) can't open \(name)."
    }

    /// What a state shows, as the view draws it. nil once the cover is over.
    struct Display: Equatable {
        var phase: Phase
        var title: String
        var secondary: String?
        var lead: String?
        var reason: String?
        var showsCancel: Bool
        var showsClose: Bool
    }

    static func display(_ phase: Phase?, name: String, phone: String, phoneMode: Bool) -> Display? {
        guard let phase else { return nil }
        switch phase {
        case .opening:
            return Display(phase: phase, title: title(name: name, phone: phone, phoneMode: phoneMode),
                           secondary: nil, lead: nil, reason: nil, showsCancel: false, showsClose: false)
        case .slow:
            return Display(phase: phase, title: title(name: name, phone: phone, phoneMode: phoneMode),
                           secondary: "Taking longer than usual", lead: nil, reason: nil,
                           showsCancel: true, showsClose: false)
        case .failed(let reason):
            return Display(phase: phase, title: title(name: name, phone: phone, phoneMode: phoneMode),
                           secondary: nil,
                           lead: lead(name: name, phone: phone, phoneMode: phoneMode),
                           reason: reason, showsCancel: false, showsClose: true)
        }
    }

    /// The state's name for the transition log.
    static func label(_ state: State) -> String {
        switch state {
        case .opening: return "opening"
        case .slow: return "slow"
        case .failed: return "failed"
        case .live: return "live"
        case .closed: return "closed"
        }
    }
}

/// The L1 cover: the dark ground, the icon, the accent sweep, the title and,
/// as the machine says, the slow line with Cancel or the failure with its
/// reason and Close. It swallows every click except its buttons: the phone sees
/// nothing while it is up.
final class OpeningCoverView: NSView {
    var onCancel: (() -> Void)?
    var onClose: (() -> Void)?
    /// The cover came or went: the chrome lays out with the immersive geometry
    /// while it is up (WIN-11). Fires only on a visibility change, never per
    /// phase tick.
    var onVisibilityChange: (() -> Void)?

    private let ground = NSView()
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let sweep = NSView()
    private let sweepLayer = CAGradientLayer()
    private let secondary = NSTextField(labelWithString: "")
    private let lead = NSTextField(labelWithString: "")
    private let reason = NSTextField(labelWithString: "")
    private let cancel = NSButton(title: "Cancel", target: nil, action: nil)
    private let close = NSButton(title: "Close", target: nil, action: nil)

    /// The 2 pt accent line under the title bar; the tests read it.
    var sweepFrame: NSRect { sweep.frame }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        ground.wantsLayer = true
        ground.layer?.backgroundColor = NSColor(white: 0.09, alpha: 1).cgColor
        ground.autoresizingMask = [.width, .height]
        addSubview(ground)

        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.wantsLayer = true
        iconView.layer?.cornerRadius = 22
        iconView.layer?.cornerCurve = .continuous
        iconView.layer?.masksToBounds = true
        addSubview(iconView)

        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        titleLabel.textColor = NSColor(white: 0.94, alpha: 1)
        titleLabel.alignment = .center
        titleLabel.lineBreakMode = .byTruncatingTail
        addSubview(titleLabel)

        // The indeterminate line: a short accent segment sweeping left to
        // right, not a percentage. It sits at the cover's top edge, directly
        // under the window's title bar.
        sweep.wantsLayer = true
        sweepLayer.colors = [NSColor.controlAccentColor.withAlphaComponent(0).cgColor,
                             NSColor.controlAccentColor.cgColor,
                             NSColor.controlAccentColor.withAlphaComponent(0).cgColor]
        sweepLayer.startPoint = CGPoint(x: 0, y: 0.5)
        sweepLayer.endPoint = CGPoint(x: 1, y: 0.5)
        sweepLayer.locations = [0, 0.5, 1]
        sweep.layer?.addSublayer(sweepLayer)
        addSubview(sweep)

        secondary.font = .systemFont(ofSize: 12)
        secondary.textColor = NSColor(white: 0.66, alpha: 1)
        secondary.alignment = .center
        addSubview(secondary)

        lead.font = .systemFont(ofSize: 15, weight: .semibold)
        lead.textColor = NSColor(white: 0.94, alpha: 1)
        lead.alignment = .center
        lead.maximumNumberOfLines = 0
        lead.lineBreakMode = .byWordWrapping
        lead.cell?.wraps = true
        addSubview(lead)

        reason.font = .systemFont(ofSize: 12.5)
        reason.textColor = NSColor(white: 0.7, alpha: 1)
        reason.alignment = .center
        reason.maximumNumberOfLines = 0
        reason.lineBreakMode = .byWordWrapping
        reason.cell?.wraps = true
        addSubview(reason)

        for button in [cancel, close] {
            button.bezelStyle = .rounded
            button.controlSize = .large
            button.target = self
            // The cover's ground is dark in either appearance: a light-mode
            // button would draw dark text on it (the first capture showed a
            // Cancel nobody could read).
            button.appearance = NSAppearance(named: .darkAqua)
        }
        cancel.action = #selector(cancelPressed)
        close.action = #selector(closePressed)
        addSubview(cancel)
        addSubview(close)

        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isOpaque: Bool { false }

    /// Shows what the machine says, or takes the cover away (nil: the picture
    /// is in or the person closed it).
    func show(_ display: OpeningCover.Display?, icon: NSImage?) {
        let wasUp = !isHidden
        defer {
            if (!isHidden) != wasUp { onVisibilityChange?() }
        }
        guard let display else {
            isHidden = true
            stopSweep()
            return
        }
        isHidden = false
        let failed: Bool
        if case .failed = display.phase { failed = true } else { failed = false }
        // Before the app's icon has arrived (or for an app with none), a
        // generic app mark keeps the cover's one large picture.
        let picture = icon ?? NSImage(systemSymbolName: "app.dashed", accessibilityDescription: nil)
        if failed, picture?.isTemplate == false {
            // A real app icon keeps its shape without its colour.
            iconView.image = picture?.greyed()
            iconView.contentTintColor = nil
            iconView.alphaValue = 0.55
        } else {
            // A symbol is a template: greying it with a colour filter turns it
            // black; its tint is what greys it.
            iconView.image = picture
            iconView.contentTintColor = failed ? .systemGray : NSColor(white: 0.92, alpha: 1)
            iconView.alphaValue = 1
        }
        iconView.isHidden = picture == nil
        // The failure's sentence already names the app and the phone; the
        // "opening on" title would contradict it.
        titleLabel.stringValue = failed ? "" : display.title
        titleLabel.isHidden = failed
        secondary.stringValue = display.secondary ?? ""
        secondary.isHidden = display.secondary == nil
        lead.stringValue = display.lead ?? ""
        lead.isHidden = display.lead == nil
        reason.stringValue = display.reason ?? ""
        reason.isHidden = display.reason == nil
        cancel.isHidden = !display.showsCancel
        close.isHidden = !display.showsClose
        startSweep(active: !failed)
        needsLayout = true
    }

    private func startSweep(active: Bool) {
        sweep.isHidden = !active
        sweepLayer.frame = sweep.bounds
        sweepLayer.removeAnimation(forKey: "sweep")
        guard active else { return }
        // Reduce Motion keeps the line as a still mark rather than a sweep.
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            sweepLayer.locations = [0.3, 0.45, 0.6]
            return
        }
        sweepLayer.locations = [0, 0.5, 1]
        let animation = CABasicAnimation(keyPath: "locations")
        animation.fromValue = [-0.4, -0.2, 0]
        animation.toValue = [1, 1.2, 1.4]
        animation.duration = 1.25
        animation.repeatCount = .infinity
        sweepLayer.add(animation, forKey: "sweep")
    }

    private func stopSweep() {
        sweepLayer.removeAnimation(forKey: "sweep")
        sweep.isHidden = true
    }

    /// The sentence on screen: the e2e's proof that the failure is the
    /// documented one, not a generic message.
    var displayedMessage: String { lead.stringValue }
    var displayedTitle: String { titleLabel.stringValue }
    var displayedSecondary: String { secondary.stringValue }
    var displayedReason: String { reason.stringValue }

    override func layout() {
        super.layout()
        ground.frame = bounds
        sweep.frame = NSRect(x: 0, y: bounds.height - 2, width: bounds.width, height: 2)
        sweepLayer.frame = sweep.bounds
        let sideInset: CGFloat = 24
        let textWidth = max(bounds.width - sideInset * 2, 80)
        let iconSide: CGFloat = 96
        let gap: CGFloat = 14
        let secondarySide: CGFloat = 18
        let titleHeight = titleLabel.isHidden ? 0 : titleLabel.intrinsicContentSize.height
        let leadHeight = lead.stringValue.isEmpty ? 0
            : lead.sizeThatFits(NSSize(width: textWidth, height: .greatestFiniteMagnitude)).height
        let reasonHeight = reason.stringValue.isEmpty ? 0
            : reason.sizeThatFits(NSSize(width: textWidth, height: .greatestFiniteMagnitude)).height
        // Only one of the two middle lines is up: the slow phase's sentence
        // or the failure's lead and reason.
        let middle = lead.stringValue.isEmpty ? secondarySide : leadHeight
        let buttons = [cancel, close].filter { !$0.isHidden }
        let buttonHeight = buttons.map { $0.intrinsicContentSize.height }.max() ?? 0
        let total = iconSide + (titleLabel.isHidden ? 0 : gap + titleHeight) + gap + middle
            + (reasonHeight > 0 ? 6 + reasonHeight : 0)
            + (buttons.isEmpty ? 0 : gap + buttonHeight)
        var y = (bounds.height + total) / 2
        y -= iconSide
        iconView.frame = NSRect(x: (bounds.width - iconSide) / 2, y: y, width: iconSide, height: iconSide)
        if !titleLabel.isHidden {
            y -= gap + titleHeight
            titleLabel.frame = NSRect(x: sideInset, y: y, width: textWidth, height: titleHeight)
        }
        y -= gap + middle
        if lead.stringValue.isEmpty {
            secondary.frame = NSRect(x: sideInset, y: y, width: textWidth, height: secondarySide)
        } else {
            lead.frame = NSRect(x: sideInset, y: y, width: textWidth, height: leadHeight)
        }
        if reasonHeight > 0 {
            y -= 6 + reasonHeight
            reason.frame = NSRect(x: sideInset, y: y, width: textWidth, height: reasonHeight)
        }
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
    /// read them (a failure's sentence wraps, and Close alone is centred).
    var messageFrame: NSRect { lead.frame }
    var messageText: String { lead.stringValue }
    var visibleButtonFrames: [NSRect] { [cancel, close].filter { !$0.isHidden }.map(\.frame) }

    /// A cover button's centre in the window's coordinates (nil while that
    /// button is not up): the shot/debug route reads where it is.
    func buttonCentre(_ title: String) -> NSPoint? {
        guard let button = [cancel, close].first(where: { !$0.isHidden && $0.title == title }) else {
            return nil
        }
        return button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
    }

    /// Presses a cover button the way its own click does (an NSButton's
    /// tracking loop owns the event queue, so a posted pair would deadlock the
    /// main thread in a quiet run; this is the same action path a click runs).
    @discardableResult
    func press(_ title: String) -> Bool {
        guard let button = [cancel, close].first(where: { !$0.isHidden && $0.title == title }) else {
            return false
        }
        button.performClick(nil)
        return true
    }

    /// The buttons keep their clicks; every other point is swallowed: the
    /// window must not send anything to the phone while the cover is up.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, let superview else { return nil }
        guard bounds.contains(convert(point, from: superview)) else { return nil }
        for button in [cancel, close] where !button.isHidden {
            if let hit = button.hitTest(convert(point, from: superview)) { return hit }
        }
        return self
    }

    @objc private func cancelPressed(_ sender: Any?) { onCancel?() }
    @objc private func closePressed(_ sender: Any?) { onClose?() }
}

private extension NSImage {
    /// The failure's grey icon: the same picture without its colour.
    func greyed() -> NSImage {
        guard let tiff = tiffRepresentation, let input = CIImage(data: tiff),
              let filter = CIFilter(name: "CIColorControls") else { return self }
        filter.setValue(input, forKey: kCIInputImageKey)
        filter.setValue(0, forKey: kCIInputSaturationKey)
        guard let output = filter.outputImage,
              let cgImage = CIContext().createCGImage(output, from: output.extent) else { return self }
        return NSImage(cgImage: cgImage, size: size)
    }
}
