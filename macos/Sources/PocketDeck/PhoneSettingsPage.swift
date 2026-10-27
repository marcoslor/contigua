// One phone's settings page (docs/specs/settings-devices.md): its name and
// state, Use This Phone, Rename…, Forget This Phone…, the Notifications section
// (sharing, click target, Muted apps) and the keep-screen-off option. It reads
// and writes only that phone's stores (`notify.<deviceId>`, the click target,
// the muted set, its panel preference) and names its phone in every section
// header, so the same page can sit in a Settings sidebar unchanged and several
// phones never share a view state.

import AppKit
import SwiftUI

struct PhoneSettingsPage: View {
    let deviceId: String
    let onRename: (RememberedPhone) -> Void
    let onForget: (RememberedPhone) -> Void
    let onAdd: () -> Void

    @Environment(ConnectionController.self) private var controller
    @State private var shareOn = false
    @State private var mutedOpen = false
    @State private var query = ""
    @State private var apps: [AppInfo] = []
    @State private var muted: Set<String> = []
    @FocusState private var searchFocused: Bool
    /// Esc and ⌘F while the muted list is open: a local monitor scoped to this
    /// Settings window, so a stream window's ⌘F still belongs to the phone.
    @State private var keyMonitor: Any?

    private var phone: RememberedPhone? {
        controller.rememberedPhones.first { $0.id == deviceId }
    }

    private var profileDefaults: UserDefaults { Profile.active.defaults }
    /// One trailing column: the header and every checkbox share its width.
    private let mutedColumnWidth: CGFloat = 52

    var body: some View {
        Group {
            if let phone {
                content(phone)
            }
        }
        .task(id: deviceId) { syncFromStores() }
        .onChange(of: controller.rememberedPhones.map(\.id)) { _, _ in syncFromStores() }
        .onChange(of: controller.devicesReportRequest) { _, _ in
            if let phone { writeReport(phone) }
        }
        .onChange(of: mutedOpen) { _, _ in updateKeyMonitor() }
        .onDisappear {
            if let monitor = keyMonitor { NSEvent.removeMonitor(monitor) }
            keyMonitor = nil
        }
    }

