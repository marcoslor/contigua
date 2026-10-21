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
    var ringing = false
    var live: [NotifyLiveItem] = []
    var liveTick = Date()
    var installBusy = false
    var installTitle = "Install APK…"

    /// The one line that explains a disabled phone control (honest settings):
    /// offline first, then a phone that sent no volume, then no DND support.
    var reason: String? {
        guard connection.isOnline else { return "Connect your phone to use these." }
        if volumeFraction == nil { return "Your phone hasn't sent a volume." }
        if dnd == nil { return "This phone doesn't report Do Not Disturb." }
        return nil
    }

    var volumeFraction: Double? {
        guard connection.isOnline else { return nil }
        return media?.volumeFraction
    }

    var showsPicker: Bool { MediaMenu.showsSessionPicker(sessions) }

    var pickerTitle: String {
        "Now Playing follows: \(MediaMenu.chosenApp(sessions, chosen: media?.key) ?? "your phone")"
    }

    var ringTitle: String { ringing ? "Stop Ringing" : "Ring Phone" }
}

/// The panel's actions. The hosts only supply how to reach the Deck window;
/// everything else is the controller's own route.
struct PhoneControlsActions {
    var setVolume: (Double) -> Void = { _ in }
    var setDnd: (Bool) -> Void = { _ in }
    var ring: () -> Void = {}
    var stopRing: () -> Void = {}
    var chooseSession: (String) -> Void = { _ in }
    var openLive: (String) -> Void = { _ in }
    var openPhoneScreen: () -> Void = {}
    var findApps: () -> Void = {}
    var continueOnMac: () -> Void = {}
    var installApk: () -> Void = {}
    var openSettings: () -> Void = {}
    var quit: () -> Void = {}
    var disconnectAgent: () -> Void = {}

    init() {}

