// Settings as a System Settings–style sidebar (branch proto/settings-sidebar;
// nothing here is a product decision). `--debug-proto settings=S1|S2|S3` is a
// test hook, so a release build ignores the flag and Settings keeps today's
// four tabs.
//
// S1 puts the phones first and the Mac's own sections below, S2 the reverse,
// and S3 keeps one Phones entry that opens today's Devices tab. The right side
// draws the shipped tab views unchanged: PhoneSettingsPage is self-contained,
// so a phone's page in the sidebar is the same page the Devices tab shows.

import AppKit
import SwiftUI

enum ProtoSettingsVariant: String, Sendable {
    case production
    case s1 = "S1", s2 = "S2", s3 = "S3"
}

enum ProtoSettings {
    nonisolated(unsafe) static var variant: ProtoSettingsVariant = .production
    /// The prototype window's width: a sidebar needs more room than today's
    /// 480 pt tab. Production keeps `SettingsLayout.width`.
    nonisolated(unsafe) static var windowWidth: CGFloat?
    static let sidebarWidth: CGFloat = 200

    /// `settings=S2`; an unknown value keeps the production tabs.
    static func select(_ value: String) {
        for part in value.split(separator: " ") {
            let pair = part.split(separator: "=", maxSplits: 1).map(String.init)
            guard pair.count == 2, pair[0].lowercased() == "settings" else { continue }
            variant = ProtoSettingsVariant(rawValue: pair[1].uppercased()) ?? .production
        }
        windowWidth = variant == .production ? nil : 700
    }
}

/// What the sidebar can show. A phone's selection carries its device id, so a
/// phone's page is never "the phone" (docs/specs/settings-devices.md).
enum SettingsSidebarSelection: Hashable, Sendable {
    case general, input, automation
    /// S3's single entry: today's Devices tab (the list plus the page).
    case devices
    case phone(String)

    var storeValue: String {
        switch self {
        case .general: return "general"
        case .input: return "input"
        case .automation: return "automation"
        case .devices: return "phones"
        case .phone(let id): return "phone:\(id)"
        }
    }

    init?(storeValue: String) {
        switch storeValue {
        case "general": self = .general
        case "input": self = .input
        case "automation": self = .automation
        case "phones": self = .devices
        default:
            guard storeValue.hasPrefix("phone:") else { return nil }
            let id = String(storeValue.dropFirst("phone:".count))
            guard !id.isEmpty else { return nil }
            self = .phone(id)
        }
    }
}

/// The selection is a per-profile preference: ⌘, reopens the last section, and
/// another profile starts with its own (never the person's) value.
enum SettingsSidebarStore {
    static let key = "settings.sidebar.selection"

    static func read(from defaults: UserDefaults) -> SettingsSidebarSelection? {
        defaults.string(forKey: key).flatMap(SettingsSidebarSelection.init(storeValue:))
    }

    static func write(_ selection: SettingsSidebarSelection?, to defaults: UserDefaults) {
        if let selection { defaults.set(selection.storeValue, forKey: key) } else { defaults.removeObject(forKey: key) }
    }
}

/// One selectable sidebar row.
struct SettingsSidebarItem: Equatable, Identifiable {
    let selection: SettingsSidebarSelection
    let title: String
    let systemImage: String
    /// The phone's state words and, when it is not connected, when it was last
    /// seen (never colour alone).
    let subtitle: String?
    let presence: DevicePresence?
    let inUse: Bool
    let help: String
    let accessibilityLabel: String

    var id: String { selection.storeValue }
}

struct SettingsSidebarGroup: Equatable, Identifiable {
    let id: String
    let title: String?
    let items: [SettingsSidebarItem]
    /// S1/S2 put Add Phone… at the end of the Phones group; S3's Devices tab
    /// already carries its own.
    let showsAddPhone: Bool
}

/// The sidebar's pure half: the order of the groups, what a row says, and which
/// row a route or the stored preference opens.
enum SettingsSidebarModel {

    static let addPhoneTitle = "Add Phone…"

