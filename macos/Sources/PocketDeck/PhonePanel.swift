// The phone controls the menu bar panel and the Deck popover share
// (docs/design/mac-redesign.md §3.8, docs/DESIGN.md "Deck"): one view, one
// item model, one copy. The panel is a fixed-width Control Center-style card:
// a header with the gear that opens the icon's menu, the PHONE section (volume,
// Do Not Disturb, Ring/Stop Ringing, the Now Playing picker), LIVE and WINDOWS.
// It never reads the track
// title, performer or artwork: the Mac's own Now Playing already shows those.
//
// The layout is fixed (300 pt wide, 28 pt rows) so the e2e can drive the real
// controls at their own frames: `PhonePanelProbe` (PanelProbe.swift) walks the
// hosting view's key-view proxies, which follow this view's focus order.

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

    var phoneName = "your phone"
    var connection: Connection = .idle
    /// The sticky problem the Deck's banner also shows (PAIR-33/35). A
    /// transient notice (a ring, an install) never reaches this row.
    var notice: Banner?
    var battery: Int?
    var charging = false

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

    /// The volume's own line (the tiles have their own, per control).
    var reason: String? { PhonePanelItem.volume.reason(in: self) }

    var volumeFraction: Double? {
        guard connection.isOnline, let volume, let max = volumeMax, max > 0 else { return nil }
        return min(Swift.max(Double(volume) / Double(max), 0), 1)
    }

    var showsPicker: Bool { MediaMenu.showsSessionPicker(sessions) }

    var pickerTitle: String {
        "Now playing: \(MediaMenu.chosenApp(sessions, chosen: media?.key) ?? "your phone")"
    }

    var ringTitle: String { ringing ? "Stop Ringing" : "Ring Phone" }

    /// [PANEL-8] The Ring Phone tile's second line. A timeout is not a state,
    /// so the tile says nothing under its title at rest; while the phone rings
    /// the line names the ring.
    var ringSubtitle: String { ringing ? "Ringing" : "" }
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
    }
}

