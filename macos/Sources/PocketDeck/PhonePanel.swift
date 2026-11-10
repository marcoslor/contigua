// The phone controls the menu bar panel and the Deck popover share
// (docs/design/mac-redesign.md §3.8, docs/DESIGN.md "Deck"): one view, one
// item model, one copy. The panel is a fixed-width Control Center-style card:
// a header with the gear that opens the icon's menu, one full-width Sound
// module, the 2×2 modules Focus / Ringer / Ring Phone / Turn Off Screen, what
// the phone plays, its live notifications, the app in front as one read and
// the two window buttons. It never reads the track title, performer or
// artwork: the Mac's own Now Playing already shows those.
//
// The layout is fixed (300 pt wide, 134×62 pt modules) so the e2e can drive the
// real controls at their own frames: `PhonePanelProbe` (PanelProbe.swift) walks
// the hosting view's key-view proxies, which follow this view's focus order.

import AppKit
import SwiftUI

/// The panel's content as a value: the controller's connection, media, DND and
/// ring state. Both hosts build it with the same initializer.
struct PhoneControlsState: Equatable {
    enum Connection: Equatable {
        case online, connecting, reconnecting, offline, needsPairing, idle

        var text: String {
            switch self {
            case .online: return "Connected"
            case .connecting: return "Connecting…"
            case .reconnecting: return "Reconnecting…"
            case .offline: return "Offline"
            case .needsPairing: return PairAgainCopy.banner
            case .idle: return "No phone paired"
            }
        }

        var isOnline: Bool { self == .online }
    }

    /// One remembered phone in the header's pop-up (PANEL-27).
    struct PanelPhone: Equatable, Identifiable {
        var id: String
        var name: String
        var active: Bool
    }

    var phoneName = "your phone"
    var connection: Connection = .idle
    /// The sticky problem the Deck's banner also shows (PAIR-33/35). A
    /// transient notice (a ring, an install) never reaches this row.
    var notice: Banner?
    var battery: Int?
    var charging = false
    /// The phone is locked (the header's lock glyph while online).
    var locked = false
    /// When the phone was last reached, for the header's line while away.
    var lastSeen: Date?
    /// Every remembered phone, most recently used first; the header shows a
    /// pop-up only with two or more (PANEL-27).
    var phones: [PanelPhone] = []
    /// The app in front on the phone, from the pulled `task.front` reply; nil
    /// while the phone is away or nothing continuable is in front (PANEL-28).
    var handoff: FrontAppRow?
    /// A fresh foreground reply said the phone's screen has nothing to open;
    /// the Phone menu's always-present item is disabled with that reason.
    var frontFresh = false
    var frontNone = false

    /// The battery the header draws: none while the phone is away. The last
    /// reading belongs to a phone that isn't there any more, and a stale level
    /// claims something nobody measured.
    var shownBattery: Int? { connection.isOnline ? battery : nil }
    var agentCount = 0
    var media: MediaState?
    var sessions: [MediaSessionRow] = []
    var dnd: PhoneDndMode?
    /// The phone's music stream (`state.volume`/`state.volumeMax`); both nil on
    /// a phone that cannot read it, which is not the same as zero.
    var volume: Int?
    var volumeMax: Int?
    var ringing = false
    var live: [NotifyLiveItem] = []
    var liveTick = Date()
    var installBusy = false
    var installTitle = "Install APK…"
    /// The phone's ringer mode (state.ringer); nil on a phone that cannot set it.
    var ringer: PhoneRingerMode?
    /// A phone window is open, so Turn Off Screen has something to act on. The
    /// Phone menu's item asks the same question.
    var phoneWindow = false
    /// The phone window holds its own panel off (state.panel, "Turn Off Screen").
    var panelOff = false

    var dndOn: Bool { dnd?.isOn == true }
    var ringerTitle: String { ringer?.displayName ?? "—" }
    var screenTitle: String { panelOff ? "Screen off" : "Screen on" }
    var showsPhonePicker: Bool { phones.count > 1 }

    /// The handoff row and the Phone menu's item: the fresh app while one is
    /// known, else the words the menu must always have (PANEL-28).
    var continueTitle: String {
        if frontFresh, let handoff { return handoff.title }
        return FrontAppRow.fallbackTitle
    }

    var continueEnabled: Bool {
        connection.isOnline && !(frontFresh && frontNone)
    }

    var continueReason: String? {
        guard connection.isOnline else { return PanelUnavailable.offline.sentence }
        return frontFresh && frontNone ? FrontAppRow.nothingToOpen : nil
    }

    var showsHandoff: Bool { connection.isOnline && handoff != nil }

    /// The Ringer menu's rows in one place: the mode, its word and whether it is
    /// the phone's current mode (the menu's checkmark).
    struct RingerMenuRow: Identifiable, Equatable {
        let mode: PhoneRingerMode
        var id: PhoneRingerMode { mode }
        var name: String { mode.displayName }
        var checked: Bool
    }

    var ringerMenu: [RingerMenuRow] {
        PhoneRingerMode.allCases.map { RingerMenuRow(mode: $0, checked: ringer == $0) }
    }

    /// The volume's own line (the modules have their own, per control).
    var reason: String? { PhonePanelItem.volume.reason(in: self) }

    var volumeFraction: Double? {
        guard connection.isOnline, let volume, let max = volumeMax, max > 0 else { return nil }
        return min(Swift.max(Double(volume) / Double(max), 0), 1)
    }

    var showsPicker: Bool { MediaMenu.showsSessionPicker(sessions) }

    var pickerApp: String { MediaMenu.chosenApp(sessions, chosen: media?.key) ?? "your phone" }
    var pickerTitle: String { "Now playing: \(pickerApp)" }

    var ringTitle: String { ringing ? "Stop Ringing" : "Ring Phone" }

    /// [PANEL-8/PANEL-11] The Ring Phone module's second line: the design's
    /// "Plays a sound" at rest, "Ringing" while the phone rings. A timeout is
    /// not a state, so it never appears here.
    var ringSubtitle: String { ringing ? "Ringing" : "Plays a sound" }
}

/// The volume slider's small machine (docs/design/mac-redesign.md §3.8):
/// the phone's echoed value is the truth while idle, but while the person drags
/// the thumb follows the pointer and the phone's old replies are ignored. On
/// release the sent value is shown until the phone echoes it (or one second
/// passes and the phone wins).
struct PhoneVolumeControl: Equatable {
    enum Phase: Equatable {
        case idle
        case dragging
        case settling(sent: Double, since: Date)
    }

    private(set) var phase: Phase = .idle
    private(set) var display: Double = 0
    /// The newest value the phone reported, even when a drag is ignoring it.
    private(set) var phone: Double?
    private var lastSentAt: Date?

    static let throttle: TimeInterval = 0.1
    static let settleTimeout: TimeInterval = 1