    @MainActor
    init(controller: ConnectionController, openDeck: @escaping () -> Void) {
        setVolume = { [weak controller] fraction in controller?.setPhoneMediaVolume(fraction) }
        setDnd = { [weak controller] on in controller?.setPhoneDnd(on: on) }
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
    case volume, dnd, ring, sessions, live, phoneScreen, findApps, continueOnMac, installApk,
         disconnectAgent, settings, quit

    var id: String { "panel.\(rawValue)" }

    var label: String {
        switch self {
        case .volume: return "Phone volume"
        case .dnd: return "Do Not Disturb"
        case .ring: return "Ring Phone"
        case .sessions: return "Now Playing follows"
        case .live: return "Live notification"
        case .phoneScreen: return "Phone Screen"
        case .findApps: return "Find Apps"
        case .continueOnMac: return "Continue on Mac"
        case .installApk: return "Install APK…"
        case .disconnectAgent: return "Disconnect the AI agent"
        case .settings: return "Settings…"
        case .quit: return "Quit PocketDeck"
        }
    }

    /// One entry per focusable control the state renders, in the order the view
    /// lays them out (top to bottom): a live row is one, and the agent row's
    /// Disconnect button exists only while an agent is connected.
    static func focusOrder(for state: PhoneControlsState) -> [PhonePanelItem] {
        var items: [PhonePanelItem] = []
        if state.agentCount > 0 { items.append(.disconnectAgent) }
        items += [.volume, .dnd, .ring]
        if state.showsPicker { items.append(.sessions) }
        items += Array(repeating: .live, count: state.live.count)
        items += [.phoneScreen, .findApps, .continueOnMac, .installApk, .settings, .quit]
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

    /// The text inset every row's title shares, from the panel's left edge.
    static let textInset = inset + rowInset + iconColumn + iconTextSpace
    /// One row's width inside the panel's inset.
    static let rowWidth = width - inset * 2
}

/// Whether a row's own control can do anything in this state: one mapping for
/// the view, the debug probe and the tests, so a disabled row looks and
/// behaves the same wherever it is read.
extension PhonePanelItem {
    func isEnabled(in state: PhoneControlsState) -> Bool {
        switch self {
        case .volume: return state.volumeFraction != nil
        case .dnd: return state.connection.isOnline && state.dnd != nil
        case .ring, .phoneScreen, .continueOnMac: return state.connection.isOnline
        case .installApk: return state.connection.isOnline && !state.installBusy
        case .sessions: return true
        case .live: return true
        case .findApps, .settings, .quit, .disconnectAgent: return true
        }
    }
}

struct PhonePanelView: View {
    let state: PhoneControlsState
    let actions: PhoneControlsActions

    static let width: CGFloat = PhonePanelMetrics.width
    private let inset: CGFloat = PhonePanelMetrics.inset

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if state.agentCount > 0 { agentRow }
            sectionLabel("PHONE")
            volumeRow
            if state.reason != nil { reasonLine }
            dndRow
            ringRow
            if state.showsPicker { pickerRow }
            if !state.live.isEmpty {
                sectionLabel("LIVE")
                ForEach(state.live) { item in
                    PanelRow(symbol: "bell.badge", title: NotifyLiveText.menuTitle(item, now: state.liveTick),
                             enabled: true) { actions.openLive(item.id) }
                        .accessibilityLabel(NotifyLiveText.menuTitle(item, now: state.liveTick))
                }
            }
            sectionLabel("WINDOWS")
            PanelRow(symbol: "iphone.gen3", title: "Phone Screen", shortcut: "⌘P",
                     enabled: PhonePanelItem.phoneScreen.isEnabled(in: state)) { actions.openPhoneScreen() }
                .accessibilityIdentifier(PhonePanelItem.phoneScreen.id)
            PanelRow(symbol: "magnifyingglass", title: "Find Apps", shortcut: "⌘K",
                     enabled: true) { actions.findApps() }
                .accessibilityIdentifier(PhonePanelItem.findApps.id)
            PanelRow(symbol: "arrow.up.forward.app", title: "Continue on Mac",
                     enabled: PhonePanelItem.continueOnMac.isEnabled(in: state)) { actions.continueOnMac() }
                .accessibilityIdentifier(PhonePanelItem.continueOnMac.id)
            PanelRow(symbol: "arrow.down.app", title: state.installTitle,
                     enabled: PhonePanelItem.installApk.isEnabled(in: state)) { actions.installApk() }
                .accessibilityIdentifier(PhonePanelItem.installApk.id)
            footer
        }
        .padding(inset)
        .frame(width: Self.width)
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

    private var volumeRow: some View {
        let enabled = PhonePanelItem.volume.isEnabled(in: state)
        return PanelRowShell(enabled: enabled,
                             icon: { Image(systemName: "speaker.fill").font(.system(size: 12)) }) {
            HStack(spacing: PhonePanelMetrics.iconTextSpace) {
                Slider(value: Binding(
                    get: { state.volumeFraction ?? 0 },
                    set: { actions.setVolume($0) },
                ), in: 0...1)
                .controlSize(.small)
                .accessibilityLabel(PhonePanelItem.volume.label)
                .accessibilityIdentifier(PhonePanelItem.volume.id)
                Image(systemName: "speaker.wave.3.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: PhonePanelMetrics.iconColumn)
            }
        }
        .disabled(!enabled)
    }

    private var reasonLine: some View {
        Text(state.reason ?? " ")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .frame(height: PhonePanelMetrics.reasonHeight, alignment: .leading)
            .padding(.horizontal, PhonePanelMetrics.rowInset)
            .accessibilityHidden(state.reason == nil)
    }

    private var dndRow: some View {
        let enabled = PhonePanelItem.dnd.isEnabled(in: state)
        return PanelRowShell(enabled: enabled,
                             icon: { Image(systemName: "moon.fill").font(.system(size: 12)) }) {
            HStack(spacing: 6) {
                Text(PhonePanelItem.dnd.label).font(.system(size: 13))
                Spacer(minLength: 6)
                Toggle("", isOn: Binding(
                    get: { state.dnd?.isOn ?? false },
                    set: { actions.setDnd($0) },
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .accessibilityLabel(PhonePanelItem.dnd.label)
                .accessibilityIdentifier(PhonePanelItem.dnd.id)
            }
        }
        .disabled(!enabled)
    }

    private var ringRow: some View {
        PanelRow(symbol: state.ringing ? "bell.slash"
                                       : "iphone.radiowaves.left.and.right",
                 title: state.ringTitle,
                 enabled: PhonePanelItem.ring.isEnabled(in: state),
                 action: state.ringing ? actions.stopRing : actions.ring)
            .accessibilityIdentifier(PhonePanelItem.ring.id)
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
