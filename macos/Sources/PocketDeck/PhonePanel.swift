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
    case volume, dnd, ring, sessions, live, phoneScreen, findApps, continueOnMac, installApk, settings, quit

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
        case .settings: return "Settings…"
        case .quit: return "Quit PocketDeck"
        }
    }

    /// One entry per focusable control the state renders (a live row is one).
    static func focusOrder(for state: PhoneControlsState) -> [PhonePanelItem] {
        var items: [PhonePanelItem] = [.volume, .dnd, .ring]
        if state.showsPicker { items.append(.sessions) }
        items += [.phoneScreen, .findApps, .continueOnMac, .installApk]
        items += Array(repeating: .live, count: state.live.count)
        items += [.settings, .quit]
        return items
    }
}

struct PhonePanelView: View {
    let state: PhoneControlsState
    let actions: PhoneControlsActions

    static let width: CGFloat = 300
    private let inset: CGFloat = 12

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            agentRow
            sectionLabel("PHONE").padding(.top, 10)
            volumeRow
            reasonLine
            dndRow
            ringRow
            if state.showsPicker { pickerRow }
            if !state.live.isEmpty {
                sectionLabel("LIVE").padding(.top, 10)
                ForEach(state.live) { item in
                    PanelRow(symbol: "bell.badge", title: NotifyLiveText.menuTitle(item, now: state.liveTick),
                             enabled: true) { actions.openLive(item.id) }
                        .accessibilityLabel(NotifyLiveText.menuTitle(item, now: state.liveTick))
                }
            }
            sectionLabel("WINDOWS").padding(.top, 10)
            PanelRow(symbol: "iphone.gen3", title: "Phone Screen", shortcut: "⌘P",
                     enabled: state.connection.isOnline) { actions.openPhoneScreen() }
                .accessibilityIdentifier(PhonePanelItem.phoneScreen.id)
            PanelRow(symbol: "magnifyingglass", title: "Find Apps", shortcut: "⌘K",
                     enabled: true) { actions.findApps() }
                .accessibilityIdentifier(PhonePanelItem.findApps.id)
            PanelRow(symbol: "arrow.up.forward.app", title: "Continue on Mac",
                     enabled: state.connection.isOnline) { actions.continueOnMac() }
                .accessibilityIdentifier(PhonePanelItem.continueOnMac.id)
            PanelRow(symbol: "arrow.down.app", title: state.installTitle,
                     enabled: state.connection.isOnline && !state.installBusy) { actions.installApk() }
                .accessibilityIdentifier(PhonePanelItem.installApk.id)
            footer.padding(.top, 10)
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
            if let battery = state.battery {
                let low = BatterySymbol.isLow(level: battery, charging: state.charging)
                HStack(spacing: 3) {
                    Image(systemName: BatterySymbol.name(level: battery, charging: state.charging))
                    Text("\(battery)%").monospacedDigit()
                }
                .font(.caption)
                .foregroundStyle(low ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
            }
        }
        .frame(height: 44)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(state.phoneName), \(state.connection.text)")
    }

    private var agentRow: some View {
        HStack(spacing: 8) {
            if state.agentCount > 0 {
                Image(systemName: "sparkles").font(.system(size: 12))
                Text("AI agent connected").font(.system(size: 12))
                Spacer(minLength: 6)
                Button("Disconnect") { actions.disconnectAgent() }
                    .buttonStyle(.glass)
                    .controlSize(.mini)
                    .accessibilityLabel("Disconnect the AI agent")
            }
        }
        .frame(height: 24)
        .padding(.horizontal, 8)
    }

    private var volumeRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "speaker.fill")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Slider(value: Binding(
                get: { state.volumeFraction ?? 0 },
                set: { actions.setVolume($0) },
            ), in: 0...1)
            .controlSize(.small)
            .disabled(state.volumeFraction == nil)
            .accessibilityLabel(PhonePanelItem.volume.label)
            .accessibilityIdentifier(PhonePanelItem.volume.id)
            Image(systemName: "speaker.wave.3.fill")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
    }

    private var reasonLine: some View {
        Text(state.reason ?? " ")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .frame(height: 14, alignment: .leading)
            .padding(.horizontal, 8)
            .opacity(state.reason == nil ? 0 : 1)
            .accessibilityHidden(state.reason == nil)
    }

    private var dndRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "moon.fill")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 18)
            Text(PhonePanelItem.dnd.label).font(.system(size: 13))
            Spacer(minLength: 6)
            Toggle("", isOn: Binding(
                get: { state.dnd?.isOn ?? false },
                set: { actions.setDnd($0) },
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)
            .disabled(!state.connection.isOnline || state.dnd == nil)
            .accessibilityLabel(PhonePanelItem.dnd.label)
            .accessibilityIdentifier(PhonePanelItem.dnd.id)
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
    }

    private var ringRow: some View {
        PanelRow(symbol: state.ringing ? "iphone.radiowaves.left.and.right.slash"
                                       : "iphone.radiowaves.left.and.right",
                 title: state.ringTitle,
                 enabled: state.connection.isOnline,
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
            HStack(spacing: 8) {
                Image(systemName: "music.note.list")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                Text(state.pickerTitle)
                    .font(.system(size: 13))
                    .lineLimit(1)
                Spacer(minLength: 6)
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .contentShape(.rect(cornerRadius: 6))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .accessibilityLabel(state.pickerTitle)
        .accessibilityIdentifier(PhonePanelItem.sessions.id)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button("Settings…") { actions.openSettings() }
                .keyboardShortcut(",", modifiers: .command)
                .accessibilityIdentifier(PhonePanelItem.settings.id)
            Text("·").foregroundStyle(.tertiary)
            Button("Quit PocketDeck") { actions.quit() }
                .keyboardShortcut("q")
                .accessibilityIdentifier(PhonePanelItem.quit.id)
            Spacer(minLength: 0)
        }
        .buttonStyle(.plain)
        .font(.system(size: 12))
        .frame(height: 28)
        .padding(.horizontal, 8)
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.8)
            .foregroundStyle(.secondary)
            .frame(height: 16, alignment: .leading)
            .padding(.horizontal, 8)
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
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
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
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(hovering && enabled ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear),
                        in: .rect(cornerRadius: 6))
            .contentShape(.rect(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { hovering = $0 }
        .accessibilityLabel(title)
    }
}