/// The panel's sticky banner (PAIR-33/35): the same sentence the Deck shows for
/// a phone that no longer trusts this Mac, whose connections switch is off, or
/// that cannot be found. Never a code, never a transient line.
enum PhonePanelNotice {
    static func banner(for link: Link,
                       naming: (PhoneRef) -> String = \.name) -> Banner? {
        switch link {
        case .needsPairing, .offline(_, .connectionsOff), .offline(_, .notFound):
            return link.banner(naming: naming)
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
    case dnd, ringer, ring, screen, volume, sessions, live, phoneScreen, findApps,
         continueOnMac, installApk, disconnectAgent, gear

    var id: String { "panel.\(rawValue)" }

    var label: String {
        switch self {
        case .dnd: return "Do Not Disturb"
        case .ringer: return "Ringer"
        case .ring: return "Ring Phone"
        case .screen: return "Turn Off Screen"
        case .volume: return "Phone volume"
        case .sessions: return "Now Playing follows"
        case .live: return "Live notification"
        case .phoneScreen: return "Phone Mirror"
        case .findApps: return "Find Apps"
        case .continueOnMac: return "Move to Mac"
        case .installApk: return "Install APK…"
        case .disconnectAgent: return "Disconnect the AI agent"
        /// The gear: an icon-only button that opens the icon's menu, named for
        /// VoiceOver after what is behind it.
        case .gear: return "Settings and more"
        }
    }

    /// One entry per focusable control the state renders, in Tab order: the
    /// header's gear first (it is the card's first control, top-right), then
    /// the agent row's Disconnect button while an agent is connected, the four
    /// tiles, the volume, the picker, the live rows and the window buttons.
    /// The panel opens one step past the gear — see `openingFocus` — so the
    /// ring lands on the first tile and not on a secondary command.
    static func focusOrder(for state: PhoneControlsState, showsGear: Bool = false) -> [PhonePanelItem] {
        var items: [PhonePanelItem] = []
        if showsGear { items.append(.gear) }
        if state.agentCount > 0 { items.append(.disconnectAgent) }
        items += [.dnd, .ringer, .ring, .screen, .volume]
        if state.showsPicker { items.append(.sessions) }
        items += Array(repeating: .live, count: state.live.count)
        items += [.phoneScreen, .findApps, .continueOnMac, .installApk]
        return items
    }

    /// Where the opening focus lands: the first phone control below the header,
    /// never the gear above it (the person's ask, 2026-10-27) and never a
    /// destructive action (ISS-75). The agent row's Disconnect sits above the
    /// tiles, so the card steps past it too: the ring lands on the same control
    /// with and without an agent.
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
    /// The one side inset every section shares: header, tiles, rows, buttons
    /// and the gear. Nothing is indented past it (CONV-MAC-26).
    static let inset: CGFloat = 12
    /// How far a row's hover highlight reaches past the inset, so its content
    /// stays on the grid while the highlight sits just outside it.
    static let hoverBleed: CGFloat = 8
    static let headerHeight: CGFloat = 44
    /// The gear's button and its top offset from the card's top edge. The
    /// controller reads these to anchor the gear's menu at the button, so the
    /// two never disagree (MenuBarMenuAnchor.gearRect).
    static let gearSize: CGFloat = 22
    static let gearTop: CGFloat = 21
    static let rowHeight: CGFloat = 28
    static let rowCorner: CGFloat = 6
    static let iconColumn: CGFloat = 18
    static let iconTextSpace: CGFloat = 8
    /// The rhythm, one scale for the panel: 8 inside a group (one tile row to
    /// the next), 12 between sections.
    static let groupGap: CGFloat = 8
    static let sectionGap: CGFloat = 12
    static let sectionHeight: CGFloat = 16
    /// P3's 2×2 control tiles: two 134 pt tiles with 8 pt between them.
    static let tileGap: CGFloat = 8
    static let tileWidth = (rowWidth - tileGap) / 2
    static let tileMinHeight: CGFloat = 62
    static let tileCorner: CGFloat = 12
    static let tilePadding: CGFloat = 10
    /// The WINDOWS row: four icon buttons, 6 pt apart, 46 pt tall.
    static let windowGap: CGFloat = 6
    static let windowMinHeight: CGFloat = 46
    static let windowCorner: CGFloat = 10

    /// The text inset every row's title shares, from the panel's left edge.
    static let textInset = inset + iconColumn + iconTextSpace
    /// One row's width inside the panel's inset.
    static let rowWidth = width - inset * 2
}

/// Whether a row's own control can do anything in this state: one mapping for
/// the view, the debug probe and the tests, so a disabled row looks and
/// behaves the same wherever it is read.
extension PhonePanelItem {
    func isEnabled(in state: PhoneControlsState) -> Bool { reason(in: state) == nil }

    /// Whether a tile draws as on (accent): the phone's own state, but only
    /// while the tile can act. A disabled tile is dimmed neutral, never accent,
    /// so it cannot read as a control that is on (CONV-MAC-25).
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
        case .sessions, .live, .findApps, .disconnectAgent, .gear:
            return nil
        }
    }

    /// The reason in the person's words: a full sentence, for a help tag and a
    /// VoiceOver hint.
    func reason(in state: PhoneControlsState) -> String? {
        unavailable(in: state)?.sentence
    }

