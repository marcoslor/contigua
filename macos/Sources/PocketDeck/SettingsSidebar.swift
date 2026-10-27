// The Settings window (docs/specs/settings.md): a System Settings–style sidebar
// whose first group is this Mac's phones. Each phone opens its own page
// (`PhoneSettingsPage`, unchanged in what it stores), and the Mac-wide sections
// (General, Input, Automation) sit below it. The window's navigation state is
// `SettingsSelection` (SettingsSelection.swift); the window title is the open
// page's name, and a phone's name appears in its page header and the title,
// never in a section heading.

import AppKit
import SwiftUI

/// One selectable sidebar row.
struct SettingsSidebarItem: Equatable, Identifiable {
    let selection: SettingsSelection
    let title: String
    let systemImage: String
    /// A phone's last-seen time when it is not connected; never colour alone.
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
    /// Add Phone… is the last row of the Phones group.
    let showsAddPhone: Bool
}

/// The sidebar's pure half: the order of the groups, what a row says, and the
/// window title of a page.
enum SettingsSidebarModel {

    static let addPhoneTitle = "Add Phone…"
    static let emptyPhonesText = "No phones yet."

    static func groups(phones: [DevicePhoneRow]) -> [SettingsSidebarGroup] {
        [
            SettingsSidebarGroup(id: "phones", title: "Phones", items: phones.map(item(for:)),
                                 showsAddPhone: true),
            SettingsSidebarGroup(id: "mac", title: "This Mac", items: macItems(), showsAddPhone: false),
        ]
    }

    static func item(for row: DevicePhoneRow) -> SettingsSidebarItem {
        SettingsSidebarItem(
            selection: .phone(row.id), title: row.name, systemImage: "iphone.gen3",
            subtitle: row.lastSeenText, presence: .init(text: row.presenceText),
            inUse: row.inUse, help: help(for: row),
            accessibilityLabel: accessibilityLabel(for: row))
    }

