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

    /// Why this control cannot work while the phone is away, in the person's
    /// words: a disabled control says what would fix it (CONV-PD-09).
    var offlineReason: String {
        switch kind {
        case .back, .home, .recents: return "Connect your phone to use these."
        case .custom: return "Connect your phone to turn off its screen."
        case .liveText: return ""
        case .cameraSwitch: return "Connect your phone to switch cameras."
        }
    }
}

/// Whether a control may act. One decision for the bar's buttons and for the
/// phone's navigation shortcuts: Live Text freezes everything but its own
/// button, because the picture is frozen and the phone behind it is paused.
enum HeaderActionPolicy {
    /// What is over the picture freezes the phone-side controls: Live Text
    /// (the frame is frozen) or a cover (the panel sleeps, a secure surface is
    /// hidden, or the opening cover refuses). A link that is down disables them
    /// too: a request into a dead session is a click that silently does
    /// nothing (M3). The Live Text button itself stays live.
    static func isEnabled(_ kind: HeaderActionKind, frozen: Bool, offline: Bool = false) -> Bool {
        if kind == .liveText { return true }
        return !frozen && !offline
    }

    /// The phone navigation shortcuts (⌘[, ⇧⌘H, ⌘↑) act on the phone: they are
    /// frozen with the buttons.
    static func allowsPhoneShortcut(frozen: Bool, offline: Bool = false) -> Bool {
        !frozen && !offline
    }
}

/// The bar's numbers and its pure layout.
enum HeaderBar {
    static let buttonWidth: CGFloat = 32
    static let buttonHeight: CGFloat = 28
    /// Between two capsules.
    static let capsuleGap: CGFloat = 6
    /// The row ends this far in from the window's right edge: the lights'
    /// left inset, mirrored (BarGeometry).
    static let rightInset = BarGeometry.rightInset
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

    /// The gap between the traffic lights and the row's first capsule.
    static let barGap: CGFloat = 8

    /// The narrowest window whose framed bar holds the lights and this row:
    /// where the lights end, the gap, the row and the right inset. A control
    /// added to a window's bar widens the row, so a window's minimum width
    /// follows the geometry instead of a guess.
    static func minimumWidth(for actions: [HeaderAction]) -> CGFloat {
        let lightsEnd = BarGeometry.lightInset + 2 * BarGeometry.lightSpacing + BarGeometry.lightSide
        let width = row(actions, rightEdge: 0)?.width ?? liveTextSide
        return lightsEnd + barGap + width + rightInset
    }

    /// The capsule's material: a light, almost opaque fill in light
    /// appearances and a dark one in dark appearances, with the symbol colour
    /// the fill carries. Opaque enough that the stream behind it (white, black
    /// or busy) cannot pull the symbol below 3:1.
    struct Material: Equatable {
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

    /// The keyboard's focus is on this button (MIRROR-13): the ring is the
    /// visible "you are here" for a person who cannot use a pointer.
    var showsFocus = false {
        didSet {
            guard showsFocus != oldValue else { return }
            setAccessibilityFocused(showsFocus)
            needsDisplay = true
        }
    }

    var isEnabled: Bool = true {
        didSet {
            guard isEnabled != oldValue else { return }
            alphaValue = isEnabled ? 1 : 0.4
            setAccessibilityEnabled(isEnabled)
            window?.invalidateCursorRects(for: self)
            if !isEnabled { hovered = false }
            needsDisplay = true
            applyHelp()
        }
    }

    /// Why the control is dimmed (nil when it is live): the tooltip and the
    /// help tag say what would fix it, in the person's words.
    var disabledReason: String? {
        didSet {
            guard disabledReason != oldValue else { return }
            applyHelp()
        }
    }

    private var standardHelp: String {
        "\(action.help): ⌃Tab moves the keyboard to the bar, Return presses"
    }