    var isDragging: Bool {
        if case .dragging = phase { return true }
        return false
    }

    private static func clamp(_ value: Double) -> Double { min(max(value, 0), 1) }

    init(display: Double = 0) {
        self.display = Self.clamp(display)
    }

    /// A phone value arrived. Idle follows it; a drag ignores it; settling
    /// shows the sent value until the echo matches or the deadline passes.
    mutating func sync(phone value: Double?, tolerance: Double, at now: Date) {
        guard let value else {
            phone = nil
            if case .idle = phase { display = 0 }
            return
        }
        let shown = Self.clamp(value)
        phone = shown
        switch phase {
        case .idle:
            display = shown
        case .dragging:
            break
        case .settling(let sent, let since):
            if abs(shown - sent) <= tolerance || now.timeIntervalSince(since) >= Self.settleTimeout {
                phase = .idle
                display = shown
            } else {
                display = sent
            }
        }
    }

    /// The person put the pointer on the thumb; keep showing what is there.
    mutating func begin(at now: Date) {
        phase = .dragging
        lastSentAt = nil
    }

    /// The thumb moved. Returns true when this value should be sent now: at
    /// most one send per `throttle`, not one per pointer event.
    @discardableResult
    mutating func drag(to value: Double, at now: Date) -> Bool {
        guard case .dragging = phase else { return false }
        display = Self.clamp(value)
        if let lastSentAt, now.timeIntervalSince(lastSentAt) < Self.throttle { return false }
        lastSentAt = now
        return true
    }

    /// The pointer came up: the final value is always sent, even when it was
    /// just sent by the last throttled step.
    mutating func end(at now: Date) -> Double? {
        guard case .dragging = phase else { return nil }
        let sent = display
        phase = .settling(sent: sent, since: now)
        lastSentAt = nil
        return sent
    }

    /// The settle deadline passed: no matching echo, so the phone's value wins.
    @discardableResult
    mutating func expire(at now: Date, phone value: Double?) -> Bool {
        guard case .settling(_, let since) = phase,
              now.timeIntervalSince(since) >= Self.settleTimeout else { return false }
        if let value {
            self.phone = Self.clamp(value)
            display = Self.clamp(value)
        }
        phase = .idle
        return true
    }
}

/// What the volume slider is showing, for the e2e's per-step assertion. The
/// slider's thumb is a SwiftUI KeyViewProxy with no AppKit value, so the probe
/// reads this mirror of the same `PhoneVolumeControl.display` the binding draws.
@MainActor
enum PhoneVolumeDebug {
    private(set) static var display: Double = 0
    private(set) static var phone: Double?
    private(set) static var phase = "idle"

    static func update(_ control: PhoneVolumeControl) {
        display = control.display
        phone = control.phone
        switch control.phase {
        case .idle: phase = "idle"
        case .dragging: phase = "dragging"
        case .settling: phase = "settling"
        }
    }

    static func reset() {
        display = 0
        phone = nil
        phase = "idle"
    }
}

/// The panel's actions. The hosts only supply how to reach the Deck window;
/// everything else is the controller's own route.
struct PhoneControlsActions {
    var setVolume: (Double) -> Void = { _ in }
    var setDnd: (Bool) -> Void = { _ in }
    var setRinger: (PhoneRingerMode) -> Void = { _ in }
    var ring: () -> Void = {}
    var stopRing: () -> Void = {}
    var chooseSession: (String) -> Void = { _ in }
    var openLive: (String) -> Void = { _ in }
    var openPhoneScreen: () -> Void = {}
    var findApps: () -> Void = {}
    var continueOnMac: () -> Void = {}
    var installApk: () -> Void = {}
    var turnOffScreen: () -> Void = {}
    var disconnectAgent: () -> Void = {}
    var pairAgain: () -> Void = {}
    var usePhone: (String) -> Void = { _ in }

    init() {}

    @MainActor
    init(controller: ConnectionController, openDeck: @escaping () -> Void) {
        setVolume = { [weak controller] fraction in controller?.setPhoneVolume(fraction) }
        setDnd = { [weak controller] on in controller?.setPhoneDnd(on: on) }
        setRinger = { [weak controller] mode in controller?.setPhoneRinger(mode) }
        ring = { [weak controller] in controller?.ringPhone() }
        stopRing = { [weak controller] in controller?.stopRingingPhone() }
        chooseSession = { [weak controller] key in controller?.chooseMediaSession(key) }
        openLive = { [weak controller] id in controller?.openLiveNotification(id) }
        openPhoneScreen = { [weak controller] in controller?.openPhoneWindow() }
        findApps = { [weak controller] in
            openDeck()
            controller?.requestSearchFocus()
        }
        continueOnMac = { [weak controller] in controller?.continueOnMac() }
        installApk = { [weak controller] in controller?.chooseApk() }
        turnOffScreen = { [weak controller] in controller?.windows.togglePhonePanelOff() }
        disconnectAgent = { [weak controller] in controller?.mcp.disconnectAgents() }
        pairAgain = { [weak controller] in controller?.pairAgain(source: .menubar) }
        usePhone = { [weak controller] id in controller?.usePhone(id: id) }
    }
}

/// The panel's sticky banner (PAIR-33/35): the same sentence the Deck shows for
/// a phone that no longer trusts this Mac, whose connections switch is off, or
/// that cannot be found. Never a code, never a transient line.
enum PhonePanelNotice {
    static func banner(for link: Link,
                       naming: (PhoneRef) -> String = \.name,
                       lastSeen: Date? = nil) -> Banner? {
        switch link {
        case .needsPairing, .offline(_, .connectionsOff), .offline(_, .notFound):
            return link.banner(naming: naming, lastSeen: lastSeen)
        default:
            return nil
        }
    }
}

extension PhoneControlsState.Connection {
    /// The panel's connection. A live session with no usable path is not
    /// Connected: it says Reconnecting at once and Offline after the windows'
    /// 15 s, while the session itself keeps its 30 s grace (PATH-6/PATH-17).
    static func resolve(link: Link, pathsDown: Bool, pathsOffline: Bool) -> Self {
        switch link {
        case .online: return pathsDown ? (pathsOffline ? .offline : .reconnecting) : .online
        case .connecting, .pairing: return .connecting
        // The controller reports a path outage as Reconnecting; the panel holds
        // it for the windows' 15 s and then says Offline (PANEL-12).
        case .reconnecting: return pathsDown && pathsOffline ? .offline : .reconnecting
        case .offline: return .offline
        case .needsPairing: return .needsPairing
        case .idle: return .idle
        }
    }
}

