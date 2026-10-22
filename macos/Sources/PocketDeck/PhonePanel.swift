// The phone controls the menu bar panel and the Deck popover share
// (docs/design/mac-redesign.md §3.8, docs/DESIGN.md "Deck"): one view, one
// item model, one copy. The panel is a fixed-width Control Center-style card:
// a header, the PHONE section (volume, Do Not Disturb, Ring/Stop Ringing, the
// Now Playing picker), LIVE, WINDOWS and a footer. It never reads the track
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
            case .needsPairing: return "Pair again"
            case .idle: return "No phone paired"
            }
        }

        var isOnline: Bool { self == .online }
    }

    var phoneName = "your phone"
    var connection: Connection = .idle
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
        "Now Playing follows: \(MediaMenu.chosenApp(sessions, chosen: media?.key) ?? "your phone")"
    }

    var ringTitle: String { ringing ? "Stop Ringing" : "Ring Phone" }
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
    var openSettings: () -> Void = {}
    var quit: () -> Void = {}
    var disconnectAgent: () -> Void = {}

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
        openSettings = { [weak controller] in controller?.openSettingsWindow() }
        quit = { NSApp.terminate(nil) }
        disconnectAgent = { [weak controller] in controller?.mcp.disconnectAgents() }
    }
}

extension PhoneControlsState {
    @MainActor
    init(controller: ConnectionController) {
        phoneName = controller.activePhone.map {
            controller.displayName(for: $0, fallback: "your phone")
        } ?? "your phone"
        switch controller.link {
        case .online: connection = .online
        case .connecting, .pairing: connection = .connecting
        case .reconnecting: connection = .reconnecting
        case .offline: connection = .offline
        case .needsPairing: connection = .needsPairing
        case .idle: connection = .idle
        }
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
         continueOnMac, installApk, disconnectAgent, settings, quit

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
        case .continueOnMac: return "Continue on Mac"
        case .installApk: return "Install APK…"
        case .disconnectAgent: return "Disconnect the AI agent"
        case .settings: return "Settings…"
        case .quit: return "Quit PocketDeck"
        }
    }

    /// One entry per focusable control the state renders, in the order P3 lays
    /// them out (top to bottom): the four tiles, the volume, the picker, the
    /// live rows, then the window buttons. The footer exists only in the menu
    /// bar panel (`showsFooter`), never in the Deck popover. The agent row's
    /// Disconnect button is first while an agent is connected.
    static func focusOrder(for state: PhoneControlsState, showsFooter: Bool = true) -> [PhonePanelItem] {
        var items: [PhonePanelItem] = []
        if state.agentCount > 0 { items.append(.disconnectAgent) }
        items += [.dnd, .ringer, .ring, .screen, .volume]
        if state.showsPicker { items.append(.sessions) }
        items += Array(repeating: .live, count: state.live.count)
        items += [.phoneScreen, .findApps, .continueOnMac, .installApk]
        if showsFooter { items += [.settings, .quit] }
        return items
    }
}

/// One grid for the panel: the fixed width, the 28 pt rows, the icon column
/// every row's symbol sits in and one section gap. The two hosts, the debug
/// probe and the geometry tests read these numbers instead of their own.
enum PhonePanelMetrics {
    static let width: CGFloat = 300
    static let inset: CGFloat = 12
    static let headerHeight: CGFloat = 44
    static let rowHeight: CGFloat = 28
    static let rowInset: CGFloat = 8
    static let iconColumn: CGFloat = 18
    static let iconTextSpace: CGFloat = 8
    static let sectionGap: CGFloat = 10
    static let sectionHeight: CGFloat = 16
    static let reasonHeight: CGFloat = 14
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
    static let textInset = inset + rowInset + iconColumn + iconTextSpace
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

