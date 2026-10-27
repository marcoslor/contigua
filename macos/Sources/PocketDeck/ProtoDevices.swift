// Settings ▸ Devices prototypes (branch proto/devices; nothing here is a
// product decision). `--debug-proto devices=D1|D2|D3` is a test hook, so a
// release build ignores it and the tab keeps today's grouped Form.
//
// The three options draw the same controls from the same small pieces
// (`DeviceNotificationRows`, `DeviceScreenRows`, `MutedAppsList`) so the
// comparison is about layout, not about what a control says.

import AppKit
import SwiftUI

enum ProtoDevicesVariant: String, Sendable {
    case production
    case d1 = "D1", d2 = "D2", d3 = "D3"
}

enum ProtoDevices {
    nonisolated(unsafe) static var variant: ProtoDevicesVariant = .production
    /// The prototype window's width: D1's sidebar needs more room than today's
    /// 480 pt. Production keeps `SettingsLayout.width`.
    nonisolated(unsafe) static var windowWidth: CGFloat?
    /// The muted-apps list starts open (the `-muted` screenshots).
    nonisolated(unsafe) static var openMutedList = false
    /// The `devices-three` screenshot of D3 scrolls to the last card: the open
    /// card is taller than the window, and the other two cards are the point.
    nonisolated(unsafe) static var scrollCardsToEnd = false
    /// Presence staged for the screenshot phones (`--preview devices-…`), which
    /// have no session and no pins.
    nonisolated(unsafe) static var stagedPresence: [String: DevicePresence] = [:]
    /// The muted list's scroll target for the `-muted` screenshot.
    static let mutedListID = "muted-apps"

    /// `devices=D2`; an unknown value keeps the production look.
    static func select(_ value: String) {
        for part in value.split(separator: " ") {
            let pair = part.split(separator: "=", maxSplits: 1).map(String.init)
            guard pair.count == 2, pair[0].lowercased() == "devices" else { continue }
            variant = ProtoDevicesVariant(rawValue: pair[1].uppercased()) ?? .production
        }
        windowWidth = variant == .production ? nil : 640
    }

    /// What the row says about this phone: the live link for the phone in use,
    /// a remembered phone's own last state for the others.
    @MainActor
    static func presence(of phone: RememberedPhone, in controller: ConnectionController) -> DevicePresence {
        if controller.activePhone?.id == phone.id { return DevicePresence(controller.link) }
        if let staged = stagedPresence[phone.id] { return staged }
        guard controller.hasPinnedKey(deviceId: phone.id) else { return .pairAgain }
        return .offline(phone.lastSeen)
    }

    /// The phone the details belong to: the one in use, else the first.
    @MainActor
    static func inUse(_ phones: [RememberedPhone], in controller: ConnectionController) -> RememberedPhone? {
        phones.first { $0.id == controller.activePhone?.id } ?? phones.first
    }
}

/// What a phone's row says, from `Link` for the phone in use and from what this
/// Mac remembers for the others. Never colour alone: every case has its words.
enum DevicePresence: Equatable {
    case connected
    case connecting
    case reconnecting
    case offline(Date?)
    case pairAgain

    init(_ link: Link) {
        switch link {
        case .online: self = .connected
        case .connecting: self = .connecting
        case .reconnecting: self = .reconnecting
        case .needsPairing: self = .pairAgain
        case .offline: self = .offline(nil)
        case .idle, .pairing: self = .offline(nil)
        }
    }

    var text: String {
        switch self {
        case .connected: return "Connected"
        case .connecting: return "Connecting…"
        case .reconnecting: return "Reconnecting…"
        case .offline: return "Offline"
        case .pairAgain: return "Pair again"
        }
    }

    var tint: Color {
        switch self {
        case .connected: return .green
        case .connecting, .reconnecting: return .orange
        case .pairAgain: return .orange
        case .offline: return .secondary
        }
    }

    var isLive: Bool { self == .connected }
}

// MARK: - Pieces shared by the three options

/// A phone's rounded app-icon-sized tile with the phone symbol.
struct DeviceGlyph: View {
    var size: CGFloat = 26

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(.quaternary)
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: "iphone.gen3")
                    .font(.system(size: size * 0.6))
                    .foregroundStyle(.secondary)
            }
            .accessibilityHidden(true)
    }
}

/// A dot and the state's own words (CONV-MAC-23).
struct DeviceStatusLabel: View {
    let presence: DevicePresence

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(presence.tint)
                .frame(width: 7, height: 7)
            Text(presence.text)
                .foregroundStyle(presence.isLive ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
        }
        .font(.subheadline)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(presence.text)
    }
}