    static func groups(variant: ProtoSettingsVariant, phones: [DevicePhoneRow]) -> [SettingsSidebarGroup] {
        let mac = macItems()
        let phoneItems = phones.map(item(for:))
        let phonesGroup = SettingsSidebarGroup(id: "phones", title: "Phones", items: phoneItems,
                                               showsAddPhone: true)
        let macGroup = SettingsSidebarGroup(id: "mac", title: "This Mac", items: mac, showsAddPhone: false)
        switch variant {
        case .production:
            return []
        case .s1:
            return [phonesGroup, macGroup]
        case .s2:
            return [macGroup, phonesGroup]
        case .s3:
            // The Mac's three sections around one Phones entry, which opens
            // today's Devices tab in the same detail column.
            let phonesEntry = SettingsSidebarItem(
                selection: .devices, title: "Phones", systemImage: "iphone.gen3",
                subtitle: phoneCountText(phones.count), presence: nil, inUse: false,
                help: "Every phone this Mac knows, and one phone's settings.",
                accessibilityLabel: "Phones, \(phoneCountText(phones.count))")
            return [SettingsSidebarGroup(id: "all", title: nil,
                                         items: [mac[0], mac[1], phonesEntry, mac[2]],
                                         showsAddPhone: false)]
        }
    }

    static func phoneCountText(_ count: Int) -> String {
        count == 0 ? "None" : (count == 1 ? "1 phone" : "\(count) phones")
    }

    static func item(for row: DevicePhoneRow) -> SettingsSidebarItem {
        SettingsSidebarItem(
            selection: .phone(row.id), title: row.name, systemImage: "iphone.gen3",
            subtitle: subtitle(for: row), presence: .init(text: row.presenceText),
            inUse: row.inUse,
            help: help(for: row),
            accessibilityLabel: accessibilityLabel(for: row))
    }

    static func addPhoneItem() -> SettingsSidebarItem {
        SettingsSidebarItem(
            selection: .general, title: addPhoneTitle, systemImage: "plus",
            subtitle: nil, presence: nil, inUse: false,
            help: "Pair a phone that is on the same Wi-Fi as this Mac.",
            accessibilityLabel: "Add Phone…")
    }

    /// The row's second line: the state's own words, plus when it was last seen
    /// while it is not connected.
    static func subtitle(for row: DevicePhoneRow) -> String? {
        guard let seen = row.lastSeenText else { return row.presenceText }
        return "\(row.presenceText) · \(seen)"
    }

    static func help(for row: DevicePhoneRow) -> String {
        row.inUse ? "This phone's settings; the Deck and the panel show it."
                  : "This phone's settings on this Mac."
    }

    static func accessibilityLabel(for row: DevicePhoneRow) -> String {
        var parts = [row.name, row.presenceText]
        if let seen = row.lastSeenText { parts.append("last seen \(seen)") }
        if row.inUse { parts.append("In use") }
        return parts.joined(separator: ", ")
    }

    /// The row a section opens: the debug verbs (`settings-tab`) and a staged
    /// preview go through this, so they drive the same selection a click does.
    static func selection(for tab: SettingsTab, variant: ProtoSettingsVariant,
                          phones: [DevicePhoneRow], inUseId: String?) -> SettingsSidebarSelection? {
        switch tab {
        case .general: return .general
        case .input: return .input
        case .automation: return .automation
        case .devices:
            if variant == .s3 { return .devices }
            return phoneSelection(phones: phones, inUseId: inUseId)
        }
    }

    /// What the window opens: the stored selection when it still exists, else
    /// the phone in use (S1/S2), else nothing but the empty state (0 phones).
    /// S3 starts on General, today's tab.
    static func resolve(stored: SettingsSidebarSelection?, variant: ProtoSettingsVariant,
                        phones: [DevicePhoneRow], inUseId: String?) -> SettingsSidebarSelection? {
        let ids = Set(phones.map(\.id))
        var candidate = stored
        if case .phone(let id)? = candidate, !ids.contains(id) { candidate = nil }
        // A value stored for one option must not select a row another option
        // does not draw.
        if variant != .s3, candidate == .devices { candidate = .general }
        if let candidate { return candidate }
        switch variant {
        case .production: return nil
        case .s1, .s2: return phoneSelection(phones: phones, inUseId: inUseId)
        case .s3: return .general
        }
    }

    private static func phoneSelection(phones: [DevicePhoneRow], inUseId: String?) -> SettingsSidebarSelection? {
        if let inUseId, phones.contains(where: { $0.id == inUseId }) { return .phone(inUseId) }
        return phones.first.map { .phone($0.id) }
    }