    /// Why this control cannot work, in the person's words. Offline comes
    /// first, then the phone's missing capability. A control that cannot work
    /// is disabled with this line, never hidden (AGENTS "Honest settings").
    func reason(in state: PhoneControlsState) -> String? {
        let connect = "Connect your phone to use these."
        switch self {
        case .volume:
            guard state.connection.isOnline else { return connect }
            return state.volumeFraction == nil ? "Your phone hasn't sent a volume." : nil
        case .dnd:
            guard state.connection.isOnline else { return connect }
            return state.dnd == nil ? "This phone doesn't report Do Not Disturb." : nil
        case .ringer:
            guard state.connection.isOnline else { return connect }
            if state.ringer == nil { return "This phone doesn't report a ringer." }
            if state.dndOn && state.dnd != nil { return "Turn off Do Not Disturb to change the ringer." }
            return nil
        case .ring, .phoneScreen, .continueOnMac:
            return state.connection.isOnline ? nil : connect
        case .screen:
            return state.phoneWindow ? nil : "Open Phone Mirror first."
        case .installApk:
            guard state.connection.isOnline else { return connect }
            return state.installBusy ? "An install is already running." : nil
        case .sessions, .live, .findApps, .settings, .quit, .disconnectAgent:
            return nil
        }
    }
}

struct PhonePanelView: View {
    let state: PhoneControlsState
    let actions: PhoneControlsActions
    /// The menu bar panel keeps Settings…/Quit; the Deck's popover does not
    /// (the Deck has its own gear, and the app menu has both).
    let showsFooter: Bool

    static let width: CGFloat = PhonePanelMetrics.width
    private let inset: CGFloat = PhonePanelMetrics.inset
    @State private var volume: PhoneVolumeControl
    @State private var settleTimeout: Task<Void, Never>?

