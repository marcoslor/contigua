// The Live Text controls in the stream chrome (docs/design/livetext.md): a
// `text.viewfinder` button that toggles the mode and drags the frozen frame out
// as a PNG, and the small "Live Text" pill that says input is paused.
//
// Both wear the chrome they sit in: the Compact bar's line at the window's top
// right of the bar. Full screen is the system's title bar, so only the View
// menu reaches the mode there and the status pill floats at the top edge of
// the stream.

import AppKit

/// A plain icon control with the chrome's look. A click toggles the mode; a
/// drag past a few points starts a file drag of the frozen frame.
final class LiveTextBarButton: NSView, NSDraggingSource {
    static let side: CGFloat = 28
    /// A click that moved less than this is still a click.
    static let dragThreshold: CGFloat = 4

    var onPress: (() -> Void)?
    /// nil when there is no frame to drag (the mode is off).
    var dragProvider: (() -> URL?)?

    private let icon = NSImageView()
    private var downPoint: NSPoint?
    var isOn = false {
        didSet { needsDisplay = true; updateIcon() }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        icon.image = NSImage(systemSymbolName: "text.viewfinder", accessibilityDescription: "Live Text")
        icon.imageScaling = .scaleProportionallyDown
        icon.contentTintColor = .labelColor
        addSubview(icon)
        toolTip = "Live Text"
        setAccessibilityLabel("Live Text")
        setAccessibilityRole(.button)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { false }

    override func layout() {
        super.layout()
        let size = min(bounds.width, bounds.height) - 10
        icon.frame = NSRect(x: bounds.midX - size / 2, y: bounds.midY - size / 2,
                            width: size, height: size)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let superview else { return nil }
        return bounds.contains(convert(point, from: superview)) ? self : nil
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard isOn || isHighlighted else { return }
        let rect = bounds.insetBy(dx: 3, dy: 3)
        let active = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
        (isHighlighted ? NSColor.labelColor.withAlphaComponent(0.16)
                       : NSColor.controlAccentColor.withAlphaComponent(0.22)).setFill()
        active.fill()
    }

    private var isHighlighted = false {
        didSet { needsDisplay = true }
    }

    private func updateIcon() {
        icon.contentTintColor = isOn ? .controlAccentColor : .labelColor
    }

    override func mouseDown(with event: NSEvent) {
        downPoint = convert(event.locationInWindow, from: nil)
        isHighlighted = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = downPoint else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard hypot(point.x - start.x, point.y - start.y) >= Self.dragThreshold,
              let url = dragProvider?() else { return }
        downPoint = nil
        isHighlighted = false
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        item.setDraggingFrame(bounds, contents: NSImage(contentsOf: url) ?? icon.image)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        isHighlighted = false
        guard downPoint != nil else { return }
        downPoint = nil
        onPress?()
    }

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }
}

/// "Live Text", small and quiet: says the window is frozen and input is paused.
/// The chrome's style decides whether it rides the bar or the stream's top edge.
final class LiveTextStatusView: NSView {
    static let height: CGFloat = 20
    static let inset: CGFloat = 8

    private let label = NSTextField(labelWithString: "Live Text")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = Self.height / 2
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.45).cgColor
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .white
        label.alignment = .center
        addSubview(label)
        setAccessibilityLabel("Live Text: input paused")
    }

    /// "Live Text" or the short-lived "Subject copied".
    func setText(_ text: String) {
        label.stringValue = text
        needsLayout = true
        setAccessibilityLabel(text == "Live Text" ? "Live Text: input paused" : text)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { false }

    var preferredSize: NSSize {
        let width = label.fittingSize.width + Self.inset * 2
        return NSSize(width: ceil(width), height: Self.height)
    }

    override func layout() {
        super.layout()
        label.frame = NSRect(x: Self.inset, y: (bounds.height - label.fittingSize.height) / 2,
                             width: bounds.width - Self.inset * 2, height: label.fittingSize.height)
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