extension PhoneControlsState {
    @MainActor
    init(controller: ConnectionController) {
        phoneName = controller.activePhone.map {
            controller.displayName(for: $0, fallback: "your phone")
        } ?? "your phone"
        connection = .resolve(link: controller.link, pathsDown: controller.pathsDown,
                              pathsOffline: controller.pathsOffline)
        notice = controller.presentation.panelNotice
        battery = controller.status?.battery
        charging = controller.status?.charging ?? false
        locked = controller.status?.locked ?? false
        lastSeen = controller.lastSeen
        phones = controller.rememberedPhones.map { phone in
            PhoneControlsState.PanelPhone(
                id: phone.id,
                name: controller.displayName(for: phone.ref, fallback: phone.name),
                active: phone.id == controller.currentId)
        }
        handoff = controller.frontAppRow
        frontFresh = controller.frontAppFresh
        frontNone = controller.frontAppNone
        agentCount = controller.mcp.clientCount
        media = controller.mediaNow
        sessions = controller.mediaSessions
        dnd = controller.phoneDnd
        ringer = controller.phoneRinger
        phoneWindow = controller.windows.phoneWindow != nil
        panelOff = controller.windows.phoneWindow?.panelOffShown ?? false
        volume = controller.status?.volume
        volumeMax = controller.status?.volumeMax
        ringing = controller.ringing
        live = controller.liveNotifications
        liveTick = controller.liveTick
        installBusy = controller.apkInstaller.isBusy
        installTitle = Self.installTitle(controller.apkInstaller.phase)
    }

    private static func installTitle(_ phase: ApkInstaller.Phase) -> String {
        switch phase {
        case .idle, .finished: return "Install APK…"
        case .waiting: return "Waiting for your phone…"
        case .preparing(let name): return "Preparing \(name)…"
        case .sending(let name, let fraction): return "Sending \(name)… \(Int(fraction * 100))%"
        case .installing(let name): return "Installing \(name)…"
        }
    }
}

/// The panel's rows in focus order, top to bottom: what the keyboard tabs
/// through and what `PhonePanelProbe` maps the hosting view's key views to.
enum PhonePanelItem: String, CaseIterable {
    case phonePicker, volume, dnd, ringer, ring, screen, sessions, live, liveDismiss,
         continueOnMac, phoneScreen, findApps, installApk, disconnectAgent, gear

    var id: String { "panel.\(rawValue)" }

    var label: String {
        switch self {
        case .phonePicker: return "Phone"
        case .volume: return "Phone volume"
        case .dnd: return "Focus"
        case .ringer: return "Ringer"
        case .ring: return "Ring Phone"
        case .screen: return "Turn Off Screen"
        case .sessions: return "Now Playing follows"
        case .live: return "Live notification"
        case .liveDismiss: return "Dismiss notification"
        case .continueOnMac: return "Open Current App on Mac"
        case .phoneScreen: return "Phone Mirror"
        case .findApps: return "Find Apps"
        /// Kept for the Phone menu's item; the card does not draw it (PANEL-16).
        case .installApk: return "Install APK…"
        case .disconnectAgent: return "Disconnect the AI agent"
        /// The gear: an icon-only button that opens the icon's menu, named for
        /// VoiceOver after what is behind it.
        case .gear: return "Settings and more"
        }
    }

    /// One entry per focusable control the state renders, in Tab order: the
    /// header's gear first (it is the card's first control, top-right), then
    /// the phone pop-up with 2+ phones, the agent row's Disconnect while an
    /// agent is connected, the Sound slider, the four modules, the picker, the
    /// live rows (each with its Dismiss), the handoff row when shown, and the
    /// two window buttons (PANEL-20). Install APK… is the Phone menu's, never
    /// a card row.
    static func focusOrder(for state: PhoneControlsState, showsGear: Bool = false) -> [PhonePanelItem] {
        var items: [PhonePanelItem] = []
        if showsGear { items.append(.gear) }
        if state.showsPhonePicker { items.append(.phonePicker) }
        if state.agentCount > 0 { items.append(.disconnectAgent) }
        items.append(.volume)
        items += [.dnd, .ringer, .ring, .screen]
        if state.showsPicker { items.append(.sessions) }
        for _ in state.live {
            items.append(.live)
            items.append(.liveDismiss)
        }
        if state.showsHandoff { items.append(.continueOnMac) }
        items += [.phoneScreen, .findApps]
        return items
    }

    /// Where the opening focus lands: the first phone module below the header,
    /// never the gear or the phone pop-up above it (the person's ask,
    /// 2026-10-27) and never a destructive action (ISS-75). The agent row's
    /// Disconnect and the Sound slider sit above the modules, so the card
    /// steps past them too: the ring lands on Focus with and without an agent.
    static func openingFocus(for state: PhoneControlsState) -> PhonePanelItem {
        .dnd
    }

    /// How many key views the card steps past the gear to reach its opening
    /// focus: the gear heads the key order, and every control between it and
    /// `openingFocus` adds one. The panel and the hosted focus test both step
    /// this many, so the pure rule and the real key loop cannot drift.
    static func openingFocusSteps(for state: PhoneControlsState) -> Int {
        focusOrder(for: state, showsGear: true).firstIndex(of: openingFocus(for: state)) ?? 1
    }
}

/// One grid for the panel: the fixed width, the 28 pt rows, the icon column
/// every row's symbol sits in and one vertical rhythm. The two hosts, the debug
/// probe and the geometry tests read these numbers instead of their own.
enum PhonePanelMetrics {
    static let width: CGFloat = 300
    /// The one side inset every section shares: header, modules, rows, buttons
    /// and the gear. Nothing is indented past it (CONV-MAC-26).
    static let inset: CGFloat = 12
    static let headerHeight: CGFloat = 44

    /// The gear's button and its top offset from the card's top edge. The
    /// controller reads these to anchor the gear's menu at the button, so the
    /// two never disagree (MenuBarMenuAnchor.gearRect).
    static let gearSize: CGFloat = 22
    static let gearTop: CGFloat = 21
    /// The header's phone name while it is a pop-up: long names truncate
    /// rather than widen the card or run under the battery and the gear
    /// (PANEL-6/PANEL-27).
    static let pickerNameWidth: CGFloat = 150
    static let rowHeight: CGFloat = 28
    static let rowCorner: CGFloat = 6
    static let iconColumn: CGFloat = 18
    /// The rhythm, one scale for the panel: 8 inside a group (one module row to
    /// the next), 12 between sections.
    static let groupGap: CGFloat = 8
    static let sectionGap: CGFloat = 12
    static let sectionHeight: CGFloat = 16
    /// P2's modules: two 134 pt modules with 8 pt between them, 62 pt tall.
    static let tileGap: CGFloat = 8
    static let tileWidth = (rowWidth - tileGap) / 2
    static let tileMinHeight: CGFloat = 62
    static let tileCorner: CGFloat = 12
    static let tilePadding: CGFloat = 10
    /// The full-width modules: Sound (label row + slider), Now Playing and the
    /// handoff row.
    static let soundMinHeight: CGFloat = 54
    static let nowPlayingMinHeight: CGFloat = 46
    static let handoffMinHeight: CGFloat = 42
    /// The WINDOWS row: two normal-text buttons, 8 pt apart, 32 pt tall.
    static let windowGap: CGFloat = 8
    static let windowMinHeight: CGFloat = 32
    static let windowCorner: CGFloat = 10