    init(state: PhoneControlsState, actions: PhoneControlsActions, showsFooter: Bool = true) {
        self.state = state
        self.actions = actions
        self.showsFooter = showsFooter
        _volume = State(initialValue: PhoneVolumeControl(display: state.volumeFraction ?? 0))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if state.agentCount > 0 { agentRow }
            tiles
            if let reason = tileReason {
                reasonLine(reason)
            }
            volumeRow.padding(.top, PhonePanelMetrics.sectionGap)
            if let reason = volumeReason, reason != tileReason {
                reasonLine(reason)
            }
            if state.showsPicker { pickerRow }
            if !state.live.isEmpty {
                sectionLabel("LIVE")
                ForEach(state.live) { item in
                    PanelRow(symbol: "bell.badge", title: NotifyLiveText.menuTitle(item, now: state.liveTick),
                             enabled: true) { actions.openLive(item.id) }
                        .accessibilityLabel(NotifyLiveText.menuTitle(item, now: state.liveTick))
                }
            }
            windowsRow
            if showsFooter { footer }
        }
        .padding(inset)
        .frame(width: Self.width)
        .onAppear { syncVolume() }
        .onChange(of: state.volumeFraction) { _, _ in syncVolume() }
        .onDisappear { settleTimeout?.cancel() }
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
        .frame(height: PhonePanelMetrics.headerHeight)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(state.phoneName), \(state.connection.text)")
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
        .padding(.horizontal, PhonePanelMetrics.rowInset)
    }

    // MARK: - P3's tiles

    /// The first tile that cannot work says why, once, in the one line under
    /// the grid. The volume has its own line so an old phone's missing volume
    /// is named next to the slider it disables.
    private var tileReason: String? {
        for item in [PhonePanelItem.dnd, .ringer, .ring, .screen] {
            if let reason = item.reason(in: state) { return reason }
        }
        return nil
    }

    private var volumeReason: String? { PhonePanelItem.volume.reason(in: state) }

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
        let enabled = PhonePanelItem.dnd.isEnabled(in: state)
        return Button {
            actions.setDnd(!state.dndOn)
        } label: {
            tileLabel(item: .dnd, symbol: state.dndOn ? "moon.fill" : "moon",
                      title: PhonePanelItem.dnd.label,
                      subtitle: state.dndOn ? "On" : "Off",
                      active: PhonePanelItem.dnd.isOn(in: state), enabled: enabled)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.55)
        .accessibilityLabel("\(PhonePanelItem.dnd.label), \(state.dndOn ? "On" : "Off")")
        .accessibilityIdentifier(PhonePanelItem.dnd.id)
        .help("\(PhonePanelItem.dnd.label) — \(state.dndOn ? "On" : "Off")")
    }

    /// The Ringer tile opens a menu; its own click never cycles the mode. The
    /// current mode is checked and named under the bell.
    private var ringerTile: some View {
        let enabled = PhonePanelItem.ringer.isEnabled(in: state)
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
            tileLabel(item: .ringer, symbol: ringerSymbol,
                      title: PhonePanelItem.ringer.label,
                      subtitle: state.ringerTitle,
                      active: PhonePanelItem.ringer.isOn(in: state),
                      enabled: enabled)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.55)
        .accessibilityLabel("\(PhonePanelItem.ringer.label), \(state.ringerTitle)")
        .accessibilityIdentifier(PhonePanelItem.ringer.id)
        .help("Ringer — \(state.ringerTitle)")
    }

    private var ringTile: some View {
        let enabled = PhonePanelItem.ring.isEnabled(in: state)
        return Button {
            state.ringing ? actions.stopRing() : actions.ring()
        } label: {
            tileLabel(item: .ring, symbol: state.ringing ? "bell.slash" : "iphone.radiowaves.left.and.right",
                      title: state.ringTitle,
                      subtitle: state.ringing ? "Ringing" : "30 seconds",
                      active: PhonePanelItem.ring.isOn(in: state), enabled: enabled)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.55)
        .accessibilityLabel(state.ringTitle)
        .accessibilityIdentifier(PhonePanelItem.ring.id)
        .help(state.ringTitle)
    }

    /// Turn Off Screen follows the phone window's held panel: the subtitle is
    /// the phone's own state, and the tile is checked while it is off.
    private var screenTile: some View {
        let enabled = PhonePanelItem.screen.isEnabled(in: state)
        return Button {
            actions.turnOffScreen()
        } label: {
            tileLabel(item: .screen, symbol: state.panelOff ? "iphone.slash" : "iphone",
                      title: PhonePanelItem.screen.label,
                      subtitle: state.screenTitle,
                      active: PhonePanelItem.screen.isOn(in: state), enabled: enabled)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.55)
        .accessibilityLabel("\(PhonePanelItem.screen.label), \(state.screenTitle)")
        .accessibilityIdentifier(PhonePanelItem.screen.id)
        .help("\(PhonePanelItem.screen.label) — \(state.screenTitle)")
    }

    private var ringerSymbol: String {
        switch state.ringer {
        case .vibrate: return "iphone.radiowaves.left.and.right"
        case .silent: return "bell.slash.fill"
        case .normal, nil: return "bell.fill"
        }
    }

    /// One 134 pt tile's content: symbol, title, and the one-word state the
    /// person needs. Accent and white type when the tile is on.
    private func tileLabel(item: PhonePanelItem, symbol: String, title: String,
                           subtitle: String, active: Bool, enabled: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(active ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            Spacer(minLength: 2)
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .foregroundStyle(active ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            Text(subtitle)
                .font(.system(size: 9))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .foregroundStyle(active ? AnyShapeStyle(.white.opacity(0.85)) : AnyShapeStyle(.secondary))
        }
        .padding(PhonePanelMetrics.tilePadding)
        .frame(maxWidth: .infinity, minHeight: PhonePanelMetrics.tileMinHeight, alignment: .leading)
        .background(active ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary),
                    in: .rect(cornerRadius: PhonePanelMetrics.tileCorner))
        .contentShape(.rect(cornerRadius: PhonePanelMetrics.tileCorner))
    }

    // MARK: - Volume and windows

    private var volumeRow: some View {
        let enabled = PhonePanelItem.volume.isEnabled(in: state)
        return PanelRowShell(enabled: enabled,
                             icon: { Image(systemName: "speaker.fill").font(.system(size: 12)) }) {
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
        .disabled(!enabled)
    }

    private var volumeText: String {
        guard state.volumeFraction != nil else { return "—" }
        return "\(Int((volume.display * 100).rounded()))%"
    }

    private func reasonLine(_ text: String) -> some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.9)
            .frame(height: PhonePanelMetrics.reasonHeight, alignment: .leading)
            .padding(.horizontal, PhonePanelMetrics.rowInset)
            .accessibilityLabel(text)
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
            .contentShape(.rect(cornerRadius: 6))
        }
        .menuStyle(.button)
        .buttonStyle(PanelRowButtonStyle())
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
            windowButton(.continueOnMac, visual: "Continue", symbol: "arrow.up.forward.app",
                         help: "Continue on Mac (⇧⌘C)", action: actions.continueOnMac)
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
            .frame(maxWidth: .infinity, minHeight: PhonePanelMetrics.windowMinHeight)
            .background(.quaternary, in: .rect(cornerRadius: PhonePanelMetrics.windowCorner))
            .contentShape(.rect(cornerRadius: PhonePanelMetrics.windowCorner))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
        .accessibilityLabel(item.label)
        .accessibilityIdentifier(item.id)
        .help(help)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button { actions.openSettings() } label: { shortcutItem("Settings…", "⌘,") }
                .keyboardShortcut(",", modifiers: .command)
                .accessibilityLabel(PhonePanelItem.settings.label)
                .accessibilityIdentifier(PhonePanelItem.settings.id)
            Text("·").foregroundStyle(.tertiary)
            Button { actions.quit() } label: { shortcutItem("Quit PocketDeck", "⌘Q") }
                .keyboardShortcut("q")
                .accessibilityLabel(PhonePanelItem.quit.label)
                .accessibilityIdentifier(PhonePanelItem.quit.id)
            Spacer(minLength: 0)
        }
        .buttonStyle(.plain)
        .font(.system(size: 12))
        .frame(height: PhonePanelMetrics.rowHeight)
        .padding(.horizontal, PhonePanelMetrics.rowInset)
        .padding(.top, PhonePanelMetrics.sectionGap)
    }

    /// A footer button with its shortcut shown beside it, the way the rows
    /// above show theirs.
    private func shortcutItem(_ title: String, _ shortcut: String) -> some View {
        HStack(spacing: 6) {
            Text(title)
            Text(shortcut).foregroundStyle(.tertiary)
        }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.8)
            .foregroundStyle(.secondary)
            .frame(height: PhonePanelMetrics.sectionHeight, alignment: .leading)
            .padding(.horizontal, PhonePanelMetrics.rowInset)
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