    private static func macItems() -> [SettingsSidebarItem] {
        [
            SettingsSidebarItem(selection: .general, title: "General", systemImage: "gearshape",
                                subtitle: nil, presence: nil, inUse: false,
                                help: "How PocketDeck behaves on this Mac.",
                                accessibilityLabel: "General"),
            SettingsSidebarItem(selection: .input, title: "Input", systemImage: "computermouse",
                                subtitle: nil, presence: nil, inUse: false,
                                help: "How the Mac's pointer and keyboard reach the phone.",
                                accessibilityLabel: "Input"),
            SettingsSidebarItem(selection: .automation, title: "Automation", systemImage: "terminal",
                                subtitle: nil, presence: nil, inUse: false,
                                help: "The local server AI agents use.",
                                accessibilityLabel: "Automation"),
        ]
    }
}

private extension DevicePresence {
    /// The row's words are the source; a phone row's dot fills their colour.
    init(text: String) {
        switch text {
        case "Connected": self = .connected
        case "Connecting…": self = .connecting
        case "Reconnecting…": self = .reconnecting
        case "Pair again": self = .pairAgain
        default: self = .offline(nil)
        }
    }
}

// MARK: - The window's sidebar

struct ProtoSettingsShell: View {
    @Environment(ConnectionController.self) private var controller
    @State private var selection: SettingsSidebarSelection?
    @State private var renameText = ""

