// One phone's settings page (docs/specs/settings.md): a header with the phone's
// icon, name, state and Use This Phone, then plain sections — Phone (model,
// Rename…), Notifications (sharing, click target, Muted apps), Screen (the
// keep-off option) and Forget. It reads and writes only that phone's stores
// (`notify.<deviceId>`, the click target, the muted set, its panel preference),
// so the page is the same wherever it is hosted. The phone's name appears in
// the header and the window title, never in a section heading.

import AppKit
import SwiftUI

/// The page's section headings, in reading order. Plain on purpose: the page is
/// already that phone's (K2 asserts none carries the phone's name).
enum PhonePageSection: String, CaseIterable {
    case phone = "Phone"
    case notifications = "Notifications"
    case applications = "Applications"
    case screen = "Screen"
    case forget = "Forget"
}

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
        .onChange(of: controller.settingsReportRequest) { _, _ in
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

        header(phone, presence: presence)
        Section {
            LabeledContent("Model") {
                Text(phone.model.isEmpty ? "Unknown" : phone.model)
            }
            Button("Rename…") { onRename(phone) }
                .help("Give this phone a name only this Mac uses.")
        } header: {
            Text(PhonePageSection.phone.rawValue)
        }

        Section {
            notifications(phone)
        } header: {
            Text(PhonePageSection.notifications.rawValue)
        } footer: {
            Text("Notifications and Now Playing come from this phone only while it is paired and connected. Nothing is shared until you turn it on here.")
        }

        Section {
            Toggle(isOn: Binding(
                get: { controller.saveAllShortcuts(deviceId: phone.id) },
                set: { controller.setSaveAllShortcuts($0, for: phone.id) },
            )) {
                Text("Save all apps as shortcuts")
            }
            .disabled(!controller.canMakeShortcuts)
            .help("Give every app on this phone its own Mac app in Applications, so Launchpad, Spotlight and other launchers list it.")
            Text("Every app on this phone gets its own app in Applications, named for the phone. Turning it off removes only the shortcuts this switch made; ones you added yourself or in the Dock stay. A phone that is offline keeps its shortcuts.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } header: {
            Text(PhonePageSection.applications.rawValue)
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
            Text(PhonePageSection.screen.rawValue)
        }

        Section {
            Button("Forget This Phone…") { onForget(phone) }
                .foregroundStyle(.red)
        } header: {
            Text(PhonePageSection.forget.rawValue)
        } footer: {
            Text("Removes this Mac's pairing with \(displayName(phone)). You'll need to pair it again to use it here.")
        }
    }

    /// The page header: the phone's icon and name, its state in words (and when
    /// it was last seen), the In Use mark, and the one action the page needs
    /// (SET-WIN-06).
    private func header(_ phone: RememberedPhone, presence: DevicePresence) -> some View {
        let inUse = controller.activePhone?.id == phone.id
        return HStack(alignment: .center, spacing: 12) {
            DeviceGlyph(size: 44)
            VStack(alignment: .leading, spacing: 3) {
                Text(displayName(phone))
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                HStack(spacing: 5) {
                    DeviceStatusLabel(presence: presence)
                    if !presence.isLive {
                        Text("· \(phone.lastSeen.formatted(.relative(presentation: .named)))")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            Spacer(minLength: 8)
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
            } else if presence == .pairAgain {
                Button("Pair Again…", action: onAdd)
                    .help("Pair this phone again from the add sheet.")
            } else {
                Button("Use This Phone") { controller.use(phone) }
                    .help("Show this phone's apps, screen and notifications on this Mac.")
            }
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .contain)
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
        if let denied = DevicesTabModel.notificationsDeniedHint(
            denied: controller.notifyAuthorization == .denied) {
            Text(denied)
                .font(.caption)
                .foregroundStyle(.orange)
            HStack(spacing: 8) {
                Button("Open System Settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
                        NSWorkspace.shared.open(url)
                    }
                }
                Button("Check Again") { controller.checkNotificationAuthorization() }
            }
            .controlSize(.small)
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

    /// What this page renders, from the same values the rows above use (the e2e
    /// `settings` check reads it; the view stays the source). The sidebar writes
    /// the report for every page that is not a phone's.
    private func writeReport(_ phone: RememberedPhone) {
        guard let path = controller.settingsReportPath else { return }
        let rows = SettingsPhoneRows.rows(in: controller)
        let name = displayName(phone)
        var lines = SettingsReport.base(selection: .phone(phone.id), title: name, rows: rows)
        lines.append("page=phone")
        lines.append("inuse=\(rows.first { $0.inUse }?.name ?? "-")")
        let presence = DevicesPreview.presence(of: phone, in: controller)
        let inUse = controller.activePhone?.id == phone.id
        lines.append("header.name=\(name)")
        lines.append("header.state=\(presence.text)")
        lines.append("header.lastSeen=\(row(of: phone, presence: presence)?.lastSeenText ?? "")")
        lines.append("header.inUse=\(inUse ? 1 : 0)")
        lines.append("header.action=\(headerAction(presence: presence, inUse: inUse))")
        lines.append("header.model=\(phone.model)")
        lines.append("title.phone=\(PhonePageSection.phone.rawValue)")
        lines.append("title.notifications=\(PhonePageSection.notifications.rawValue)")
        lines.append("title.applications=\(PhonePageSection.applications.rawValue)")
        lines.append("title.screen=\(PhonePageSection.screen.rawValue)")
        lines.append("title.forget=\(PhonePageSection.forget.rawValue)")
        lines.append("share=\(shareOn ? 1 : 0)")
        lines.append("saveAllShortcuts=\(controller.saveAllShortcuts(deviceId: phone.id) ? 1 : 0)")
        let missingAccess = controller.notifyAccessMissing(deviceId: phone.id)
        lines.append("accessHint=\(DevicesTabModel.accessHint(noAccess: missingAccess) ?? "")")
        let denied = DevicesTabModel.notificationsDeniedHint(denied: controller.notifyAuthorization == .denied)
        lines.append("notificationsDenied=\(denied == nil ? 0 : 1)")
        lines.append("notificationsHint=\(denied ?? "")")
        lines.append("click=\(clickLabel(controller.notifyClickTarget(deviceId: phone.id)))")
        lines.append("mutedCount=\(DevicesTabModel.mutedCountText(muted.count))")
        lines.append("mutedOpen=\(mutedOpen ? 1 : 0)")
        lines.append("query=\(query)")
        lines.append("focused=\(searchFocused ? "search" : "none")")
        let forgetting = controller.rememberedPhones.first { $0.id == controller.forgettingDeviceId }
        lines.append("forgetDialog=\(forgetting.map(displayName) ?? "")")
        if let sheet = controller.sheet { lines.append("sheet=\(SettingsReport.sheetName(sheet))") }
        if mutedOpen {
            let seen = controller.seenPackages(deviceId: phone.id)
            for row in DevicesTabModel.mutedRows(apps: apps, seen: seen, muted: muted, query: query) {
                lines.append(["muted", row.title, row.packageBelow ?? "", row.seen ? "1" : "0",
                              row.muted ? "1" : "0"].joined(separator: "|"))
            }
        }
        try? (lines.joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8)
    }

    private func row(of phone: RememberedPhone, presence: DevicePresence) -> DevicePhoneRow? {
        DevicesTabModel.phoneRow(
            id: phone.id, name: displayName(phone), model: phone.model, presence: presence,
            lastSeen: phone.lastSeen.formatted(.relative(presentation: .named)),
            inUse: controller.activePhone?.id == phone.id)
    }

    /// The header's one action: nothing for the phone in use, Pair Again… for a
    /// phone whose key is gone, Use This Phone otherwise.
    private func headerAction(presence: DevicePresence, inUse: Bool) -> String {
        if inUse { return "-" }
        if presence == .pairAgain { return "Pair Again…" }
        return "Use This Phone"
    }
}