/// "In Use": the accent mark that says which phone the rest of the Mac shows.
struct InUseBadge: View {
    var body: some View {
        Label("In Use", systemImage: "checkmark.circle.fill")
            .font(.caption.weight(.medium))
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Color.accentColor.opacity(0.12), in: Capsule())
            .accessibilityLabel("In use")
    }
}

/// The one name for this phone (its nickname, else its own), as everywhere else
/// (CONV-PD-07).
@MainActor
func deviceName(_ phone: RememberedPhone, in controller: ConnectionController) -> String {
    controller.displayName(for: phone.ref)
}

/// An app's icon in the muted list: the real one when we have it, a neutral
/// tile when we do not (the package name then sits under the row's title).
struct AppRowIcon: View {
    let image: NSImage?

    var body: some View {
        if let image {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .frame(width: 18, height: 18)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                .accessibilityHidden(true)
        } else {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(.quaternary)
                .frame(width: 18, height: 18)
                .overlay {
                    Image(systemName: "app")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
                .accessibilityHidden(true)
        }
    }
}

// MARK: - Notifications (one phone)

/// The Notifications section's rows. D3 keeps them inside a phone's card, so
/// only the rows live here and the section wrapper is below.
struct DeviceNotificationRows: View {
    let phone: RememberedPhone
    @Binding var mutedOpen: Bool

    @Environment(ConnectionController.self) private var controller
    @State private var shareOn = false
    @State private var clickTarget = NotifyClickTarget.mac
    @State private var mutedCount = 0

    var body: some View {
        content
            .onAppear {
                shareOn = controller.notificationsEnabled(deviceId: phone.id)
                clickTarget = controller.notifyClickTarget(deviceId: phone.id)
                mutedCount = mutedCount(of: phone.id)
                mutedOpen = mutedOpen || ProtoDevices.openMutedList
            }
            .onChange(of: mutedOpen) { _, open in
                if open { mutedCount = mutedCount(of: phone.id) }
            }
    }

