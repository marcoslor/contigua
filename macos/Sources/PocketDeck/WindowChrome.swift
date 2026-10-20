// The bar's controls: the window kind's actions (the phone window's Back /
// Home / Recents, the camera window's switch) and the Live Text button sit in
// Liquid Glass capsules at the bar's right end, like a macOS toolbar item
// group. One capsule per group; buttons keep their 32x28 pt hit area.
//
// Everything the tests pin is pure: which actions share a capsule, the symbol
// each kind draws, and whether a kind is enabled in Live Text mode. The views
// below draw the capsules and the buttons; the capsule's material is a plain
// fill (the glass above it adds the system's blur and edge), which is what the
// contrast test renders off screen.

import AppKit

/// What a bar action does, which fixes its symbol, its group and whether Live
/// Text freezes it.
enum HeaderActionKind: String, CaseIterable {
    case back
    case home
    case recents
    case liveText
    case cameraSwitch
    /// A window kind's own action with its own symbol; frozen by Live Text too.
    case custom
}

/// Actions with the same group share one capsule.
enum HeaderActionGroup: Hashable {
    case navigation
    case camera
    case custom(String)

    var id: String {
        switch self {
        case .navigation: return "navigation"
        case .camera: return "camera"
        case .custom(let id): return "custom:" + id
        }
    }
}

/// One button at the bar's right end (the phone window's Back/Home/Recents).
struct HeaderAction {
    let kind: HeaderActionKind
    let symbol: String
    let help: String
    let perform: () -> Void

    /// The symbol and tooltip come from the kind; `custom` passes its own.
    init(kind: HeaderActionKind, customSymbol: String? = nil, help: String? = nil,
         perform: @escaping () -> Void) {
        self.kind = kind
        self.symbol = customSymbol ?? HeaderBar.symbol(for: kind) ?? "circle"
        self.help = help ?? HeaderBar.help(for: kind)
        self.perform = perform
    }

    static func back(_ perform: @escaping () -> Void) -> HeaderAction {
        HeaderAction(kind: .back, perform: perform)
    }

    static func home(_ perform: @escaping () -> Void) -> HeaderAction {
        HeaderAction(kind: .home, perform: perform)
    }

    static func recents(_ perform: @escaping () -> Void) -> HeaderAction {
        HeaderAction(kind: .recents, perform: perform)
    }

    static func cameraSwitch(_ perform: @escaping () -> Void) -> HeaderAction {
        HeaderAction(kind: .cameraSwitch, perform: perform)
    }

    var group: HeaderActionGroup {
        switch kind {
        case .back, .home, .recents: return .navigation
        case .cameraSwitch: return .camera
        case .liveText: return .custom("livetext")
        case .custom: return .custom(help)
        }
    }
}

/// Whether a control may act. One decision for the bar's buttons and for the
/// phone's navigation shortcuts: Live Text freezes everything but its own
/// button, because the picture is frozen and the phone behind it is paused.
enum HeaderActionPolicy {
    static func isEnabled(_ kind: HeaderActionKind, liveTextActive: Bool) -> Bool {
        liveTextActive ? kind == .liveText : true
    }

    /// The phone navigation shortcuts (⌘[, ⇧⌘H, ⌘↑) act on the phone: they are
    /// frozen with the buttons.
    static func allowsPhoneShortcut(liveTextActive: Bool) -> Bool {
        !liveTextActive
    }
}

/// The bar's numbers and its pure layout.
enum HeaderBar {
    static let buttonWidth: CGFloat = 32
    static let buttonHeight: CGFloat = 28
    /// Between two capsules.
    static let capsuleGap: CGFloat = 6
    /// The row ends this far in from the window's right edge.
    static let rightInset: CGFloat = 12
    static let symbolPointSize: CGFloat = 14
    static let symbolWeight: NSFont.Weight = .medium
    /// The Live Text button's side (LiveTextBarButton.side).
    static let liveTextSide: CGFloat = 28

    static func symbol(for kind: HeaderActionKind) -> String? {
        switch kind {
        case .back: return "chevron.backward"
        case .home: return "house"
        case .recents: return "rectangle.stack"
        case .liveText: return "text.viewfinder"
        case .cameraSwitch: return "arrow.triangle.2.circlepath.camera"
        case .custom: return nil
        }
    }