    private var variant: ProtoSettingsVariant { ProtoSettings.variant }
    private var defaults: UserDefaults { controller.profile.defaults }

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .navigationSplitViewStyle(.balanced)
        .onAppear(perform: selectInitial)
        .onChange(of: controller.settingsTab) { _, tab in
            selection = SettingsSidebarModel.selection(for: tab, variant: variant,
                                                       phones: rows, inUseId: inUseId)
        }
        .onChange(of: controller.rememberedPhones.map(\.id)) { _, _ in
            selection = SettingsSidebarModel.resolve(stored: selection, variant: variant,
                                                     phones: rows, inUseId: inUseId)
        }
        .onChange(of: selection) { _, value in
            SettingsSidebarStore.write(value, to: defaults)
        }
        .task(id: controller.renamingDeviceId) {
            guard let id = controller.renamingDeviceId else { return }
            renameText = controller.previewRenameText ?? controller.nickname(for: id)
        }
        .alert("Rename", isPresented: renaming) {
            TextField("Nickname", text: $renameText, prompt: alertPrompt)
            Button("Rename") { saveRename() }
            Button("Cancel", role: .cancel) { controller.endRename() }
        } message: {
            Text("Up to 40 characters. Leave it empty to keep using the phone's own name.")
        }
        // S3's Devices tab presents these dialogs itself; the sidebar's copy
        // stays inert there so two sheets never race.
        .sheet(isPresented: Binding(
            get: { variant != .s3 && controller.forgettingDeviceId != nil },
            set: { if !$0 { controller.endForget() } })) {
            if let phone = forgettingPhone {
                ForgetConfirmation(
                    name: controller.displayName(for: phone.ref),
                    onCancel: { controller.endForget() },
                    onConfirm: {
                        controller.forget(phone)
                        controller.endForget()
                    })
            }
        }
    }

    private var sidebar: some View {
        List(selection: $selection) {
            ForEach(SettingsSidebarModel.groups(variant: variant, phones: rows)) { group in
                Section {
                    ForEach(group.items) { item in
                        row(item).tag(item.selection)
                    }
                    if group.showsAddPhone {
                        addPhoneRow
                    }
                } header: {
                    if let title = group.title { Text(title) }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 180, ideal: ProtoSettings.sidebarWidth, max: 260)
    }

    @ViewBuilder
    private func row(_ item: SettingsSidebarItem) -> some View {
        HStack(spacing: 8) {
            if let presence = item.presence {
                DeviceGlyph(size: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.title)
                    HStack(spacing: 4) {
                        DeviceStatusLabel(presence: presence)
                            .font(.caption)
                        if let subtitle = item.subtitle {
                            Text(subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .lineLimit(1)
                }
                Spacer(minLength: 4)
                if item.inUse {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.accentColor)
                        .accessibilityHidden(true)
                }
            } else {
                Label(item.title, systemImage: item.systemImage)
                if let subtitle = item.subtitle {
                    Spacer(minLength: 4)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.accessibilityLabel)
        .help(item.help)
    }

    private var addPhoneRow: some View {
        let item = SettingsSidebarModel.addPhoneItem()
        return Button(action: addPhone) {
            Label(item.title, systemImage: item.systemImage)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(item.accessibilityLabel)
        .accessibilityAddTraits(.isButton)
        .help(item.help)
    }

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .general: GeneralSettings()
        case .input: InputSettings()
        case .automation: AutomationSettings()
        // Today's Devices tab, unchanged, in the sidebar's detail column.
        case .devices: DevicesSettings()
        case .phone(let id):
            if controller.rememberedPhones.contains(where: { $0.id == id }) {
                phonePage(id)
            } else {
                unavailable(NothingSelectedState())
            }
        case nil:
            if rows.isEmpty {
                unavailable(NoPhonesState(addPhone: addPhone))
            } else {
                unavailable(NothingSelectedState())
            }
        }
    }

    private func phonePage(_ id: String) -> some View {
        Form {
            PhoneSettingsPage(deviceId: id,
                              onRename: { controller.beginRename($0) },
                              onForget: { controller.beginForget($0) },
                              onAdd: addPhone)
        }
        .formStyle(.grouped)
    }

    private func unavailable(_ state: some View) -> some View {
        state.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: actions and stores

    private var rows: [DevicePhoneRow] {
        controller.rememberedPhones.map { phone in
            let presence = DevicesPreview.presence(of: phone, in: controller)
            return DevicesTabModel.phoneRow(
                id: phone.id, name: controller.displayName(for: phone.ref),
                model: phone.model, presence: presence,
                lastSeen: phone.lastSeen.formatted(.relative(presentation: .named)),
                inUse: controller.activePhone?.id == phone.id)
        }
    }

    private var inUseId: String? {
        controller.rememberedPhones.first { $0.id == controller.activePhone?.id }?.id
    }

    /// The staged preview's tab (the e2e and the shots) wins over the stored
    /// preference; otherwise the window reopens the last selection.
    private func selectInitial() {
        guard selection == nil else { return }
        if controller.settingsTab != .general {
            selection = SettingsSidebarModel.selection(for: controller.settingsTab, variant: variant,
                                                       phones: rows, inUseId: inUseId)
        } else {
            selection = SettingsSidebarModel.resolve(stored: SettingsSidebarStore.read(from: defaults),
                                                     variant: variant, phones: rows, inUseId: inUseId)
        }
    }

    /// "Add Phone…": the Deck's own add sheet, so pairing has one flow.
    private func addPhone() {
        DeckWindow.show()
        controller.sheet = .addPhone
    }

    private var forgettingPhone: RememberedPhone? {
        controller.rememberedPhones.first { $0.id == controller.forgettingDeviceId }
    }

    private var renaming: Binding<Bool> {
        Binding(get: { variant != .s3 && controller.renamingDeviceId != nil },
                set: { if !$0 { controller.endRename() } })
    }

    private var alertPrompt: Text {
        controller.rememberedPhones.first { $0.id == controller.renamingDeviceId }
            .map { Text($0.ref.name) } ?? Text("Nickname")
    }

    private func saveRename() {
        if let id = controller.renamingDeviceId {
            controller.setNickname(renameText, for: id)
        }
        controller.endRename()
    }
}

/// The 0-phone detail: the empty state names its one action (SET-DEV-02).
private struct NoPhonesState: View {
    let addPhone: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("No Phones", systemImage: "iphone.gen3")
        } description: {
            Text("Add a phone to use its apps and its screen on this Mac.")
        } actions: {
            Button("Add Phone…", action: addPhone)
                .buttonStyle(.borderedProminent)
        }
    }
}

private struct NothingSelectedState: View {
    var body: some View {
        ContentUnavailableView {
            Label("Nothing Selected", systemImage: "sidebar.left")
        } description: {
            Text("Choose a phone or a settings section on the left.")
        }
    }
}

/// The quiet prototype run draws its controls as an active app's: the window is
/// never key in a background run, so an "on" switch and the sidebar selection
/// would render in the inactive grey and a screenshot would misreport the
/// state. Test builds only, and only while the prototype flag is set.
enum ProtoSettingsRender {
    static func installActiveStandIn() {
        guard ProtoSettings.variant != .production,
              let original = class_getInstanceMethod(NSApplication.self, #selector(getter: NSApplication.isActive)),
              let standIn = class_getInstanceMethod(NSApplication.self, #selector(getter: NSApplication.protoSettingsIsActive))
        else { return }
        method_exchangeImplementations(original, standIn)
    }
}

extension NSApplication {
    @objc fileprivate var protoSettingsIsActive: Bool { true }
}