    /// One row's width inside the panel's inset.
    static let rowWidth = width - inset * 2
}

/// Whether a row's own control can do anything in this state: one mapping for
/// the view, the debug probe and the tests, so a disabled row looks and
/// behaves the same wherever it is read.
extension PhonePanelItem {
    func isEnabled(in state: PhoneControlsState) -> Bool { reason(in: state) == nil }

    /// Whether a module draws as on (accent): the phone's own state, but only
    /// while the module can act. A disabled module is dimmed neutral, never
    /// accent, so it cannot read as a control that is on (CONV-MAC-25).
    func isOn(in state: PhoneControlsState) -> Bool {
        guard isEnabled(in: state) else { return false }
        switch self {
        case .dnd: return state.dndOn
        case .ringer: return state.ringer != .normal && state.ringer != nil
        case .ring: return state.ringing
        case .screen: return state.panelOff
        default: return false
        }
    }

    /// Why this control cannot work, or nil when it can. Offline comes first,
    /// then the phone's missing capability. A control that cannot work is
    /// disabled with its reason, never hidden (AGENTS "Honest settings").
    func unavailable(in state: PhoneControlsState) -> PanelUnavailable? {
        switch self {
        case .volume:
            guard state.connection.isOnline else { return .offline }
            return state.volumeFraction == nil ? .volumeUnreported : nil
        case .dnd:
            guard state.connection.isOnline else { return .offline }
            return state.dnd == nil ? .dndUnreported : nil
        case .ringer:
            guard state.connection.isOnline else { return .offline }
            if state.ringer == nil { return .ringerUnreported }
            if state.dndOn && state.dnd != nil { return .ringerNeedsDndOff }
            return nil
        case .ring, .phoneScreen, .continueOnMac:
            return state.connection.isOnline ? nil : .offline
        case .screen:
            // The same offline gate as every other control: a request sent
            // into a dead session is a click that silently does nothing
            // (PANEL-12/PANEL-19, misses.md M3).
            guard state.connection.isOnline else { return .offline }
            return state.phoneWindow ? nil : .mirrorClosed
        case .installApk:
            guard state.connection.isOnline else { return .offline }
            return state.installBusy ? .installBusy : nil
        case .phonePicker, .sessions, .live, .liveDismiss, .findApps, .disconnectAgent, .gear:
            return nil
        }
    }

    /// The reason in the person's words: a full sentence, for a help tag and a
    /// VoiceOver hint.
    func reason(in state: PhoneControlsState) -> String? {
        unavailable(in: state)?.sentence
    }

    /// A help tag with a disabled module's reason after it, while online. While
    /// the link is down no module repeats the group's reason; the Screen
    /// module's help tag is its short reason itself (PANEL-12/PANEL-19). The
    /// view, the tooltip and VoiceOver read this one string.
    func help(in state: PhoneControlsState) -> String {
        let base: String
        switch self {
        case .dnd: base = "\(label) — \(state.dndOn ? "Do Not Disturb" : "Off")"
        case .ringer: base = "\(label) — \(state.ringerTitle)"
        case .ring: base = "\(state.ringTitle) — \(state.ringSubtitle)"
        case .screen: base = "\(label) — \(state.screenTitle)"
        default: base = label
        }
        guard state.connection.isOnline, let reason = reason(in: state) else { return base }
        if self == .screen, let short = shortReason(in: state) { return short }
        return "\(base) — \(reason)"
    }

    /// The line a disabled module shows in place of its state. The full
    /// sentence is its VoiceOver hint. While the link is down the four modules
    /// show no line at all: the Sound module carries the group's one reason
    /// (PANEL-19).
    func shortReason(in state: PhoneControlsState) -> String? {
        guard state.connection.isOnline else { return nil }
        return unavailable(in: state)?.shortLine
    }
}

/// Why a panel control cannot work. One value gives both the full sentence and
/// a tile's short line, so the two never disagree.
enum PanelUnavailable: Equatable {
    case offline
    case dndUnreported
    case ringerUnreported
    case volumeUnreported
    case ringerNeedsDndOff
    case mirrorClosed
    case installBusy

    var sentence: String {
        switch self {
        case .offline: return "Connect your phone to use these."
        case .dndUnreported: return "This phone doesn't report Do Not Disturb."
        case .ringerUnreported: return "This phone doesn't report a ringer."
        case .volumeUnreported: return "Your phone hasn't sent a volume."
        case .ringerNeedsDndOff: return "Turn off Do Not Disturb to change the ringer."
        case .mirrorClosed: return "Open Phone Mirror first."
        case .installBusy: return "An install is already running."
        }
    }

    var shortLine: String {
        switch self {
        case .offline: return "Connect phone first"
        case .dndUnreported, .ringerUnreported, .volumeUnreported: return "Not on this phone"
        case .ringerNeedsDndOff: return "Off while DND is on"
        case .mirrorClosed: return "Open Mirror first"
        case .installBusy: return "Install running"
        }
    }
}

struct PhonePanelView: View {
    let state: PhoneControlsState
    let actions: PhoneControlsActions
    /// The menu bar panel's gear: an icon-only button that opens the icon's
    /// menu. The Deck's popover passes none — the Deck has its own gear and the
    /// app menu has the same commands.
    let onGear: (() -> Void)?
    /// The menu bar panel reports its card height so the window can follow a
    /// row that arrives or leaves (PANEL-4). The Deck popover and the tests
    /// pass none: their host sizes itself.
    let onSizeChange: ((CGFloat) -> Void)?

    static let width: CGFloat = PhonePanelMetrics.width

    /// The long sentence for the handoff module's help tag and VoiceOver label:
    /// what it does, not "continue" (CONV-PD-09).
    static let handoffHelp = FrontAppRow.genericHelp

    private let inset: CGFloat = PhonePanelMetrics.inset
    @State private var volume: PhoneVolumeControl
    @State private var settleTimeout: Task<Void, Never>?
    @State private var dismissed: Set<String> = []
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(state: PhoneControlsState, actions: PhoneControlsActions,
         onGear: (() -> Void)? = nil,
         onSizeChange: ((CGFloat) -> Void)? = nil) {
        self.state = state
        self.actions = actions
        self.onGear = onGear
        self.onSizeChange = onSizeChange
        _volume = State(initialValue: PhoneVolumeControl(display: state.volumeFraction ?? 0))
    }