    static func help(for kind: HeaderActionKind) -> String {
        switch kind {
        case .back: return "Back"
        case .home: return "Home"
        case .recents: return "Recents"
        case .liveText: return "Live Text"
        case .cameraSwitch: return "Switch Camera"
        case .custom: return ""
        }
    }

    /// Consecutive actions in the same group share a capsule; a different
    /// group starts a new one, in order.
    static func groups(_ actions: [HeaderAction]) -> [[HeaderAction]] {
        var result: [[HeaderAction]] = []
        for action in actions {
            if let last = result.last, last.first?.group == action.group {
                result[result.count - 1].append(action)
            } else {
                result.append([action])
            }
        }
        return result
    }

    static func capsuleWidth(buttonCount: Int) -> CGFloat {
        CGFloat(max(buttonCount, 0)) * buttonWidth
    }

    /// The action capsules only: their widths plus the gaps between them.
    static func rowWidth(_ actions: [HeaderAction]) -> CGFloat {
        let capsules = groups(actions)
        return capsules.reduce(0) { $0 + capsuleWidth(buttonCount: $1.count) }
            + CGFloat(max(capsules.count - 1, 0)) * capsuleGap
    }

    /// Where one group's capsule starts (the view runs left to right).
    static func capsuleOrigins(_ actions: [HeaderAction]) -> [CGFloat] {
        var x: CGFloat = 0
        return groups(actions).map { group in
            let origin = x
            x += capsuleWidth(buttonCount: group.count) + capsuleGap
            return origin
        }
    }

    /// The bar's whole row: the action capsules, a gap, and the Live Text
    /// capsule, ending `rightInset` from the right edge. nil while the window
    /// has no actions and no Live Text button (full screen).
    struct Row: Equatable {
        var actionsX: CGFloat
        var actionsWidth: CGFloat
        var liveTextX: CGFloat
        var width: CGFloat
    }

    static func row(_ actions: [HeaderAction], rightEdge: CGFloat) -> Row? {
        let actionsWidth = rowWidth(actions)
        let hasActions = !actions.isEmpty
        let width = (hasActions ? actionsWidth + capsuleGap : 0) + liveTextSide
        let start = rightEdge - rightInset - width
        let actionsX = start
        let liveTextX = start + (hasActions ? actionsWidth + capsuleGap : 0)
        return Row(actionsX: actionsX, actionsWidth: actionsWidth, liveTextX: liveTextX, width: width)
    }

    /// The capsule's material: a light, almost opaque fill in light
    /// appearances and a dark one in dark appearances, with the symbol colour
    /// the fill carries. Opaque enough that the stream behind it (white, black
    /// or busy) cannot pull the symbol below 3:1.
    struct Material {
        var fill: NSColor
        var symbol: NSColor
    }

    static func material(dark: Bool) -> Material {
        dark ? Material(fill: NSColor(white: 0.16, alpha: 0.82), symbol: NSColor(white: 0.97, alpha: 1))
             : Material(fill: NSColor(white: 0.95, alpha: 0.82), symbol: NSColor(white: 0.06, alpha: 1))
    }

    static func material(for appearance: NSAppearance?) -> Material {
        let match = appearance?.bestMatch(from: [.darkAqua, .aqua])
        return material(dark: match == .darkAqua)
    }
}

// MARK: - Views

/// One action button: its symbol on the capsule, a click for the action, a
/// pointing hand while enabled. Disabled (Live Text) it draws dimmed, takes no
/// click, shows no hand and says "dimmed" to accessibility.
final class HeaderActionButton: NSView {
    let action: HeaderAction
    private let icon = NSImageView()
    private let material: HeaderBar.Material
    private var hovered = false

    var isEnabled: Bool = true {
        didSet {
            guard isEnabled != oldValue else { return }
            alphaValue = isEnabled ? 1 : 0.4
            setAccessibilityEnabled(isEnabled)
            window?.invalidateCursorRects(for: self)
            if !isEnabled { hovered = false }
            needsDisplay = true
        }
    }