    @ViewBuilder
    private func content(_ phone: RememberedPhone) -> some View {
        let presence = DevicesPreview.presence(of: phone, in: controller)

        Section {
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

        Section {
            notifications(phone)
        } header: {
            Text(title("Notifications", phone))
        } footer: {
            Text("Notifications and Now Playing come from this phone only while it is paired and connected. Nothing is shared until you turn it on here.")
        }

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

        Section {
            Button("Forget This Phone…") { onForget(phone) }
                .foregroundStyle(.red)
        } header: {
            Text(title("Forget", phone))
        } footer: {
            Text("Removes this Mac's pairing with \(displayName(phone)). You'll need to pair it again to use it here.")
        }
    }

    @ViewBuilder
    private func notifications(_ phone: RememberedPhone) -> some View {
        Toggle(isOn: $shareOn) {
            Text("Share notifications and Now Playing")
        }
        .onChange(of: shareOn) { _, on in
            controller.notifySettingChanged(deviceId: phone.id, on: on)
            muted = controller.mutedPackages(deviceId: phone.id)
        }
        if let hint = DevicesTabModel.accessHint(noAccess: controller.notifyAccessMissing(deviceId: phone.id)) {
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
            if mutedOpen { loadMutedApps() }
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
    }

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

    // MARK: keyboard

    /// While the list is open the tab owns ⌘F (focus and select the search) and
    /// Esc (close it). A local monitor is scoped to the key window and checked
    /// against this Settings window, so a stream window keeps its own ⌘F.
    private func updateKeyMonitor() {
        if mutedOpen, keyMonitor == nil {
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                MainActor.assumeIsolated { handleKey(event) }
            }
        } else if !mutedOpen, let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
    }

    private func handleKey(_ event: NSEvent) -> NSEvent? {
        guard mutedOpen, let window = NSApp.keyWindow,
              window === SettingsProbe.settingsWindow() else { return event }
        if event.modifierFlags.contains(.command),
           event.charactersIgnoringModifiers?.lowercased() == "f" {
            searchFocused = true
            Task { @MainActor in
                await Task.yield()
                NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
            }
            return nil
        }
        if event.keyCode == 53 {
            mutedOpen = false
            return nil
        }
        return event
    }

    // MARK: stores

    private func syncFromStores() {
        guard phone != nil else { return }
        shareOn = controller.notificationsEnabled(deviceId: deviceId)
        muted = controller.mutedPackages(deviceId: deviceId)
        mutedOpen = DevicesPreview.openMutedList
        if mutedOpen { loadMutedApps() }
    }

    private func loadMutedApps() {
        apps = controller.cachedApps(deviceId: deviceId)
        muted = controller.mutedPackages(deviceId: deviceId)
        query = ""
    }

    private func muteBinding(_ pkg: String, phone: RememberedPhone) -> Binding<Bool> {
        Binding(
            get: { muted.contains(pkg) },
            set: { on in
                if on { muted.insert(pkg) } else { muted.remove(pkg) }
                controller.notifyMuteChanged(deviceId: phone.id, pkg: pkg, muted: on)
            },
        )
    }

    // MARK: strings

    private func title(_ base: String, _ phone: RememberedPhone) -> String {
        DevicesTabModel.sectionTitle(base, phone: displayName(phone),
                                     phoneCount: controller.rememberedPhones.count)
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

    // MARK: the e2e's read

    /// What this page and the tab around it render, from the same values the
    /// rows above use (the e2e `settings-devices` check reads it; the view
    /// stays the source).
    private func writeReport(_ phone: RememberedPhone) {
        guard let path = controller.devicesReportPath else { return }
        let phones = controller.rememberedPhones
        var lines = ["phones=\(phones.count)"]
        if phones.isEmpty { lines.append("empty=No phones yet.") }
        lines.append("selected=\(displayName(phone))")
        let inUse = phones.first { $0.id == controller.activePhone?.id }
        lines.append("inuse=\(inUse.map(displayName) ?? "-")")
        for other in phones {
            let presence = DevicesPreview.presence(of: other, in: controller)
            let row = DevicesTabModel.phoneRow(
                id: other.id, name: displayName(other), model: other.model, presence: presence,
                lastSeen: other.lastSeen.formatted(.relative(presentation: .named)),
                inUse: controller.activePhone?.id == other.id)
            lines.append(["row", row.name, row.model, row.presenceText, row.lastSeenText ?? "",
                          row.inUse ? "1" : "0", row.pairAgain ? "1" : "0",
                          row.canUseThisPhone ? "1" : "0"].joined(separator: "|"))
        }
        lines.append("title.phone=\(title("Phone", phone))")
        lines.append("title.notifications=\(title("Notifications", phone))")
        lines.append("title.screen=\(title("Screen", phone))")
        lines.append("title.forget=\(title("Forget", phone))")
        lines.append("share=\(shareOn ? 1 : 0)")
        let missingAccess = controller.notifyAccessMissing(deviceId: phone.id)
        lines.append("accessHint=\(DevicesTabModel.accessHint(noAccess: missingAccess) ?? "")")
        lines.append("click=\(clickLabel(controller.notifyClickTarget(deviceId: phone.id)))")
        lines.append("mutedCount=\(DevicesTabModel.mutedCountText(muted.count))")
        lines.append("mutedOpen=\(mutedOpen ? 1 : 0)")
        lines.append("query=\(query)")
        lines.append("focused=\(searchFocused ? "search" : "none")")
        let forgetting = controller.rememberedPhones.first { $0.id == controller.forgettingDeviceId }
        lines.append("forgetDialog=\(forgetting.map(displayName) ?? "")")
        if mutedOpen {
            let seen = controller.seenPackages(deviceId: phone.id)
            for row in DevicesTabModel.mutedRows(apps: apps, seen: seen, muted: muted, query: query) {
                lines.append(["muted", row.title, row.packageBelow ?? "", row.seen ? "1" : "0",
                              row.muted ? "1" : "0"].joined(separator: "|"))
            }
        }
        try? (lines.joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8)
    }
}
