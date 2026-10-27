// Settings ▸ Devices, the shipped tab (docs/specs/settings-devices.md). One
// grouped Form: a Phones section (a row per phone and Add Phone…), then the
// settings of the phone whose ⓘ is open — the in-use phone by default. With two
// or more phones every section names its phone, so nothing is read as
// belonging to "the phone" (docs/specs/settings-devices.md, reviewer fix a).

import AppKit
import SwiftUI

/// What a `--preview devices-…` run stages for the screenshot phones: they have
/// no session and no pins, so their state and seen apps are supplied here.
enum DevicesPreview {
    nonisolated(unsafe) static var stagedPresence: [String: DevicePresence] = [:]
    /// The muted-apps list starts open (the `-muted` screenshots and e2e).
    nonisolated(unsafe) static var openMutedList = false

    /// The live link for the phone in use, a staged value for another.
    @MainActor
    static func presence(of phone: RememberedPhone, in controller: ConnectionController) -> DevicePresence {
        if controller.activePhone?.id == phone.id { return DevicePresence(controller.link) }
        if let staged = stagedPresence[phone.id] { return staged }
        guard controller.hasPinnedKey(deviceId: phone.id) else { return .pairAgain }
        return .offline(phone.lastSeen)
    }

    @MainActor
    static func reset() {
        stagedPresence = [:]
        openMutedList = false
    }
}

// MARK: - Shared pieces

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
                .fill(tint)
                .frame(width: 7, height: 7)
            Text(presence.text)
                .foregroundStyle(presence.isLive ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
        }
        .font(.subheadline)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(presence.text)
    }

    private var tint: Color {
        switch presence {
        case .connected: return .green
        case .connecting, .reconnecting, .pairAgain: return .orange
        case .offline: return .secondary
        }
    }
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

// MARK: - The tab

struct DevicesSettingsTab: View {
    let onRename: (RememberedPhone) -> Void
    let onForget: (RememberedPhone) -> Void
    let onAdd: () -> Void

    @Environment(ConnectionController.self) private var controller
    @State private var selected: String?
    @State private var mutedOpen = false
    @State private var shareOn = false
    @State private var query = ""
    @State private var apps: [AppInfo] = []
    @State private var muted: Set<String> = []
    @FocusState private var searchFocused: Bool

    private var phones: [RememberedPhone] { controller.rememberedPhones }
    private var inUse: RememberedPhone? { phones.first { $0.id == controller.activePhone?.id } }
    private var selectedPhone: RememberedPhone? {
        phones.first { $0.id == selected } ?? inUse ?? phones.first
    }

    var body: some View {
        Form {
            phoneList
            if let phone = selectedPhone {
                phoneSection(phone)
                notificationsSection(phone)
                screenSection(phone)
                forgetSection(phone)
            }
        }
        .formStyle(.grouped)
        .onAppear { selectDefault() }
        .onChange(of: phones.map(\.id)) { _, _ in selectDefault() }
        .onChange(of: selected) { _, _ in
            mutedOpen = DevicesPreview.openMutedList
            syncNotificationState()
            if mutedOpen, let phone = selectedPhone { loadMutedApps(phone) }
        }
        .onKeyPress(keys: ["f"], phases: .down) { press in
            guard press.modifiers.contains(.command), mutedOpen else { return .ignored }
            searchFocused = true
            Task { @MainActor in
                await Task.yield()
                NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
            }
            return .handled
        }
        .onExitCommand {
            if mutedOpen { mutedOpen = false }
        }
    }

    // MARK: phones

    private var phoneList: some View {
        Section {
            if phones.isEmpty {
                Text("No phones yet.")
                    .foregroundStyle(.secondary)
            }
            ForEach(phones) { phone in
                phoneRow(phone)
            }
            Button(action: onAdd) {
                Label(DevicesTabModel.labels.addPhone, systemImage: "plus")
            }
            .help("Pair a phone that is on the same Wi-Fi as this Mac.")
        } header: {
            Text("Phones")
        } footer: {
            if phones.isEmpty {
                Text("Pair a phone that is on the same Wi-Fi as this Mac.")
            }
        }
    }