/// One panel row's content on the shared grid: the 28 pt height, the row inset
/// and the 18 pt icon column every row's symbol sits in, so icons and titles
/// line up from row to row. A row that can't act is dimmed here once, the same
/// way for a button, a switch and a slider.
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
        .padding(.horizontal, PhonePanelMetrics.rowInset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: PhonePanelMetrics.rowHeight)
        .contentShape(.rect(cornerRadius: 6))
        .opacity(enabled ? 1 : 0.6)
    }
}

/// A row's press look without the platform's own disabled fade: the shell
/// dims a disabled row, so the slider and the switch can match the buttons.
struct PanelRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.75 : 1)
    }
}

/// One 28 pt row: symbol, title, an optional shortcut hint. A person's click
/// is the button's action; the hover highlight is the Control Center cue.
struct PanelRow: View {
    let symbol: String
    let title: String
    var shortcut: String?
    var enabled = true
    let action: () -> Void
    @State private var hovering = false

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
            .background(hovering && enabled ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear),
                        in: .rect(cornerRadius: 6))
            .contentShape(.rect(cornerRadius: 6))
        }
        .buttonStyle(PanelRowButtonStyle())
        .disabled(!enabled)
        .onHover { hovering = $0 }
        .accessibilityLabel(title)
    }
}