    static func addPhoneItem() -> SettingsSidebarItem {
        SettingsSidebarItem(
            selection: .general, title: addPhoneTitle, systemImage: "plus",
            subtitle: nil, presence: nil, inUse: false,
            help: "Pair a phone that is on the same Wi-Fi as this Mac.",
            accessibilityLabel: "Add Phone…")
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

    /// The window title: the open page's own name (SET-WIN-06).
    static func title(for selection: SettingsSelection, rows: [DevicePhoneRow]) -> String {
        switch selection {
        case .general: return "General"
        case .input: return "Input"
        case .automation: return "Automation"
        case .phone(let id): return rows.first { $0.id == id }?.name ?? "Phones"
        }
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
    /// The row's words are the source; the dot only fills their colour.
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

// MARK: - The window

struct SettingsSidebarView: View {
    @Environment(ConnectionController.self) private var controller
    @State private var selection: SettingsSelection = .general
    @State private var renameText = ""

    private var defaults: UserDefaults { controller.profile.defaults }

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .navigationSplitViewStyle(.balanced)
        // The title is the page under the sidebar's selection, not the app.
        .navigationTitle(pageTitle)
        .onAppear {
            apply(.open(stored: SettingsSelectionStore.read(from: defaults),
                        phones: phoneIds, inUse: inUseId))
        }
        .onChange(of: controller.rememberedPhones.map(\.id)) { _, _ in
            apply(.phonesChanged(phones: phoneIds, inUse: inUseId))
        }
        .onChange(of: controller.settingsAddRequest) { _, _ in
            // The check's setup for Add Phone…: the same action the row runs.
            apply(.addPhone)
        }
        .onChange(of: controller.settingsReportRequest) { _, _ in
            // A phone page writes its own report (it holds the page's state);
            // this is the report for every other page and for 0 phones.
            if !selection.isPhonePage { writeReport() }
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
        // A sheet, not an alert: a confirmation should not take the focus.
        .sheet(isPresented: Binding(
            get: { controller.forgettingDeviceId != nil },
            set: { if !$0 { controller.endForget() } })) {
            if let phone = forgettingPhone {
                ForgetConfirmation(
                    name: controller.displayName(for: phone.ref),
                    onCancel: { controller.endForget() },
                    onConfirm: {
                        controller.forget(phone)
                        controller.endForget()
                        // The forgotten phone may be the open page (SET-WIN-05).
                        apply(.forgot(deviceId: phone.id, phones: phoneIds, inUse: inUseId))
                    })
            }
        }
    }

    private var sidebar: some View {
        List(selection: listSelection) {
            ForEach(SettingsSidebarModel.groups(phones: rows)) { group in
                Section {
                    ForEach(group.items) { item in
                        row(item, selected: selection == item.selection).tag(item.selection)
                    }
                    if group.showsAddPhone {
                        if rows.isEmpty {
                            Text(SettingsSidebarModel.emptyPhonesText)
                                .foregroundStyle(.secondary)
                                .accessibilityLabel(SettingsSidebarModel.emptyPhonesText)
                        }
                        addPhoneRow
                    }
                } header: {
                    if let title = group.title { Text(title) }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: SettingsLayout.sidebarWidth,
                                        ideal: SettingsLayout.sidebarWidth, max: 280)
    }

    /// The list selects the sidebar's own state; clicking empty space must not
    /// clear the page, so a nil set is ignored.
    private var listSelection: Binding<SettingsSelection?> {
        Binding(get: { selection },
                set: { page in
                    guard let page else { return }
                    apply(.choose(page, phones: phoneIds))
                })
    }

    @ViewBuilder
    private func row(_ item: SettingsSidebarItem, selected: Bool) -> some View {
        HStack(spacing: 8) {
            if let presence = item.presence {
                DeviceGlyph(size: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.title)
                        .lineLimit(1)
                    HStack(spacing: 4) {
                        DeviceStatusLabel(presence: presence)
                            .font(.caption)
                            .layoutPriority(1)
                        if let subtitle = item.subtitle {
                            Text("· \(subtitle)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .lineLimit(1)
                }
                Spacer(minLength: 4)
                if item.inUse {
                    // The accent blue disappears on the selected row's blue.
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(Color.accentColor))
                        .layoutPriority(1)
                        .accessibilityHidden(true)
                }
            } else {
                Label(item.title, systemImage: item.systemImage)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.accessibilityLabel)
        .help(item.help)
    }

    private var addPhoneRow: some View {
        let item = SettingsSidebarModel.addPhoneItem()
        return Button(action: { apply(.addPhone) }) {
            Label(item.title, systemImage: item.systemImage)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(item.accessibilityLabel)
        .help(item.help)
    }

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .general: GeneralSettings()
        case .input: InputSettings()
        case .automation: AutomationSettings()
        case .phone(let id):
            if controller.rememberedPhones.contains(where: { $0.id == id }) {
                Form {
                    PhoneSettingsPage(deviceId: id,
                                      onRename: { controller.beginRename($0) },
                                      onForget: { controller.beginForget($0) },
                                      onAdd: addPhone)
                }
                .formStyle(.grouped)
            } else {
                // The page's phone is gone (a forget that has not re-rendered
                // yet): the sidebar resolves the selection in the same pass.
                ContentUnavailableView("No Phones", systemImage: "iphone.gen3")
            }
        }
    }

    // MARK: actions and stores

    private var phoneIds: [String] { controller.rememberedPhones.map(\.id) }

    private var inUseId: String? {
        controller.rememberedPhones.first { $0.id == controller.activePhone?.id }?.id
    }

    private var pageTitle: String {
        SettingsSidebarModel.title(for: selection, rows: rows)
    }

    private var rows: [DevicePhoneRow] {
        SettingsPhoneRows.rows(in: controller)
    }

    /// The machine decides, the window performs: one path for opening,
    /// choosing, pairing and forgetting (SET-WIN-03/04/05).
    private func apply(_ event: SettingsSelectionEvent) {
        let step = SettingsSelectionMachine.step(from: selection, event: event)
        selection = step.selection
        for action in step.actions {
            switch action {
            case .store: SettingsSelectionStore.write(step.selection, to: defaults)
            case .addPhoneSheet: addPhone()
            }
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
        Binding(get: { controller.renamingDeviceId != nil },
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

    // MARK: the e2e's read

    /// What the window renders for a page that is not a phone's (the phone page
    /// reports itself). Same values the rows and the title above use.
    private func writeReport() {
        guard let path = controller.settingsReportPath else { return }
        var lines = SettingsReport.base(selection: selection, title: pageTitle, rows: rows)
        lines.append("page=\(reportPageName)")
        if controller.rememberedPhones.isEmpty { lines.append("empty=\(SettingsSidebarModel.emptyPhonesText)") }
        if let sheet = controller.sheet {
            lines.append("sheet=\(SettingsReport.sheetName(sheet))")
        }
        try? (lines.joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8)
    }

    private var reportPageName: String {
        switch selection {
        case .general: return "general"
        case .input: return "input"
        case .automation: return "automation"
        case .phone: return "phone"
        }
    }
}

// MARK: - The e2e's report pieces

/// The phone rows the sidebar and the report read: the live link for the phone
/// in use, a remembered phone's own last state for the others.
@MainActor
enum SettingsPhoneRows {
    static func rows(in controller: ConnectionController) -> [DevicePhoneRow] {
        controller.rememberedPhones.map { phone in
            let presence = DevicesPreview.presence(of: phone, in: controller)
            return DevicesTabModel.phoneRow(
                id: phone.id, name: controller.displayName(for: phone.ref),
                model: phone.model, presence: presence,
                lastSeen: phone.lastSeen.formatted(.relative(presentation: .named)),
                inUse: controller.activePhone?.id == phone.id)
        }
    }
}

/// The report both writers build, so the sidebar and a phone's page describe
/// the same rows and the same title (the e2e's read of the real view).
enum SettingsReport {

    @MainActor
    static func base(selection: SettingsSelection, title: String, rows: [DevicePhoneRow]) -> [String] {
        var lines = ["phones=\(rows.count)"]
        lines.append("selection=\(selectionName(selection, rows: rows))")
        lines.append("title=\(title)")
        lines.append("focus=\(focusName())")
        for row in rows {
            lines.append(["row", row.name, row.model, row.presenceText, row.lastSeenText ?? "",
                          row.inUse ? "1" : "0", row.pairAgain ? "1" : "0",
                          row.canUseThisPhone ? "1" : "0"].joined(separator: "|"))
        }
        return lines
    }

    static func selectionName(_ selection: SettingsSelection, rows: [DevicePhoneRow]) -> String {
        switch selection {
        case .general: return "General"
        case .input: return "Input"
        case .automation: return "Automation"
        case .phone(let id): return rows.first { $0.id == id }?.name ?? "-"
        }
    }

    /// Where the keyboard is: the sidebar's table, a text field, the window.
    /// The e2e proves ↑/↓ reach the sidebar and Tab leaves it for the detail.
    @MainActor
    static func focusName() -> String {
        guard let responder = NSApp.keyWindow?.firstResponder else { return "none" }
        if responder is NSTableView { return "sidebar" }
        if responder is NSTextView { return "text" }
        if responder is NSWindow { return "window" }
        return "other"
    }

    static func sheetName(_ sheet: DeckSheet) -> String {
        switch sheet {
        case .addPhone: return "addPhone"
        case .code: return "code"
        case .qr: return "qr"
        case .manual: return "manual"
        }
    }
}