    init(action: HeaderAction, material: HeaderBar.Material) {
        self.action = action
        self.material = material
        super.init(frame: NSRect(x: 0, y: 0, width: HeaderBar.buttonWidth, height: HeaderBar.buttonHeight))
        wantsLayer = true
        icon.image = NSImage(systemSymbolName: action.symbol, accessibilityDescription: action.help)
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: HeaderBar.symbolPointSize,
                                                               weight: HeaderBar.symbolWeight)
        icon.contentTintColor = material.symbol
        icon.imageScaling = .scaleProportionallyDown
        icon.frame = NSRect(x: (bounds.width - HeaderBar.symbolPointSize) / 2,
                            y: (bounds.height - HeaderBar.symbolPointSize) / 2,
                            width: HeaderBar.symbolPointSize, height: HeaderBar.symbolPointSize)
        icon.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin, .maxYMargin]
        addSubview(icon)
        toolTip = action.help
        setAccessibilityLabel(action.help)
        setAccessibilityRole(.button)
        setAccessibilityEnabled(true)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(point) ? self : nil
    }

    override func resetCursorRects() {
        if isEnabled { addCursorRect(bounds, cursor: .pointingHand) }
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        hovered = true
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        hovered = false
        needsDisplay = true
        guard isEnabled else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point) else { return }
        action.perform()
    }

    override func draw(_ dirtyRect: NSRect) {
        guard hovered, isEnabled else { return }
        material.symbol.withAlphaComponent(0.12).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 3, dy: 3), xRadius: 7, yRadius: 7).fill()
    }
}

/// A group's capsule: the material fill, with a clear glass view over it for
/// the system's edge and blur. It takes no clicks of its own, so a click on
/// the capsule's padding is the bar's (a drag).
final class HeaderCapsuleView: NSView {
    var material: HeaderBar.Material {
        didSet {
            glass.tintColor = material.fill.withAlphaComponent(0.35)
            needsDisplay = true
        }
    }
    private let glass = NSGlassEffectView()

    init(material: HeaderBar.Material) {
        self.material = material
        super.init(frame: .zero)
        wantsLayer = true
        // The glass gives the capsule its Liquid Glass edge; the fill below it
        // is what keeps the symbols readable over white, black and busy frames
        // (and what the off-screen contrast test sees).
        glass.style = .clear
        glass.cornerRadius = HeaderBar.buttonHeight / 2
        glass.tintColor = material.fill.withAlphaComponent(0.35)
        addSubview(glass)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Buttons are siblings above this view; the capsule itself is the bar.
        nil
    }

    override func layout() {
        super.layout()
        glass.frame = bounds
    }

    override func draw(_ dirtyRect: NSRect) {
        material.fill.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
    }
}

/// The action capsules in one view, laid out left to right. The chrome places
/// and hides this view exactly like the bare buttons before it.
final class HeaderBarView: NSView {
    private(set) var actions: [HeaderAction] = []
    private var capsules: [HeaderCapsuleView] = []
    private var buttons: [HeaderActionButton] = []
    private var liveTextActive = false

    var material: HeaderBar.Material = HeaderBar.material(dark: false) {
        didSet { rebuild() }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// The actions changed (a window kind's own set), or the mode did: rebuild
    /// the capsules and dim the frozen kinds. One place decides: the policy.
    func setActions(_ actions: [HeaderAction], liveTextActive: Bool) {
        guard actions.map(\.help) != self.actions.map(\.help) || liveTextActive != self.liveTextActive else {
            applyEnabled()
            return
        }
        self.actions = actions
        self.liveTextActive = liveTextActive
        rebuild()
    }

    var actionCount: Int { actions.count }

    private func rebuild() {
        capsules.forEach { $0.removeFromSuperview() }
        buttons.forEach { $0.removeFromSuperview() }
        capsules = []
        buttons = []
        let groups = HeaderBar.groups(actions)
        let origins = HeaderBar.capsuleOrigins(actions)
        for (index, group) in groups.enumerated() {
            let capsule = HeaderCapsuleView(material: material)
            capsule.frame = NSRect(x: origins[index], y: 0,
                                   width: HeaderBar.capsuleWidth(buttonCount: group.count),
                                   height: HeaderBar.buttonHeight)
            addSubview(capsule)
            capsules.append(capsule)
            for (offset, action) in group.enumerated() {
                let button = HeaderActionButton(action: action, material: material)
                button.frame = NSRect(x: origins[index] + CGFloat(offset) * HeaderBar.buttonWidth,
                                      y: 0, width: HeaderBar.buttonWidth, height: HeaderBar.buttonHeight)
                addSubview(button)
                buttons.append(button)
            }
        }
        applyEnabled()
        needsLayout = true
    }

    private func applyEnabled() {
        for button in buttons {
            button.isEnabled = HeaderActionPolicy.isEnabled(button.action.kind, liveTextActive: liveTextActive)
        }
    }
}