    private func applyHelp() {
        let help = disabledReason ?? standardHelp
        toolTip = disabledReason ?? action.help
        setAccessibilityHelp(help)
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
        setAccessibilityLabel(action.help)
        setAccessibilityRole(.button)
        setAccessibilityEnabled(true)
        // CONV-PD-09/MIRROR-13: the label names the action, the help says how
        // to reach it without a pointer (or why it is dimmed).
        applyHelp()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// AppKit hands `hitTest` a point in the superview's coordinates; the
    /// button's own bounds only match it for the first capsule slot. A disabled
    /// button still takes the hit and swallows it (mouseDown/mouseUp are gated
    /// on isEnabled): a click on a greyed-out control must never fall through
    /// to the video under the bar and become a touch on the phone.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let superview else { return nil }
        return bounds.contains(convert(point, from: superview)) ? self : nil
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
        if hovered, isEnabled {
            material.symbol.withAlphaComponent(0.12).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 3, dy: 3), xRadius: 7, yRadius: 7).fill()
        }
        // The keyboard's focus ring (MIRROR-13): the accent, 2 pt, inside the
        // button's 32x28 hit area and never over the symbol.
        guard showsFocus, isEnabled else { return }
        NSColor.controlAccentColor.setStroke()
        let ring = NSBezierPath(roundedRect: bounds.insetBy(dx: 2.5, dy: 2.5), xRadius: 6, yRadius: 6)
        ring.lineWidth = 2
        ring.stroke()
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
    private var frozen = false
    /// The link is down: every phone-side control is dimmed with its reason.
    private var offline = false
    /// The button the keyboard is on (MIRROR-13), kept across a rebuild: the
    /// bar is rebuilt when the panel report changes its glyph.
    private var focusedIndex: Int?

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
            button.isEnabled = HeaderActionPolicy.isEnabled(button.action.kind,
                                                            frozen: frozen || liveTextActive,
                                                            offline: offline)
            button.disabledReason = !button.isEnabled && offline ? button.action.offlineReason : nil
        }
        applyFocus()
    }

    /// What freezes the kinds (Live Text or a cover over the picture): every
    /// action is disabled except Live Text's own button, and a disabled button
    /// takes no click (hitTest).
    func setFrozen(_ frozen: Bool) {
        guard frozen != self.frozen else { return }
        self.frozen = frozen
        applyEnabled()
    }

    /// The link went down or came back: the phone-side controls dim with the
    /// reason (Turn Off Phone Screen included).
    func setOffline(_ offline: Bool) {
        guard offline != self.offline else { return }
        self.offline = offline
        applyEnabled()
    }

    /// The kinds the bar has live right now, in reading order: the chrome
    /// state's proof that a frozen or offline control is really disabled.
    var enabledKinds: [String] {
        buttons.filter { $0.isEnabled }.map { $0.action.kind.rawValue }
    }

    /// The button that runs one kind (the e2e clicks its real control).
    func button(for kind: HeaderActionKind) -> HeaderActionButton? {
        buttons.first { $0.action.kind == kind }
    }

    /// The button at an index in reading order, for the keyboard.
    func action(at index: Int) -> HeaderAction? {
        buttons.indices.contains(index) ? buttons[index].action : nil
    }

    /// The bar's buttons the keyboard may focus, in reading order: a disabled
    /// (frozen) button is skipped, so ⌃Tab can never land on one.
    var focusableIndices: [Int] {
        buttons.indices.filter { buttons[$0].isEnabled }
    }

    /// The keyboard's focus lands on a button (nil: back to the picture).
    func setFocus(_ index: Int?) {
        focusedIndex = index
        applyFocus()
    }

    /// The focus ring survives a rebuild (the panel glyph changes the bar's
    /// actions) but never stays on a button that is gone or disabled.
    private func applyFocus() {
        for (index, button) in buttons.enumerated() {
            button.showsFocus = index == focusedIndex && button.isEnabled
        }
    }

    /// The capsules are 28 pt tall in a bar that may be taller (Standard): keep
    /// them on the bar's centre line.
    override func layout() {
        super.layout()
        let y = (bounds.height - HeaderBar.buttonHeight) / 2
        let groups = HeaderBar.groups(actions)
        let origins = HeaderBar.capsuleOrigins(actions)
        guard groups.count == capsules.count else { return }
        for (index, group) in groups.enumerated() {
            capsules[index].frame = NSRect(x: origins[index], y: y,
                                           width: HeaderBar.capsuleWidth(buttonCount: group.count),
                                           height: HeaderBar.buttonHeight)
            for offset in 0..<group.count {
                let buttonIndex = index > 0 ? groups.prefix(index).reduce(0) { $0 + $1.count } : 0
                guard buttonIndex + offset < buttons.count else { continue }
                buttons[buttonIndex + offset].frame = NSRect(
                    x: origins[index] + CGFloat(offset) * HeaderBar.buttonWidth, y: y,
                    width: HeaderBar.buttonWidth, height: HeaderBar.buttonHeight)
            }
        }
    }
}