    /// The line a disabled tile shows in place of its state. The full sentence
    /// is its help tag and hint.
    func shortReason(in state: PhoneControlsState) -> String? {
        unavailable(in: state)?.shortLine
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

    static let width: CGFloat = PhonePanelMetrics.width

    /// The long sentence for the handoff button's help tag and VoiceOver label:
    /// what it does, not "continue" (CONV-PD-09).
    static let moveToMacHelp = "Moves the app on your phone's screen into its own Mac window, where you left off (⇧⌘C)"

    private let inset: CGFloat = PhonePanelMetrics.inset
    @State private var volume: PhoneVolumeControl
    @State private var settleTimeout: Task<Void, Never>?

    init(state: PhoneControlsState, actions: PhoneControlsActions,
         onGear: (() -> Void)? = nil) {
        self.state = state
        self.actions = actions
        self.onGear = onGear
        _volume = State(initialValue: PhoneVolumeControl(display: state.volumeFraction ?? 0))
    }

    var body: some View {
        // The gear is the ZStack's second child, so SwiftUI adds it after the
        // card and the key view loop reaches it last: it must not take the
        // opening focus (focusOrder ends with it too).
        ZStack(alignment: .topTrailing) {
            if let onGear {
                gearButton(onGear)
                    .offset(x: -inset, y: PhonePanelMetrics.gearTop)
                    .zIndex(1)
            }
            card
        }
        .onAppear { syncVolume() }
        .onChange(of: state.volumeFraction) { _, _ in syncVolume() }
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
            tiles
            volumeRow.padding(.top, PhonePanelMetrics.sectionGap)
            if state.showsPicker { pickerRow.padding(.top, PhonePanelMetrics.sectionGap) }
            if !state.live.isEmpty {
                sectionLabel("LIVE")
                ForEach(state.live) { item in
                    PanelRow(symbol: "bell.badge", title: NotifyLiveText.menuTitle(item, now: state.liveTick),
                             enabled: true) { actions.openLive(item.id) }
                        .accessibilityLabel(NotifyLiveText.menuTitle(item, now: state.liveTick))
                }
            }
            windowsRow
        }
        .padding(inset)
        .frame(width: Self.width)
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

    /// The phone and its connection, the battery: one VoiceOver element, so the
    /// gear beside it stays a control of its own.
    private var headerIdentity: some View {
        HStack(spacing: 10) {
            Image(systemName: state.connection.isOnline ? "iphone.gen3" : "iphone.slash")
                .font(.system(size: 22))
                .foregroundStyle(.tint)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(state.phoneName)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 6, height: 6)
                    Text(state.connection.text)
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(state.phoneName), \(state.connection.text)")
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

    // MARK: - The tiles

    /// A tile's second line: its state while the tile can act, else why it
    /// cannot (the full sentence is the tile's help tag and hint).
    private func tileLine(_ item: PhonePanelItem, _ text: String) -> String {
        item.isEnabled(in: state) ? text : (item.shortReason(in: state) ?? text)
    }

    /// A help tag with a disabled control's full reason after it.
    private func helpTag(_ base: String, for item: PhonePanelItem) -> String {
        guard let reason = item.reason(in: state) else { return base }
        return "\(base) — \(reason)"
    }

    private var tiles: some View {
        VStack(spacing: PhonePanelMetrics.tileGap) {
            HStack(spacing: PhonePanelMetrics.tileGap) {
                dndTile
                ringerTile
            }
            HStack(spacing: PhonePanelMetrics.tileGap) {
                ringTile
                screenTile
            }
        }
        .padding(.top, PhonePanelMetrics.sectionGap)
    }

    private var dndTile: some View {
        let item = PhonePanelItem.dnd
        let enabled = item.isEnabled(in: state)
        return Button {
            actions.setDnd(!state.dndOn)
        } label: {
            tileLabel(symbol: state.dndOn ? "moon.fill" : "moon",
                      title: item.label,
                      subtitle: tileLine(item, state.dndOn ? "On" : "Off"),
                      lit: item.isOn(in: state), enabled: enabled)
        }
        .buttonStyle(PanelControlStyle(enabled: enabled, active: item.isOn(in: state), hoverID: item.id))
        .disabled(!enabled)
        .accessibilityLabel("\(item.label), \(state.dndOn ? "On" : "Off")")
        .accessibilityHint(item.reason(in: state) ?? "")
        .accessibilityIdentifier(item.id)
        .help(helpTag("\(item.label) — \(state.dndOn ? "On" : "Off")", for: item))
    }

    /// The Ringer tile opens a menu; its own click never cycles the mode. The
    /// current mode is checked and named under the bell.
    private var ringerTile: some View {
        let item = PhonePanelItem.ringer
        let enabled = item.isEnabled(in: state)
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
            tileLabel(symbol: ringerSymbol,
                      title: item.label,
                      subtitle: tileLine(item, state.ringerTitle),
                      lit: item.isOn(in: state), enabled: enabled)
        }
        .menuStyle(.button)
        .buttonStyle(PanelControlStyle(enabled: enabled, active: item.isOn(in: state), hoverID: item.id))
        .menuIndicator(.hidden)
        .disabled(!enabled)
        .accessibilityLabel("\(item.label), \(state.ringerTitle)")
        .accessibilityHint(item.reason(in: state) ?? "")
        .accessibilityIdentifier(item.id)
        .help(helpTag("Ringer — \(state.ringerTitle)", for: item))
    }

    private var ringTile: some View {
        let item = PhonePanelItem.ring
        let enabled = item.isEnabled(in: state)
        return Button {
            state.ringing ? actions.stopRing() : actions.ring()
        } label: {
            tileLabel(symbol: state.ringing ? "bell.slash" : "iphone.radiowaves.left.and.right",
                      title: state.ringTitle,
                      subtitle: tileLine(item, state.ringSubtitle),
                      lit: item.isOn(in: state), enabled: enabled)
        }
        .buttonStyle(PanelControlStyle(enabled: enabled, active: item.isOn(in: state), hoverID: item.id))
        .disabled(!enabled)
        .accessibilityLabel(state.ringTitle)
        .accessibilityHint(item.reason(in: state) ?? "")
        .accessibilityIdentifier(item.id)
        .help(helpTag(state.ringTitle, for: item))
    }

    /// Turn Off Screen follows the phone window's held panel: the subtitle is
    /// the phone's own state, and the tile is lit while it is off.
    private var screenTile: some View {
        let item = PhonePanelItem.screen
        let enabled = item.isEnabled(in: state)
        return Button {
            actions.turnOffScreen()
        } label: {
            tileLabel(symbol: state.panelOff ? "iphone.slash" : "iphone",
                      title: item.label,
                      subtitle: tileLine(item, state.screenTitle),
                      lit: item.isOn(in: state), enabled: enabled)
        }
        .buttonStyle(PanelControlStyle(enabled: enabled, active: item.isOn(in: state), hoverID: item.id))
        .disabled(!enabled)
        .accessibilityLabel("\(item.label), \(state.screenTitle)")
        .accessibilityHint(item.reason(in: state) ?? "")
        .accessibilityIdentifier(item.id)
        .help(helpTag("\(item.label) — \(state.screenTitle)", for: item))
    }

    private var ringerSymbol: String {
        switch state.ringer {
        case .vibrate: return "iphone.radiowaves.left.and.right"
        case .silent: return "bell.slash.fill"
        case .normal, nil: return "bell.fill"
        }
    }

    /// One tile's content: symbol, title and its second line. Lit, the type is
    /// white on the accent. Disabled, all three lines are neutral grey, so the
    /// tile reads as off and not operable (CONV-MAC-25); its fill and hover come
    /// from PanelControlStyle.
    private func tileLabel(symbol: String, title: String, subtitle: String,
                           lit: Bool, enabled: Bool) -> some View {
        // `.secondary` still reads near-primary on the panel material. A
        // disabled tile draws every line at a fixed low opacity (35 %), so its
        // title contrast is under half an enabled title's on both appearances
        // (reviewer round 2, fix 1c). The fill comes from PanelControlStyle.
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
            // A tile with no state to name (Ring Phone at rest) keeps its
            // second line's box: the card's height is the same online and
            // away (PANEL-19), so a blank line, never a shorter tile.
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

    // MARK: - Volume and windows

    /// The volume row. Where the slider would be, a disabled row says why, so
    /// the reason sits on the control it disables and not in a line of its own.
    private var volumeRow: some View {
        let enabled = PhonePanelItem.volume.isEnabled(in: state)
        return PanelRowShell(enabled: enabled,
                             icon: { Image(systemName: "speaker.fill").font(.system(size: 12)) }) {
            if let reason = PhonePanelItem.volume.reason(in: state) {
                Text(reason)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.9)
            } else {
                HStack(spacing: PhonePanelMetrics.iconTextSpace) {
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
                    .accessibilityLabel(PhonePanelItem.volume.label)
                    .accessibilityValue(volumeText)
                    .accessibilityIdentifier(PhonePanelItem.volume.id)
                    Text(volumeText)
                        .font(.system(size: 11))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 32, alignment: .trailing)
                    Image(systemName: "speaker.wave.3.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(width: PhonePanelMetrics.iconColumn)
                }
            }
        }
        .disabled(!enabled)
    }

    private var volumeText: String {
        guard state.volumeFraction != nil else { return "—" }
        return "\(Int((volume.display * 100).rounded()))%"
    }

    private var pickerRow: some View {
        Menu {
            ForEach(state.sessions) { row in
                Button {
                    actions.chooseSession(row.key)
                } label: {
                    Text(row.playing ? "\(row.app) — playing" : row.app)
                }
            }
        } label: {
            PanelRowShell(icon: { Image(systemName: "music.note").font(.system(size: 12)) }) {
                HStack(spacing: 6) {
                    Text(state.pickerTitle)
                        .font(.system(size: 13))
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .contentShape(.rect(cornerRadius: PhonePanelMetrics.rowCorner))
        }
        .menuStyle(.button)
        .buttonStyle(PanelControlStyle(kind: .row, corner: PhonePanelMetrics.rowCorner,
                                       bleed: PhonePanelMetrics.hoverBleed,
                                       hoverID: PhonePanelItem.sessions.id))
        .menuIndicator(.hidden)
        .accessibilityLabel(state.pickerTitle)
        .accessibilityIdentifier(PhonePanelItem.sessions.id)
    }

    /// P3's WINDOWS: one compact row of icon buttons, each with its shortcut in
    /// the tooltip. The visual label may be short ("Mirror"); VoiceOver hears
    /// the full name ("Phone Mirror").
    private var windowsRow: some View {
        HStack(spacing: PhonePanelMetrics.windowGap) {
            windowButton(.phoneScreen, visual: "Mirror", symbol: "iphone.gen3",
                         help: "Phone Mirror (⌘P)", action: actions.openPhoneScreen)
            windowButton(.findApps, visual: "Find Apps", symbol: "magnifyingglass",
                         help: "Find Apps (⌘K)", action: actions.findApps)
            windowButton(.continueOnMac, visual: "Move to Mac", symbol: "arrow.up.forward.app",
                         help: Self.moveToMacHelp, action: actions.continueOnMac)
            windowButton(.installApk, visual: "Install APK", symbol: "arrow.down.app",
                         help: state.installTitle, action: actions.installApk)
        }
        .padding(.top, PhonePanelMetrics.sectionGap)
    }

    private func windowButton(_ item: PhonePanelItem, visual: String, symbol: String,
                              help: String, action: @escaping () -> Void) -> some View {
        let enabled = item.isEnabled(in: state)
        return Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 15))
                Text(visual)
                    .font(.system(size: 9))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(enabled ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            .frame(maxWidth: .infinity, minHeight: PhonePanelMetrics.windowMinHeight)
            .contentShape(.rect(cornerRadius: PhonePanelMetrics.windowCorner))
        }
        .buttonStyle(PanelControlStyle(enabled: enabled, corner: PhonePanelMetrics.windowCorner,
                                       hoverID: item.id))
        .disabled(!enabled)
        .accessibilityLabel(item == .continueOnMac ? Self.moveToMacHelp : item.label)
        .accessibilityHint(item.reason(in: state) ?? "")
        .accessibilityIdentifier(item.id)
        .help(helpTag(help, for: item))
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.8)
            .foregroundStyle(.secondary)
            .frame(height: PhonePanelMetrics.sectionHeight, alignment: .leading)
            .padding(.top, PhonePanelMetrics.sectionGap)
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

/// One panel row's content on the shared grid: the 28 pt height and the 18 pt
/// icon column every row's symbol sits in, so icons and titles line up from row
/// to row. The row starts on the panel's inset, like the tiles. A row that can't
/// act is dimmed here once, the same way for a button, a switch and a slider.
struct PanelRowShell<Icon: View, Content: View>: View {
    var enabled = true
    @ViewBuilder var icon: Icon
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: PhonePanelMetrics.iconTextSpace) {
            icon
                .frame(width: PhonePanelMetrics.iconColumn)
                .foregroundStyle(.secondary)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: PhonePanelMetrics.rowHeight)
        .contentShape(.rect(cornerRadius: PhonePanelMetrics.rowCorner))
        .opacity(enabled ? 1 : 0.6)
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
    /// How far the highlight reaches past the content (a row's hover bleed).
    var bleed: CGFloat = 0
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
                .padding(.horizontal, -style.bleed)
            }
            .scaleEffect(isPressed && style.enabled && !reduceMotion ? 0.98 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isHovered)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.08), value: isPressed)
            .onHover { hovering = $0 }
    }
}

/// One 28 pt row: symbol, title, an optional shortcut hint. A person's click is
/// the button's action; the hover highlight is the Control Center cue.
struct PanelRow: View {
    let symbol: String
    let title: String
    var shortcut: String?
    var enabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            PanelRowShell(enabled: enabled,
                          icon: { Image(systemName: symbol).font(.system(size: 12)) }) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.system(size: 13))
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    if let shortcut {
                        Text(shortcut)
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .buttonStyle(PanelControlStyle(kind: .row, enabled: enabled,
                                       corner: PhonePanelMetrics.rowCorner,
                                       bleed: PhonePanelMetrics.hoverBleed))
        .disabled(!enabled)
        .accessibilityLabel(title)
    }
}