    @ViewBuilder
    private var content: some View {
        Toggle(isOn: $shareOn) { Text("Share notifications and Now Playing") }
            .onChange(of: shareOn) { _, on in
                controller.notifySettingChanged(deviceId: phone.id, on: on)
                mutedCount = mutedCount(of: phone.id)
            }
        LabeledContent("When I click a notification") {
            Picker("", selection: $clickTarget) {
                ForEach(NotifyClickTarget.allCases) { target in
                    Text(clickLabel(target)).tag(target)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .onChange(of: clickTarget) { _, target in
                controller.notifyClickSettingChanged(deviceId: phone.id, target: target)
            }
        }
        .disabled(!shareOn)
        .help("What a click on this phone's notification does.")
        if !shareOn {
            Text("Turn on sharing to choose what a click does and to mute apps.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        Button {
            mutedOpen.toggle()
            if mutedOpen { mutedCount = mutedCount(of: phone.id) }
        } label: {
            HStack(spacing: 6) {
                Text("Muted apps")
                Spacer()
                Text(mutedCount == 0 ? "None" : "\(mutedCount)")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Image(systemName: mutedOpen ? "chevron.down" : "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!shareOn)
        .help("Apps whose notifications are not shown on this Mac.")
        .id(ProtoDevices.mutedListID)
        if mutedOpen, shareOn {
            MutedAppsList(deviceId: phone.id)
        }
    }

    private func mutedCount(of deviceId: String) -> Int {
        controller.mutedPackages(deviceId: deviceId).count
    }

    private func clickLabel(_ target: NotifyClickTarget) -> String {
        switch target {
        case .mac: return "Open on this Mac"
        case .phone: return "Open on the phone"
        case .none: return "Do nothing"
        }
    }
}

/// The section wrapper D1 and D2 use; its footer says the condition that
/// gates everything above it.
struct DeviceNotificationsSection: View {
    let phone: RememberedPhone
    @Binding var mutedOpen: Bool

    var body: some View {
        Section {
            DeviceNotificationRows(phone: phone, mutedOpen: $mutedOpen)
        } header: {
            Text("Notifications")
        } footer: {
            Text("Notifications and Now Playing come from this phone only while it is paired and connected. Nothing is shared until you turn it on here.")
        }
    }
}

/// The `-muted` screenshot: the list is below the fold at 560 pt, so the run
/// scrolls it to the top (a person scrolls the same form by hand).
@MainActor
func scrollToMuted(_ proxy: ScrollViewProxy, open: Bool) async {
    guard open, ProtoDevices.openMutedList else { return }
    try? await Task.sleep(for: .milliseconds(700))
    withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(ProtoDevices.mutedListID, anchor: .top) }
}

/// The muted list: the apps that have sent notifications this session plus the
/// ones already muted, by name and icon, searchable, one switch column.
struct MutedAppsList: View {
    let deviceId: String

    @Environment(ConnectionController.self) private var controller
    @State private var query = ""
    @State private var muted: Set<String> = []
    @State private var packages: [String] = []

    private var rows: [String] {
        let matching = packages.filter {
            query.isEmpty || name($0).localizedCaseInsensitiveContains(query)
                || $0.localizedCaseInsensitiveContains(query)
        }
        return matching.sorted { name($0).localizedStandardCompare(name($1)) == .orderedAscending }
    }

    var body: some View {
        content
            .onAppear {
                packages = controller.notifyMutedAppChoices(deviceId: deviceId)
                muted = controller.mutedPackages(deviceId: deviceId)
            }
    }

    @ViewBuilder
    private var content: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search apps", text: $query)
                .textFieldStyle(.plain)
                .accessibilityLabel("Search apps")
        }
        ForEach(rows, id: \.self) { pkg in
            Toggle(isOn: binding(pkg)) {
                HStack(spacing: 8) {
                    AppRowIcon(image: icon(pkg))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(name(pkg))
                    }
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .accessibilityLabel("Mute \(name(pkg))")
        }
        if rows.isEmpty {
            Text(query.isEmpty
                 ? "No app has sent a notification yet. Muted apps you already chose stay here."
                 : "No apps match “\(query)”.")
                .foregroundStyle(.secondary)
        }
    }

    private func name(_ pkg: String) -> String {
        controller.appLabel(for: pkg) ?? pkg
    }

    private func icon(_ pkg: String) -> NSImage? {
        controller.icons[pkg] ?? IconCache.shared.load(pkg: pkg, deviceId: deviceId)
    }

    private func binding(_ pkg: String) -> Binding<Bool> {
        Binding(
            get: { muted.contains(pkg) },
            set: { on in
                if on { muted.insert(pkg) } else { muted.remove(pkg) }
                controller.notifyMuteChanged(deviceId: deviceId, pkg: pkg, muted: on)
            },
        )
    }
}

// MARK: - Screen (one phone)

struct DeviceScreenRows: View {
    let phone: RememberedPhone

    @State private var keepOff = false

    var body: some View {
        Group {
            Toggle(isOn: $keepOff) {
                Text("Keep the phone screen off until I turn it on from the Mac")
            }
            .onChange(of: keepOff) { _, on in
                PhonePanelIgnorePowerSetting.write(on, for: phone.id, to: Profile.active.defaults)
            }
            Text("While the Mac holds the screen off, the phone's power button lights it for a moment; then it goes dark again. The phone stays locked either way.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .onAppear {
            keepOff = PhonePanelIgnorePowerSetting.read(from: Profile.active.defaults, deviceId: phone.id)
        }
    }
}

struct DeviceScreenSection: View {
    let phone: RememberedPhone

    var body: some View {
        Section {
            DeviceScreenRows(phone: phone)
        } header: {
            Text("Screen")
        }
    }
}

// MARK: - Phone rows and actions

/// The phone's "Phone" section: who it is, what state it is in, and the two
/// actions that do not destroy anything.
struct DevicePhoneSection: View {
    let phone: RememberedPhone
    let presence: DevicePresence
    let isInUse: Bool
    let onUse: () -> Void
    let onRename: () -> Void
    let onPairAgain: () -> Void

    @Environment(ConnectionController.self) private var controller

    var body: some View {
        Section {
            HStack(spacing: 10) {
                DeviceGlyph(size: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(deviceName(phone, in: controller))
                        .font(.headline)
                    HStack(spacing: 5) {
                        DeviceStatusLabel(presence: presence)
                        if !presence.isLive {
                            Text("· \(phone.lastSeen.formatted(.relative(presentation: .named)))")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            LabeledContent("Model") {
                Text(phone.model.isEmpty ? "Unknown" : phone.model)
            }
            if !isInUse {
                Button("Use This Phone", action: onUse)
                    .help("Show this phone's apps, screen and notifications on this Mac.")
            }
            if presence == .pairAgain {
                Button("Pair Again…", action: onPairAgain)
                    .help("Pair this phone again from the add sheet.")
            }
            Button("Rename…", action: onRename)
                .help("Give this phone a name only this Mac uses.")
        } header: {
            Text("Phone")
        }
    }
}

/// The destructive action, alone, at the bottom (never beside "Connected").
struct DeviceForgetSection: View {
    let phone: RememberedPhone
    let onForget: () -> Void

    @Environment(ConnectionController.self) private var controller

    var body: some View {
        Section {
            Button("Forget This Phone…") { onForget() }
                .foregroundStyle(.red)
        } footer: {
            Text("Removes this Mac's pairing with \(deviceName(phone, in: controller)). You'll need to pair it again to use it here.")
        }
    }
}

/// "Add Phone…" opens the Deck's own add sheet, so there is one pairing flow.
struct DeviceAddPhoneRow: View {
    let onAdd: () -> Void

    var body: some View {
        Button(action: onAdd) {
            Label("Add Phone…", systemImage: "plus")
        }
    }
}

// MARK: - D1: sidebar of phones, details on the right

struct DevicesSidebarOption: View {
    let phones: [RememberedPhone]
    @Binding var selection: String?
    let onAdd: () -> Void
    let onRename: (RememberedPhone) -> Void
    let onForget: (RememberedPhone) -> Void

    @Environment(ConnectionController.self) private var controller
    @State private var mutedOpen = false

    private var selected: RememberedPhone? { phones.first { $0.id == selection } }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                List(selection: $selection) {
                    ForEach(phones) { phone in
                        row(phone).tag(phone.id)
                    }
                }
                .listStyle(.sidebar)
                .overlay {
                    if phones.isEmpty {
                        Text("No phones")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                Divider()
                HStack(spacing: 2) {
                    Button(action: onAdd) {
                        Image(systemName: "plus")
                    }
                    .help("Add a phone…")
                    .accessibilityLabel("Add a phone")
                    Button {
                        if let selected { onForget(selected) }
                    } label: {
                        Image(systemName: "minus")
                    }
                    .disabled(selected == nil)
                    .help("Forget the selected phone…")
                    .accessibilityLabel("Forget the selected phone")
                    Spacer()
                }
                .buttonStyle(.borderless)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
            }
            .frame(width: 208)
            Divider()
            Group {
                if let phone = selected {
                    detail(phone)
                } else {
                    emptyDetail
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            if selection == nil { selection = ProtoDevices.inUse(phones, in: controller)?.id }
        }
        .onChange(of: phones.map(\.id)) { _, ids in
            if let current = selection, !ids.contains(current) { selection = ids.first }
        }
    }

    private func row(_ phone: RememberedPhone) -> some View {
        let presence = ProtoDevices.presence(of: phone, in: controller)
        return HStack(spacing: 8) {
            DeviceGlyph(size: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(deviceName(phone, in: controller))
                DeviceStatusLabel(presence: presence)
                    .font(.caption)
            }
            Spacer(minLength: 4)
            if controller.activePhone?.id == phone.id {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Color.accentColor)
                    .accessibilityLabel("In use")
                    .padding(.trailing, 2)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func detail(_ phone: RememberedPhone) -> some View {
        let presence = ProtoDevices.presence(of: phone, in: controller)
        let inUse = controller.activePhone?.id == phone.id
        ScrollViewReader { proxy in
            Form {
                DevicePhoneSection(phone: phone, presence: presence, isInUse: inUse,
                                   onUse: { controller.use(phone) },
                                   onRename: { onRename(phone) },
                                   onPairAgain: onAdd)
                DeviceNotificationsSection(phone: phone, mutedOpen: $mutedOpen)
                DeviceScreenSection(phone: phone)
                DeviceForgetSection(phone: phone, onForget: { onForget(phone) })
            }
            .formStyle(.grouped)
            .task(id: mutedOpen) { await scrollToMuted(proxy, open: mutedOpen) }
        }
    }

    private var emptyDetail: some View {
        ContentUnavailableView {
            Label("No Phones", systemImage: "iphone.gen3")
        } description: {
            Text("Add a phone to use its apps and its screen on this Mac.")
        } actions: {
            Button("Add Phone…", action: onAdd)
                .buttonStyle(.borderedProminent)
        }
    }
}

// MARK: - D2: one grouped Form

struct DevicesFormOption: View {
    let phones: [RememberedPhone]
    let onAdd: () -> Void
    let onRename: (RememberedPhone) -> Void
    let onForget: (RememberedPhone) -> Void

    @Environment(ConnectionController.self) private var controller
    @State private var expanded: String?
    @State private var mutedOpen = false

    var body: some View {
        ScrollViewReader { proxy in
        Form {
            Section {
                ForEach(phones) { phone in
                    row(phone)
                    if expanded == phone.id {
                        details(phone)
                    }
                }
                if phones.isEmpty {
                    Text("No phones yet.")
                        .foregroundStyle(.secondary)
                }
                DeviceAddPhoneRow(onAdd: onAdd)
            } header: {
                Text("Phones")
            } footer: {
                if phones.isEmpty {
                    Text("Pair a phone that is on the same Wi-Fi as this Mac.")
                }
            }
            if let phone = ProtoDevices.inUse(phones, in: controller) {
                DeviceNotificationsSection(phone: phone, mutedOpen: $mutedOpen)
                DeviceScreenSection(phone: phone)
                DeviceForgetSection(phone: phone, onForget: { onForget(phone) })
            }
        }
        .formStyle(.grouped)
        .task(id: mutedOpen) { await scrollToMuted(proxy, open: mutedOpen) }
        }
    }

    private func row(_ phone: RememberedPhone) -> some View {
        let presence = ProtoDevices.presence(of: phone, in: controller)
        let inUse = controller.activePhone?.id == phone.id
        return HStack(spacing: 10) {
            DeviceGlyph()
            VStack(alignment: .leading, spacing: 1) {
                Text(deviceName(phone, in: controller))
                HStack(spacing: 5) {
                    DeviceStatusLabel(presence: presence)
                    if !presence.isLive {
                        Text("· \(phone.lastSeen.formatted(.relative(presentation: .named)))")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Spacer(minLength: 6)
            if inUse {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                    Text("In Use")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("In use")
            }
            Button {
                expanded = expanded == phone.id ? nil : phone.id
            } label: {
                Image(systemName: expanded == phone.id ? "info.circle.fill" : "info.circle")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .help("Details for this phone")
            .accessibilityLabel("Details for \(deviceName(phone, in: controller))")
        }
    }

    @ViewBuilder
    private func details(_ phone: RememberedPhone) -> some View {
        let presence = ProtoDevices.presence(of: phone, in: controller)
        let inUse = controller.activePhone?.id == phone.id
        LabeledContent("Model") { Text(phone.model) }
        LabeledContent("Status") { DeviceStatusLabel(presence: presence) }
        if !inUse {
            Button("Use This Phone") { controller.use(phone) }
                .help("Show this phone's apps, screen and notifications on this Mac.")
        }
        Button("Rename…") { onRename(phone) }
        if presence == .pairAgain {
            Button("Pair Again…", action: onAdd)
                .help("Pair this phone again from the add sheet.")
        }
        Button("Forget This Phone…") { onForget(phone) }
            .foregroundStyle(.red)
    }
}

// MARK: - D3: one card per phone

struct DevicesCardsOption: View {
    let phones: [RememberedPhone]
    let onAdd: () -> Void
    let onRename: (RememberedPhone) -> Void
    let onForget: (RememberedPhone) -> Void

    @Environment(ConnectionController.self) private var controller
    @State private var expanded: Set<String> = []
    @State private var mutedOpenFor: String?

    var body: some View {
        ScrollViewReader { proxy in
        Form {
            ForEach(phones) { phone in
                Section {
                    header(phone)
                    if isOpen(phone) {
                        body(phone)
                    }
                }
            }
            if phones.isEmpty {
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("No Phones")
                            .font(.headline)
                        Text("Add a phone to use its apps and its screen on this Mac.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                    DeviceAddPhoneRow(onAdd: onAdd)
                }
            } else {
                Section {
                    DeviceAddPhoneRow(onAdd: onAdd)
                }
            }
        }
        .formStyle(.grouped)
        .task(id: mutedOpenFor) { await scrollToMuted(proxy, open: mutedOpenFor != nil) }
        .task {
            guard ProtoDevices.scrollCardsToEnd, let last = phones.last else { return }
            try? await Task.sleep(for: .milliseconds(700))
            withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(last.id, anchor: .bottom) }
        }
        }
    }

    private func isOpen(_ phone: RememberedPhone) -> Bool {
        controller.activePhone?.id == phone.id || expanded.contains(phone.id)
    }

    private func header(_ phone: RememberedPhone) -> some View {
        let presence = ProtoDevices.presence(of: phone, in: controller)
        let inUse = controller.activePhone?.id == phone.id
        return HStack(spacing: 10) {
            DeviceGlyph(size: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(deviceName(phone, in: controller))
                    .font(.headline)
                HStack(spacing: 5) {
                    DeviceStatusLabel(presence: presence)
                    if !presence.isLive {
                        Text("· \(phone.lastSeen.formatted(.relative(presentation: .named)))")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Spacer(minLength: 6)
            if inUse {
                InUseBadge()
            } else {
                if presence == .pairAgain {
                    Button("Pair Again…", action: onAdd)
                        .help("Pair this phone again from the add sheet.")
                } else {
                    Button("Use This Phone") { controller.use(phone) }
                        .help("Show this phone's apps, screen and notifications on this Mac.")
                }
                Button {
                    if expanded.contains(phone.id) {
                        expanded.remove(phone.id)
                    } else {
                        _ = expanded.insert(phone.id)
                    }
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(expanded.contains(phone.id) ? 0 : -90))
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .help(expanded.contains(phone.id) ? "Hide this phone's settings" : "Show this phone's settings")
                .accessibilityLabel("Settings for \(deviceName(phone, in: controller))")
            }
        }
        .id(phone.id)
    }

    @ViewBuilder
    private func body(_ phone: RememberedPhone) -> some View {
        let presence = ProtoDevices.presence(of: phone, in: controller)
        if presence == .pairAgain {
            Button("Pair Again…", action: onAdd)
                .help("Pair this phone again from the add sheet.")
        }
        Button("Rename…") { onRename(phone) }
        groupTitle("Notifications")
        DeviceNotificationRows(phone: phone, mutedOpen: mutedBinding(phone))
        Text("Only while this phone is paired and connected.")
            .font(.caption)
            .foregroundStyle(.secondary)
        groupTitle("Screen")
        DeviceScreenRows(phone: phone)
        Button("Forget This Phone…") { onForget(phone) }
            .foregroundStyle(.red)
        Text("Removes this Mac's pairing with \(deviceName(phone, in: controller)). You'll need to pair it again.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private func groupTitle(_ text: String) -> some View {
        Text(text)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.top, 2)
    }

    private func mutedBinding(_ phone: RememberedPhone) -> Binding<Bool> {
        Binding(
            get: { mutedOpenFor == phone.id },
            set: { open in mutedOpenFor = open ? phone.id : nil },
        )
    }
}

// MARK: - The tab's prototype shell

/// What the Devices tab draws when the prototype flag names an option.
struct ProtoDevicesSettings: View {
    let onRename: (RememberedPhone) -> Void
    let onForget: (RememberedPhone) -> Void
    let onAdd: () -> Void

    @Environment(ConnectionController.self) private var controller
    @State private var selection: String?

    var body: some View {
        switch ProtoDevices.variant {
        case .d1:
            DevicesSidebarOption(phones: controller.rememberedPhones, selection: $selection,
                                 onAdd: onAdd, onRename: onRename, onForget: onForget)
        case .d2:
            DevicesFormOption(phones: controller.rememberedPhones, onAdd: onAdd,
                              onRename: onRename, onForget: onForget)
        case .d3:
            DevicesCardsOption(phones: controller.rememberedPhones, onAdd: onAdd,
                               onRename: onRename, onForget: onForget)
        case .production:
            EmptyView()
        }
    }
}

/// The quiet prototype run draws its controls as an active app's: the window
/// is never key in a background run, so an "on" switch and the list selection
/// would render in the inactive grey and a screenshot would misreport the
/// state. Test builds only, and only while a prototype flag is set.
enum ProtoDevicesRender {
    static func installActiveStandIn() {
        guard let original = class_getInstanceMethod(NSApplication.self, #selector(getter: NSApplication.isActive)),
              let standIn = class_getInstanceMethod(NSApplication.self, #selector(getter: NSApplication.pd_protoIsActive)) else { return }
        method_exchangeImplementations(original, standIn)
    }
}

extension NSApplication {
    @objc fileprivate var pd_protoIsActive: Bool { true }
}

/// The prototype run opens the Settings window by itself (screenshots): the
/// gear, ⌘, and the panel's Settings… row stay the real entry points.
@MainActor
enum ProtoDevicesScreens {
    static func start(controller: ConnectionController) {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1200))
            controller.openSettingsWindow()
        }
    }
}