    var body: some View {
        // The gear is drawn over the card, after it, so the key view loop
        // reaches it in the header's own order and it never takes the opening
        // focus (focusOrder puts it first; openingFocus steps past it).
        ZStack(alignment: .topTrailing) {
            if let onGear {
                gearButton(onGear)
                    .offset(x: -inset, y: PhonePanelMetrics.gearTop)
                    .zIndex(1)
            }
            card
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.height
                } action: { height in
                    onSizeChange?(height)
                }
        }
        .onAppear { syncVolume() }
        .onChange(of: state.volumeFraction) { _, _ in syncVolume() }
        .onChange(of: state.live.map(\.id)) { _, ids in
            dismissed.formIntersection(Set(ids))
        }
        .onDisappear { settleTimeout?.cancel() }
    }

    /// The card itself: every section starts a sectionGap below the one above,
    /// on the one inset; nothing floats between sections.
    private var card: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if let notice = state.notice {
                noticeRow(notice).padding(.top, PhonePanelMetrics.sectionGap)
            }
            if state.agentCount > 0 { agentRow.padding(.top, PhonePanelMetrics.sectionGap) }
            soundModule.padding(.top, PhonePanelMetrics.sectionGap)
            modules.padding(.top, PhonePanelMetrics.sectionGap)
            if state.showsPicker { nowPlaying.padding(.top, PhonePanelMetrics.sectionGap) }
            if !visibleLive.isEmpty { liveSection.padding(.top, PhonePanelMetrics.sectionGap) }
            if let handoff = state.handoff, state.connection.isOnline {
                handoffModule(handoff)
                    .padding(.top, PhonePanelMetrics.sectionGap)
                    .transition(.opacity)
            }
            windowsRow.padding(.top, PhonePanelMetrics.sectionGap)
        }
        .padding(inset)
        .frame(width: Self.width)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: state.handoff)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: visibleLive.map(\.id))
    }

    /// The Deck's sticky banner in the panel (PAIR-33/35): text, the one line
    /// that names the fix, and at most Pair again. No close control.
    private func noticeRow(_ notice: Banner) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 12))
                .foregroundStyle(.orange)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(notice.text)
                    .font(.system(size: 12))
                    .fixedSize(horizontal: false, vertical: true)
                if let detail = notice.detail {
                    Text(detail)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let lastSeen = notice.lastSeen {
                    Text(LastSeen.line(lastSeen))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 6)
            if notice.action == .pairAgain {
                Button(PairAgainCopy.banner, action: actions.pairAgain)
                    .buttonStyle(.glassProminent)
                    .controlSize(.small)
                    .accessibilityLabel(PairAgainCopy.banner)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.12), in: .rect(cornerRadius: PhonePanelMetrics.rowCorner))
        .accessibilityElement(children: .contain)
    }

    /// The phone's value is the slider's value while idle; a drag or a settle
    /// in progress ignores it (the machine decides).
    private func syncVolume() {
        let tolerance = state.volumeMax.map { 1.0 / Double($0) / 2 } ?? 0.005
        volume.sync(phone: state.volumeFraction, tolerance: tolerance, at: Date())
        PhoneVolumeDebug.update(volume)
    }

    private func finishVolumeDrag() {
        guard let sent = volume.end(at: Date()) else { return }
        PhoneVolumeDebug.update(volume)
        actions.setVolume(sent)
        settleTimeout?.cancel()
        settleTimeout = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            _ = volume.expire(at: Date(), phone: volume.phone)
            PhoneVolumeDebug.update(volume)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            headerIdentity
            // Room for the overlaid gear, so the battery keeps its distance
            // from it without a second focusable control in the header.
            if onGear != nil {
                Color.clear.frame(width: PhonePanelMetrics.gearSize,
                                  height: PhonePanelMetrics.gearSize)
            }
        }
        .frame(height: PhonePanelMetrics.headerHeight)
    }

    /// The phone and its connection, the battery. With two or more phones the
    /// name is its own pop-up (PANEL-27); the link/lock/battery line is one
    /// VoiceOver element, so the name and the gear stay controls of their own.
    private var headerIdentity: some View {
        HStack(spacing: 10) {
            Image(systemName: state.connection.isOnline ? "iphone.gen3" : "iphone.slash")
                .font(.system(size: 22))
                .foregroundStyle(.tint)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                nameLine
                statusLine
                if !state.connection.isOnline, let lastSeen = state.lastSeen {
                    Text(LastSeen.line(lastSeen))
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            if let battery = state.shownBattery {
                let low = BatterySymbol.isLow(level: battery, charging: state.charging)
                HStack(spacing: 3) {
                    Image(systemName: BatterySymbol.name(level: battery, charging: state.charging))
                    Text("\(battery)%").monospacedDigit()
                }
                .font(.caption)
                .foregroundStyle(low ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                .accessibilityHidden(true)
            }
        }
    }

    /// One phone: the name, plain. Two or more: a short checkmark pop-up that
    /// switches the phone in use through the app's one route (SET-DEV-03), the
    /// macOS way to pick the device the card speaks for.
    @ViewBuilder
    private var nameLine: some View {
        if state.showsPhonePicker {
            Menu {
                ForEach(state.phones) { phone in
                    Button {
                        actions.usePhone(phone.id)
                    } label: {
                        if phone.active {
                            Label(phone.name, systemImage: "checkmark")
                        } else {
                            Text(phone.name)
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(state.phoneName)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .accessibilityLabel("\(state.phoneName), phone in use")
            .accessibilityIdentifier(PhonePanelItem.phonePicker.id)
            .help("Choose the phone the panel acts on.")
        } else {
            Text(state.phoneName)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .accessibilityLabel(state.phoneName)
        }
    }

    /// The dot plus the link's words, the lock while the phone is locked, and
    /// the last-seen line while it is away: one VoiceOver element.
    private var statusLine: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(statusColor)
                .frame(width: 6, height: 6)
            Text(state.connection.text)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            if state.connection.isOnline, state.locked {
                Image(systemName: "lock.fill")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(headerLabel)
    }

    private var headerLabel: String {
        var parts = [state.connection.text]
        if state.connection.isOnline, state.locked { parts.append("locked") }
        if let battery = state.shownBattery { parts.append("\(battery)% battery") }
        if !state.connection.isOnline, let lastSeen = state.lastSeen {
            parts.append(LastSeen.line(lastSeen))
        }
        return parts.joined(separator: ", ")
    }

    /// The gear, at the panel's top-right: an icon-only button whose help tag
    /// names what is behind it (Settings, About, Quit). The top and trailing
    /// padding put its centre on the header row, on the panel's one inset.
    private func gearButton(_ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "gearshape")
                .font(.system(size: 13))
                .frame(width: PhonePanelMetrics.gearSize, height: PhonePanelMetrics.gearSize)
                .contentShape(.rect(cornerRadius: PhonePanelMetrics.rowCorner))
        }
        .buttonStyle(PanelControlStyle(kind: .row, corner: PhonePanelMetrics.rowCorner,
                                       hoverID: PhonePanelItem.gear.id))
        .accessibilityLabel(PhonePanelItem.gear.label)
        .accessibilityIdentifier(PhonePanelItem.gear.id)
        .help("Settings, About and Quit")
    }

    private var agentRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles").font(.system(size: 12))
            Text("AI agent connected").font(.system(size: 12))
            Spacer(minLength: 6)
            Button("Disconnect") { actions.disconnectAgent() }
                .buttonStyle(.glass)
                .controlSize(.mini)
                .accessibilityLabel("Disconnect the AI agent")
                .accessibilityIdentifier(PhonePanelItem.disconnectAgent.id)
        }
        .frame(height: 24)
    }

    // MARK: - The Sound module and the 2×2 modules

    /// A module's second line: its state while it can act, else why it cannot
    /// while online. While the link is down the four modules show no line: the
    /// Sound module carries the group's one reason (PANEL-19).
    private func moduleLine(_ item: PhonePanelItem, _ text: String) -> String {
        guard item.isEnabled(in: state) else { return item.shortReason(in: state) ?? "" }
        return text
    }

    private var modules: some View {
        VStack(spacing: PhonePanelMetrics.tileGap) {
            HStack(spacing: PhonePanelMetrics.tileGap) {
                dndModule
                ringerModule
            }
            HStack(spacing: PhonePanelMetrics.tileGap) {
                ringModule
                screenModule
            }
        }
    }

    private var dndModule: some View {
        let item = PhonePanelItem.dnd
        let enabled = item.isEnabled(in: state)
        let stateText = state.dndOn ? "Do Not Disturb" : "Off"
        let line = moduleLine(item, stateText)
        return Button {
            actions.setDnd(!state.dndOn)
        } label: {
            moduleLabel(symbol: state.dndOn ? "moon.fill" : "moon",
                        title: item.label,
                        subtitle: line,
                        lit: item.isOn(in: state), enabled: enabled)
        }
        .buttonStyle(PanelControlStyle(enabled: enabled, active: item.isOn(in: state), hoverID: item.id))
        .disabled(!enabled)
        .accessibilityLabel(item.label)
        .accessibilityValue(enabled ? stateText : (line.isEmpty ? "" : line))
        .accessibilityHint(item.reason(in: state) ?? "")
        .accessibilityIdentifier(item.id)
        .help(item.help(in: state))
    }

    /// The Ringer module opens a menu; its own click never cycles the mode. The
    /// current mode is checked and named under the bell.
    private var ringerModule: some View {
        let item = PhonePanelItem.ringer
        let enabled = item.isEnabled(in: state)
        let line = moduleLine(item, state.ringerTitle)
        return Menu {
            ForEach(state.ringerMenu) { row in
                Button {
                    actions.setRinger(row.mode)
                } label: {
                    if row.checked {
                        Label(row.name, systemImage: "checkmark")
                    } else {
                        Text(row.name)
                    }
                }
            }
        } label: {
            moduleLabel(symbol: ringerSymbol,
                        title: item.label,
                        subtitle: line,
                        lit: item.isOn(in: state), enabled: enabled)
        }
        .menuStyle(.button)
        .buttonStyle(PanelControlStyle(enabled: enabled, active: item.isOn(in: state), hoverID: item.id))
        .menuIndicator(.hidden)
        .disabled(!enabled)
        .accessibilityLabel(item.label)
        .accessibilityValue(enabled ? state.ringerTitle : (line.isEmpty ? "" : line))
        .accessibilityHint(item.reason(in: state) ?? "")
        .accessibilityIdentifier(item.id)
        .help(item.help(in: state))
    }

    private var ringModule: some View {
        let item = PhonePanelItem.ring
        let enabled = item.isEnabled(in: state)
        let line = moduleLine(item, state.ringSubtitle)
        return Button {
            state.ringing ? actions.stopRing() : actions.ring()
        } label: {
            moduleLabel(symbol: state.ringing ? "bell.slash" : "iphone.radiowaves.left.and.right",
                        title: state.ringTitle,
                        subtitle: line,
                        lit: item.isOn(in: state), enabled: enabled)
        }
        .buttonStyle(PanelControlStyle(enabled: enabled, active: item.isOn(in: state), hoverID: item.id))
        .disabled(!enabled)
        .accessibilityLabel(state.ringTitle)
        .accessibilityValue(enabled ? state.ringSubtitle : (line.isEmpty ? "" : line))
        .accessibilityHint(item.reason(in: state) ?? "")
        .accessibilityIdentifier(item.id)
        .help(item.help(in: state))
    }

    /// Turn Off Screen follows the phone window's held panel: the second line
    /// is the phone's own state, and the module is lit while it is off.
    private var screenModule: some View {
        let item = PhonePanelItem.screen
        let enabled = item.isEnabled(in: state)
        let line = moduleLine(item, state.screenTitle)
        return Button {
            actions.turnOffScreen()
        } label: {
            moduleLabel(symbol: state.panelOff ? "iphone.slash" : "iphone",
                        title: item.label,
                        subtitle: line,
                        lit: item.isOn(in: state), enabled: enabled)
        }
        .buttonStyle(PanelControlStyle(enabled: enabled, active: item.isOn(in: state), hoverID: item.id))
        .disabled(!enabled)
        .accessibilityLabel(item.label)
        .accessibilityValue(enabled ? state.screenTitle : (line.isEmpty ? "" : line))
        .accessibilityHint(item.reason(in: state) ?? "")
        .accessibilityIdentifier(item.id)
        .help(item.help(in: state))
    }

    private var ringerSymbol: String {
        switch state.ringer {
        case .vibrate: return "iphone.radiowaves.left.and.right"
        case .silent: return "bell.slash.fill"
        case .normal, nil: return "bell.fill"
        }
    }

    /// One module's content: symbol, title and its second line. Lit, the type
    /// is white on the accent. Disabled, all three lines are neutral grey, so
    /// the module reads as off and not operable (CONV-MAC-25); its fill and
    /// hover come from PanelControlStyle.
    private func moduleLabel(symbol: String, title: String, subtitle: String,
                             lit: Bool, enabled: Bool) -> some View {
        // `.secondary` still reads near-primary on the panel material. A
        // disabled module draws every line at a fixed low opacity (35 %), so
        // its title contrast is under half an enabled title's on both
        // appearances (reviewer round 2, fix 1c). The fill comes from
        // PanelControlStyle.
        let muted = AnyShapeStyle(Color.primary.opacity(0.35))
        let strong: AnyShapeStyle = lit ? AnyShapeStyle(.white)
            : enabled ? AnyShapeStyle(.primary) : muted
        let weak: AnyShapeStyle = lit ? AnyShapeStyle(.white.opacity(0.85))
            : enabled ? AnyShapeStyle(.secondary) : muted
        return VStack(alignment: .leading, spacing: 2) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(strong)
            Spacer(minLength: 2)
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .foregroundStyle(strong)
            // A module with no state line (offline) keeps its second line's
            // box, so the group's height never changes with the link.
            Text(subtitle.isEmpty ? " " : subtitle)
                .font(.system(size: 9))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .foregroundStyle(weak)
        }
        .padding(PhonePanelMetrics.tilePadding)
        .frame(maxWidth: .infinity, minHeight: PhonePanelMetrics.tileMinHeight, alignment: .leading)
        .contentShape(.rect(cornerRadius: PhonePanelMetrics.tileCorner))
    }

    // MARK: - Sound, Now Playing, Live, handoff, windows

    /// The full-width Sound module: the speaker, the word "Sound" and the
    /// phone's percentage on one line, the volume slider under it. Where the
    /// slider would be, a disabled module says why, so the reason sits on the
    /// control it disables and not in a line of its own (PANEL-13/PANEL-19).
    private var soundModule: some View {
        let item = PhonePanelItem.volume
        let enabled = item.isEnabled(in: state)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "speaker.fill")
                    .font(.system(size: 12, weight: .medium))
                Text("Sound")
                    .font(.system(size: 11, weight: .semibold))
                Spacer(minLength: 4)
                Text(volumeText)
                    .font(.system(size: 10))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .foregroundStyle(enabled ? AnyShapeStyle(.primary) : AnyShapeStyle(Color.primary.opacity(0.35)))
            if let reason = item.reason(in: state) {
                Text(reason)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.9)
                    .accessibilityIdentifier("panel.volumeReason")
            } else {
                Slider(value: Binding(
                    get: {
                        PhoneVolumeDebug.update(volume)
                        return volume.display
                    },
                    set: { fraction in
                        let now = Date()
                        if !volume.isDragging { volume.begin(at: now) }
                        if volume.drag(to: fraction, at: now) { actions.setVolume(fraction) }
                        PhoneVolumeDebug.update(volume)
                    },
                ), in: 0...1, onEditingChanged: { editing in
                    if editing {
                        volume.begin(at: Date())
                        PhoneVolumeDebug.update(volume)
                    } else {
                        finishVolumeDrag()
                    }
                })
                .controlSize(.small)
                .accessibilityLabel(item.label)
                .accessibilityValue(volumeText)
                .accessibilityIdentifier(item.id)
            }
        }
        .padding(PhonePanelMetrics.tilePadding)
        .frame(maxWidth: .infinity, minHeight: PhonePanelMetrics.soundMinHeight, alignment: .leading)
        .background(Color.primary.opacity(enabled ? PanelFill.filledRest : PanelFill.filledDisabled),
                    in: RoundedRectangle(cornerRadius: PhonePanelMetrics.tileCorner))
        .contentShape(.rect(cornerRadius: PhonePanelMetrics.tileCorner))
        .accessibilityElement(children: .contain)
    }

    private var volumeText: String {
        guard state.volumeFraction != nil else { return "—" }
        return "\(Int((volume.display * 100).rounded()))%"
    }

    /// The Now Playing module: the caption and the chosen app on two lines, the
    /// session picker behind the chevron (PANEL-14). Only with two or more
    /// sessions, unchanged in behaviour.
    private var nowPlaying: some View {
        Menu {
            ForEach(state.sessions) { row in
                Button {
                    actions.chooseSession(row.key)
                } label: {
                    Text(row.playing ? "\(row.app) — playing" : row.app)
                }
            }
        } label: {
            HStack(spacing: 9) {
                Image(systemName: "music.note")
                    .font(.system(size: 13))
                    .frame(width: 20)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Now playing")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                    Text(state.pickerApp)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(PhonePanelMetrics.tilePadding)
            .frame(maxWidth: .infinity, minHeight: PhonePanelMetrics.nowPlayingMinHeight,
                   alignment: .leading)
            .contentShape(.rect(cornerRadius: PhonePanelMetrics.tileCorner))
        }
        .menuStyle(.button)
        .buttonStyle(PanelControlStyle(kind: .filled, corner: PhonePanelMetrics.tileCorner,
                                       hoverID: PhonePanelItem.sessions.id))
        .menuIndicator(.hidden)
        .accessibilityLabel(state.pickerTitle)
        .accessibilityIdentifier(PhonePanelItem.sessions.id)
        .help(state.pickerTitle)
    }

    private var visibleLive: [NotifyLiveItem] {
        PhonePanelLiveRows.visible(state.live, dismissed: dismissed)
    }

    private var liveSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionLabel("Live")
            ForEach(visibleLive) { item in
                liveRow(item)
            }
        }
    }

    /// One Live row: the notification's click action, and its own Dismiss
    /// button. Dismissing hides the row on the Mac only; it sends nothing to
    /// the phone and leaves the other rows (PANEL-15).
    private func liveRow(_ item: NotifyLiveItem) -> some View {
        let title = NotifyLiveText.menuTitle(item, now: state.liveTick)
        return HStack(spacing: 0) {
            Button {
                actions.openLive(item.id)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "bell.badge")
                        .font(.system(size: 12))
                        .frame(width: PhonePanelMetrics.iconColumn)
                        .foregroundStyle(.secondary)
                    Text(title)
                        .font(.system(size: 12))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                }
                .frame(height: PhonePanelMetrics.rowHeight)
                .contentShape(.rect)
            }
            .buttonStyle(PanelControlStyle(kind: .row, corner: PhonePanelMetrics.rowCorner,
                                           hoverID: PhonePanelItem.live.id))
            .accessibilityLabel(title)
            .accessibilityIdentifier(PhonePanelItem.live.id)
            Button {
                dismissLive(item.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
                    .background(Color.primary.opacity(0.08), in: .circle)
            }
            .buttonStyle(PanelControlStyle(kind: .row, corner: 9,
                                           hoverID: PhonePanelItem.liveDismiss.id))
            .accessibilityLabel(PhonePanelItem.liveDismiss.label)
            .accessibilityIdentifier(PhonePanelItem.liveDismiss.id)
            .help("Dismiss")
        }
    }

    private func dismissLive(_ id: String) {
        dismissed.insert(id)
    }

    /// The handoff module: the app's icon, "Open <App> on Mac", the arrow. It
    /// exists only while the phone reports an app in front (PANEL-28); a click
    /// opens the handoff window, the same function as the Phone menu's item.
    private func handoffModule(_ handoff: FrontAppRow) -> some View {
        let item = PhonePanelItem.continueOnMac
        return Button {
            actions.continueOnMac()
        } label: {
            HStack(spacing: 9) {
                if let icon = handoff.icon {
                    Image(nsImage: icon)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 18, height: 18)
                        .clipShape(.rect(cornerRadius: 4, style: .continuous))
                } else {
                    Image(systemName: "app.fill")
                        .font(.system(size: 13))
                        .frame(width: 18, height: 18)
                        .foregroundStyle(.secondary)
                }
                Text(handoff.title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 4)
                Image(systemName: "arrow.up.forward")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(PhonePanelMetrics.tilePadding)
            .frame(maxWidth: .infinity, minHeight: PhonePanelMetrics.handoffMinHeight,
                   alignment: .leading)
            .contentShape(.rect(cornerRadius: PhonePanelMetrics.tileCorner))
        }
        .buttonStyle(PanelControlStyle(kind: .filled, corner: PhonePanelMetrics.tileCorner,
                                       hoverID: item.id))
        .accessibilityLabel(handoff.help)
        .accessibilityHint(handoff.help)
        .accessibilityIdentifier(item.id)
        .help(handoff.help)
    }

    /// The two normal-text window buttons, Phone Mirror and Apps, each with its
    /// shortcut in the tooltip and the full name to VoiceOver (PANEL-16).
    private var windowsRow: some View {
        HStack(spacing: PhonePanelMetrics.windowGap) {
            windowButton(.phoneScreen, title: "Phone Mirror", symbol: "iphone.gen3",
                         voiceOver: "Phone Mirror", help: "Phone Mirror (⌘P)",
                         action: actions.openPhoneScreen)
            windowButton(.findApps, title: "Apps", symbol: "square.grid.2x2",
                         voiceOver: "Find Apps", help: "Find Apps (⌘K)",
                         action: actions.findApps)
        }
    }

    private func windowButton(_ item: PhonePanelItem, title: String, symbol: String,
                              voiceOver: String, help: String,
                              action: @escaping () -> Void) -> some View {
        let enabled = item.isEnabled(in: state)
        return Button(action: action) {
            Label {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            } icon: {
                Image(systemName: symbol)
                    .font(.system(size: 13))
            }
            .foregroundStyle(enabled ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            .frame(maxWidth: .infinity, minHeight: PhonePanelMetrics.windowMinHeight)
            .contentShape(.rect(cornerRadius: PhonePanelMetrics.windowCorner))
        }
        .buttonStyle(PanelControlStyle(enabled: enabled, corner: PhonePanelMetrics.windowCorner,
                                       hoverID: item.id))
        .disabled(!enabled)
        .accessibilityLabel(voiceOver)
        .accessibilityHint(item.reason(in: state) ?? "")
        .accessibilityIdentifier(item.id)
        .help(windowHelp(help, for: item))
    }

    private func windowHelp(_ base: String, for item: PhonePanelItem) -> String {
        guard state.connection.isOnline, let reason = item.reason(in: state) else { return base }
        return "\(base) — \(reason)"
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(height: PhonePanelMetrics.sectionHeight, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }

    private var statusColor: Color {
        switch state.connection {
        case .online: return .green
        case .reconnecting, .needsPairing: return .orange
        case .connecting, .offline, .idle: return .secondary
        }
    }
}

/// PANEL-15: a Live row's local dismissal. The filter is the card's own: the
/// phone learns nothing, and the row leaves only this open card.
enum PhonePanelLiveRows {
    static func visible(_ rows: [NotifyLiveItem], dismissed: Set<String>) -> [NotifyLiveItem] {
        rows.filter { !dismissed.contains($0.id) }
    }
}

/// The fill levels, as opacities of the primary colour (white in Dark, black in
/// Light), so one value reads on both appearances. A tile or WINDOWS button
/// rests at 10 %, lifts to 25 % on hover and deepens to 34 % pressed: the
/// prototype's 9 % hover step was too faint, so hover is a step a person sees at
/// a glance (CONV-MAC-25, Control Center modules). A row rests clear and lifts
/// to 12 % and 20 %. An on tile lifts with white over the accent. A disabled
/// tile keeps 5 %, so it reads as present and not operable.
enum PanelFill {
    static let filledRest = 0.10
    static let filledHover = 0.25
    static let filledPressed = 0.34
    static let filledDisabled = 0.05
    static let rowHover = 0.12
    static let rowPressed = 0.20
    static let onHover = 0.10
    static let onPressed = 0.20
}

/// A clickable panel control's look (CONV-MAC-25): a rounded fill that lights on
/// hover and deepens while pressed, the way a Control Center module does. An on
/// tile is accent; a disabled control is dimmed neutral and never lights up.
/// Reduce Motion drops the press scale and the fade (CONV-MAC-22).
struct PanelControlStyle: ButtonStyle {
    /// A tile or a WINDOWS button rests on a fill; a row rests clear.
    enum Kind: Equatable { case filled, row }

    var kind: Kind = .filled
    var enabled = true
    /// The tile is on (accent fill). Only an enabled control can be on.
    var active = false
    var corner: CGFloat = PhonePanelMetrics.tileCorner
    /// The item this control is, for the e2e's forced hover (PanelHoverDebug).
    var hoverID: String?

    func makeBody(configuration: Configuration) -> some View {
        PanelControlSurface(style: self, isPressed: configuration.isPressed) {
            configuration.label
        }
    }
}

/// The surface behind a PanelControlStyle. It owns the hover state, so each
/// control lights up on its own pointer, not the panel's.
private struct PanelControlSurface<Content: View>: View {
    let style: PanelControlStyle
    let isPressed: Bool
    @ViewBuilder var content: Content
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The pointer's hover, or the e2e's forced hover on this control.
    private var isHovered: Bool {
        hovering || (style.hoverID != nil && PanelHoverDebug.shared.itemID == style.hoverID)
    }

    /// The neutral fill's opacity for the state the control is in.
    private var level: Double {
        let pressed = style.enabled && isPressed
        let hovered = style.enabled && isHovered
        switch style.kind {
        case .filled:
            guard style.enabled else { return PanelFill.filledDisabled }
            return pressed ? PanelFill.filledPressed : hovered ? PanelFill.filledHover : PanelFill.filledRest
        case .row:
            return pressed ? PanelFill.rowPressed : hovered ? PanelFill.rowHover : 0
        }
    }

    /// The white lift over an on tile's accent.
    private var onLevel: Double {
        guard style.enabled && style.active else { return 0 }
        return isPressed ? PanelFill.onPressed : isHovered ? PanelFill.onHover : 0
    }

    var body: some View {
        content
            .background {
                ZStack {
                    RoundedRectangle(cornerRadius: style.corner)
                        .fill(style.active && style.enabled ? Color.accentColor : Color.primary.opacity(level))
                    RoundedRectangle(cornerRadius: style.corner)
                        .fill(Color.white.opacity(onLevel))
                }
            }
            .scaleEffect(isPressed && style.enabled && !reduceMotion ? 0.98 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isHovered)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.08), value: isPressed)
            .onHover { hovering = $0 }
    }
}