    private func phoneRow(_ phone: RememberedPhone) -> some View {
        let presence = DevicesPreview.presence(of: phone, in: controller)
        let row = DevicesTabModel.phoneRow(
            id: phone.id, name: displayName(phone), model: phone.model, presence: presence,
            lastSeen: phone.lastSeen.formatted(.relative(presentation: .named)),
            inUse: controller.activePhone?.id == phone.id,
            pinnedKey: controller.hasPinnedKey(deviceId: phone.id))
        return HStack(spacing: 10) {
            DeviceGlyph()
            VStack(alignment: .leading, spacing: 1) {
                Text(row.name)
                HStack(spacing: 5) {
                    DeviceStatusLabel(presence: presence)
                    if let seen = row.lastSeenText {
                        Text("· \(seen)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Spacer(minLength: 6)
            if row.inUse {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                    Text("In Use")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(DevicesTabModel.labels.inUse)
            }
            Button {
                selected = (selected == phone.id) ? nil : phone.id
            } label: {
                Image(systemName: selected == phone.id ? "info.circle.fill" : "info.circle")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .help(DevicesTabModel.labels.details(row.name))
            .accessibilityLabel(DevicesTabModel.labels.details(row.name))
        }
    }

    // MARK: per-phone sections

    private func phoneSection(_ phone: RememberedPhone) -> some View {
        let presence = DevicesPreview.presence(of: phone, in: controller)
        return Section {
            LabeledContent("Model") {
                Text(phone.model.isEmpty ? "Unknown" : phone.model)
            }
            if controller.activePhone?.id != phone.id, presence != .pairAgain {
                Button("Use This Phone") { controller.use(phone) }
                    .help("Show this phone's apps, screen and notifications on this Mac.")
            }
            if presence == .pairAgain {
                Button("Pair Again…", action: onAdd)
                    .help("Pair this phone again from the add sheet.")
            }
            Button("Rename…") { onRename(phone) }
                .help("Give this phone a name only this Mac uses.")
        } header: {
            Text(title("Phone", phone))
        }
    }

    private func notificationsSection(_ phone: RememberedPhone) -> some View {
        Section {
            Toggle(isOn: $shareOn) {
                Text("Share notifications and Now Playing")
            }
            .onChange(of: shareOn) { _, on in
                guard selectedPhone?.id == phone.id else { return }
                controller.notifySettingChanged(deviceId: phone.id, on: on)
                muted = controller.mutedPackages(deviceId: phone.id)
            }
            if let hint = DevicesTabModel.accessHint(
                noAccess: controller.notifyAccessMissing(deviceId: phone.id)) {
                Text(hint)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            LabeledContent("When I click a notification") {
                Picker("", selection: Binding(
                    get: { controller.notifyClickTarget(deviceId: phone.id) },
                    set: { controller.notifyClickSettingChanged(deviceId: phone.id, target: $0) },
                )) {
                    ForEach(NotifyClickTarget.allCases) { target in
                        Text(clickLabel(target)).tag(target)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
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
                if mutedOpen { loadMutedApps(phone) }
            } label: {
                HStack(spacing: 6) {
                    Text("Muted apps")
                    Spacer()
                    Text(DevicesTabModel.mutedCountText(muted.count))
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
            if mutedOpen, shareOn {
                mutedList(phone)
            }
        } header: {
            Text(title("Notifications", phone))
        } footer: {
            Text("Notifications and Now Playing come from this phone only while it is paired and connected. Nothing is shared until you turn it on here.")
        }
        .task(id: phone.id) {
            mutedOpen = DevicesPreview.openMutedList
            syncNotificationState()
            if mutedOpen { loadMutedApps(phone) }
        }
    }

    private func screenSection(_ phone: RememberedPhone) -> some View {
        Section {
            Toggle(isOn: Binding(
                get: { PhonePanelIgnorePowerSetting.read(from: profileDefaults, deviceId: phone.id) },
                set: { PhonePanelIgnorePowerSetting.write($0, for: phone.id, to: profileDefaults) },
            )) {
                Text("Keep the phone screen off until I turn it on from the Mac")
            }
            Text("While the Mac holds the screen off, the phone's power button lights it for a moment; then it goes dark again. The phone stays locked either way.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } header: {
            Text(title("Screen", phone))
        }
    }

    private func forgetSection(_ phone: RememberedPhone) -> some View {
        Section {
            Button("Forget This Phone…") { onForget(phone) }
                .foregroundStyle(.red)
        } header: {
            Text(title("Forget", phone))
        } footer: {
            Text("Removes this Mac's pairing with \(displayName(phone)). You'll need to pair it again to use it here.")
        }
    }

    // MARK: muted apps

    private func mutedList(_ phone: RememberedPhone) -> some View {
        let seen = controller.seenPackages(deviceId: phone.id)
        let rows = DevicesTabModel.mutedRows(apps: apps, seen: seen, muted: muted, query: query)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 0) {
                Text("App")
                Spacer()
                Text(DevicesTabModel.labels.mutedColumn)
                    .frame(width: mutedColumnWidth, alignment: .trailing)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField(DevicesTabModel.labels.searchField, text: $query)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .accessibilityLabel(DevicesTabModel.labels.searchField)
            }
            ForEach(rows) { row in
                HStack(spacing: 8) {
                    AppRowIcon(image: icon(row.pkg, phone: phone))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(row.title)
                        if let pkg = row.packageBelow {
                            Text(pkg)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if row.seen {
                        Image(systemName: "bell.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .help(DevicesTabModel.labels.sent(row.title))
                            .accessibilityLabel(DevicesTabModel.labels.sent(row.title))
                    }
                    Spacer(minLength: 6)
                    Toggle(DevicesTabModel.labels.mutedColumn, isOn: muteBinding(row.pkg, phone: phone))
                        .labelsHidden()
                        .toggleStyle(.checkbox)
                        .controlSize(.small)
                        .frame(width: mutedColumnWidth, alignment: .trailing)
                        .accessibilityLabel(DevicesTabModel.labels.mute(row.title))
                }
            }
            if rows.isEmpty {
                Text(query.isEmpty
                     ? "No app has sent a notification yet. Muted apps you already chose stay here."
                     : "No apps match “\(query)”.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// One trailing column: the header and every checkbox share its width.
    private let mutedColumnWidth: CGFloat = 52

    private func muteBinding(_ pkg: String, phone: RememberedPhone) -> Binding<Bool> {
        Binding(
            get: { muted.contains(pkg) },
            set: { on in
                if on { muted.insert(pkg) } else { muted.remove(pkg) }
                controller.notifyMuteChanged(deviceId: phone.id, pkg: pkg, muted: on)
            },
        )
    }

    private func loadMutedApps(_ phone: RememberedPhone) {
        apps = controller.cachedApps(deviceId: phone.id)
        muted = controller.mutedPackages(deviceId: phone.id)
        query = ""
    }

    private func syncNotificationState() {
        guard let phone = selectedPhone else { return }
        shareOn = controller.notificationsEnabled(deviceId: phone.id)
        muted = controller.mutedPackages(deviceId: phone.id)
    }

    private func selectDefault() {
        let ids = Set(phones.map(\.id))
        if let selected, ids.contains(selected) { return }
        selected = inUse?.id ?? phones.first?.id
    }

    // MARK: helpers

    private var profileDefaults: UserDefaults { Profile.active.defaults }

    private func title(_ base: String, _ phone: RememberedPhone) -> String {
        DevicesTabModel.sectionTitle(base, phone: displayName(phone), phoneCount: phones.count)
    }

    private func displayName(_ phone: RememberedPhone) -> String {
        controller.displayName(for: phone.ref)
    }

    private func clickLabel(_ target: NotifyClickTarget) -> String {
        switch target {
        case .mac: return "Open on this Mac"
        case .phone: return "Open on the phone"
        case .none: return "Do nothing"
        }
    }

    private func icon(_ pkg: String, phone: RememberedPhone) -> NSImage? {
        controller.icons[pkg] ?? IconCache.shared.load(pkg: pkg, deviceId: phone.id)
    }
}
