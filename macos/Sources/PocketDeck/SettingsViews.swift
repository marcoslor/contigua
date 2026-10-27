// Settings (⌘,): General and Devices, nothing else (docs/design/mac-redesign.md §3.6).

import AppKit
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") { GeneralSettings() }
            Tab("Input", systemImage: "computermouse") { InputSettings() }
            Tab("Devices", systemImage: "iphone.gen3") { DevicesSettings() }
            Tab("Automation", systemImage: "terminal") { AutomationSettings() }
        }
        .frame(width: SettingsLayout.currentWidth)
        // A grouped Form reports its content's ideal height, and the Settings
        // window took it: on a short screen the rows below the fold were
        // clipped and could not scroll. The cap makes the TabView fit the
        // screen, so the form inside it scrolls; a shorter tab keeps its own
        // natural height.
        .frame(maxHeight: SettingsLayout.maxContentHeight(for: NSScreen.main?.visibleFrame.height ?? 800))
        .background(SettingsWindowTag())
    }
}

/// Sizes the Settings window to the screen: SwiftUI opens it at its own 450 pt
/// default whatever the form needs, so a long tab was cropped at "Default
/// window density" while the top of the screen was free. The window takes the
/// screen's room (SettingsLayout) and never extends past the visible frame; the
/// tab inside it scrolls for the rest.
private struct SettingsWindowTag: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            let screen = window.screen ?? NSScreen.main
            let height = SettingsLayout.maxContentHeight(for: screen?.visibleFrame.height ?? 800)
            window.setContentSize(NSSize(width: SettingsLayout.currentWidth, height: height))
            if let screen {
                var frame = window.frame
                frame.origin.x = min(max(screen.visibleFrame.minX, frame.origin.x),
                                     screen.visibleFrame.maxX - frame.width)
                frame.origin.y = min(max(screen.visibleFrame.minY, frame.origin.y),
                                     screen.visibleFrame.maxY - frame.height)
                window.setFrame(frame, display: false)
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// Settings' window size rules (docs/design/mac-redesign.md §3.6).
enum SettingsLayout {
    static let width: CGFloat = 480
    /// The window width this run draws: the prototype's wider window (a test
    /// hook), else today's 480 pt.
    static var currentWidth: CGFloat { ProtoDevices.windowWidth ?? width }
    /// The design's height; tall enough for General's usual rows, short enough
    /// for a 1280x800 screen with the menu bar and margins.
    static let designHeight: CGFloat = 560
    /// The title bar, the menu bar and a margin: the room a window must leave.
    static let chromeAllowance: CGFloat = 120
    static let minimumHeight: CGFloat = 320

    /// The tallest the tab content may be on a screen whose visible height is
    /// `visibleHeight` (no scrolling until the content is actually taller).
    static func maxContentHeight(for visibleHeight: CGFloat) -> CGFloat {
        max(min(designHeight, visibleHeight - chromeAllowance), minimumHeight)
    }
}

/// Settings › Automation: the automation server's gate (docs/design/mcp.md).
/// Off by default; while it is on, Settings shows the client snippet and how
/// many agents are connected.
struct AutomationSettings: View {
    @Environment(ConnectionController.self) private var controller
    @State private var copied = false

    var body: some View {
        Form {
            Section {
                Toggle("Allow AI agents to control your phone", isOn: Binding(
                    get: { controller.mcp.enabled },
                    set: { controller.mcp.setEnabled($0) },
                ))
                Text("A local MCP server lets an AI agent on this Mac see Phone Mirrors, tap, type, swipe, open apps and send links or files. It listens only on a private local socket, never on the network. Everything is off while this is off.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            if controller.mcp.enabled {
                Section("Connected agents") {
                    LabeledContent("Clients") {
                        Text("\(controller.mcp.clientCount)")
                    }
                    Button("Disconnect agent") { controller.mcp.disconnectAgents() }
                        .disabled(controller.mcp.clientCount == 0)
                }
                Section("MCP client configuration") {
                    Text(controller.mcp.configSnippet)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                    Button(copied ? "Copied" : "Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(controller.mcp.configSnippet, forType: .string)
                        copied = true
                    }
                }
                Section {
                    Text("Every tool call is logged by name and duration only, never its arguments, text, links, file names or pixels.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }
            if let error = controller.mcp.lastError {
                Section {
                    Text(error).font(.subheadline).foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// Settings → General "Glass app icons": the Deck grid's Liquid Glass tiles
/// (docs/design/mac-redesign.md). On unless turned off.
enum GlassIconsSetting {
    static let key = "deck.glassIcons"

    static func isEnabled(in defaults: UserDefaults) -> Bool {
        defaults.object(forKey: key) as? Bool ?? true
    }

    static var isEnabled: Bool { isEnabled(in: Profile.active.defaults) }
}

struct GeneralSettings: View {
    @Environment(ConnectionController.self) private var controller
    @AppStorage("showMenuBar", store: Profile.active.defaults) private var showMenuBar = true
    @AppStorage(ClipboardSync.enabledKey, store: Profile.active.defaults) private var shareClipboard = true
    @AppStorage(WindowDensity.key, store: Profile.active.defaults) private var density = 1.0
    @AppStorage(DockAutoSetting.key, store: Profile.active.defaults) private var showAppsInDock = true
    @AppStorage(GlassIconsSetting.key, store: Profile.active.defaults) private var glassIconsOn = true
    @AppStorage(RevealDelay.key, store: Profile.active.defaults) private var revealDelay: RevealDelay = .short
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Form {
            FilesFinderSettings()
            Toggle("Launch at login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, on in
                    do {
                        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                    } catch {
                        launchAtLogin = SMAppService.mainApp.status == .enabled
                    }
                }
            Toggle("Show in menu bar", isOn: $showMenuBar)
            Toggle("Share clipboard with your phone", isOn: $shareClipboard)
            Toggle("Show phone apps in the Dock", isOn: $showAppsInDock)
                .onChange(of: showAppsInDock) { _, _ in controller.showAppsInDockChanged() }
            Toggle("Glass app icons", isOn: $glassIconsOn)
            Picker("Default window density", selection: $density) {
                ForEach(WindowDensity.options, id: \.value) { Text($0.label).tag($0.value) }
            }
            .pickerStyle(.menu)
            .onChange(of: density) { _, value in controller.setDefaultDensity(value) }
            if !controller.densityOverrides.isEmpty {
                Section("App overrides") {
                    ForEach(controller.densityOverrides) { row in
                        LabeledContent(controller.displayName(forPackage: row.pkg)) {
                            HStack(spacing: 8) {
                                Text(DensityRules.percentLabel(row.value)).foregroundStyle(.secondary)
                                Button("Reset") { controller.clearDensityOverride(forPackage: row.pkg) }
                            }
                        }
                    }
                    Button("Reset all") { controller.clearAllDensityOverrides() }
                }
            }
            Picker("Reveal controls after", selection: $revealDelay) {
                ForEach(RevealDelay.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.menu)
            .onChange(of: revealDelay) { _, delay in controller.setRevealDelay(delay) }
        }
        .formStyle(.grouped)
    }
}

/// Settings ▸ Input: how the Mac's pointer and keyboard reach the phone.
struct InputSettings: View {
    @AppStorage(WindowManager.hoverKey, store: Profile.active.defaults) private var hover = true
    @AppStorage(SecondaryClick.key, store: Profile.active.defaults)
    private var secondary = SecondaryClick.longPress.rawValue

    private var secondaryChoice: SecondaryClick {
        SecondaryClick(rawValue: secondary) ?? .longPress
    }

    var body: some View {
        Form {
            Picker("Secondary click (two-finger click)", selection: $secondary) {
                ForEach(SecondaryClick.allCases) { Text($0.label).tag($0.rawValue) }
            }
            .pickerStyle(.menu)
            Text(secondaryChoice.explanation)
                .font(.subheadline).foregroundStyle(.secondary)
            Toggle("Hover over Android apps", isOn: $hover)
            Text("Moving the pointer over a stream window moves a mouse over the app, so hover highlights, tooltips and hover menus react. Off sends no hover at all; clicks and scrolling are unaffected.")
                .font(.subheadline).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }
}

struct DevicesSettings: View {
    @Environment(ConnectionController.self) private var controller
    @State private var forgetting: RememberedPhone?
    @State private var renameText = ""

    var body: some View {
        Group {
            if ProtoDevices.variant == .production {
                productionForm
            } else {
                ProtoDevicesSettings(onRename: { controller.beginRename($0) },
                                     onForget: { forgetting = $0 },
                                     onAdd: addPhone)
            }
        }
        // A rename in progress: which device, and the staged text (previews set
        // both; a row's Rename… button sets the device). The task also fires on
        // appear, so a state staged before the window existed fills the field.
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
        .confirmationDialog("Forget \(forgetTitle)?", isPresented: Binding(
            get: { forgetting != nil }, set: { if !$0 { forgetting = nil } }), titleVisibility: .visible) {
            Button("Forget", role: .destructive) {
                if let phone = forgetting { controller.forget(phone) }
                forgetting = nil
            }
            Button("Cancel", role: .cancel) { forgetting = nil }
        } message: {
            Text("You'll need to pair it again.")
        }
    }

    /// Today's tab, unchanged (the prototype options are a test hook).
    private var productionForm: some View {
        Form {
            Section {
                if controller.rememberedPhones.isEmpty {
                    Text("No phones yet.").foregroundStyle(.secondary)
                }
                ForEach(controller.rememberedPhones) { phone in productionRow(phone) }
            }
            Section {
                Text("Notifications and the playing media session per phone stay off until you turn them on; the phone only shares with a paired Mac.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Section {
                Button("Add phone…", action: addPhone)
                    .buttonStyle(.glass)
            }
        }
        .formStyle(.grouped)
    }

    /// "Add Phone…": the Deck's own add sheet, so pairing has one flow.
    private func addPhone() {
        DeckWindow.show()
        controller.sheet = .addPhone
    }

    /// The dialog's visibility lives in the controller, so previews can stage it.
    private var renaming: Binding<Bool> {
        Binding(get: { controller.renamingDeviceId != nil },
                set: { if !$0 { controller.endRename() } })
    }

    private var forgetTitle: String {
        forgetting.map { controller.displayName(for: $0.ref) } ?? "this phone"
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

    private func productionRow(_ phone: RememberedPhone) -> some View {
        let isActive = controller.activePhone?.id == phone.id
        return LabeledContent {
            VStack(alignment: .trailing, spacing: 8) {
                HStack(spacing: 8) {
                    stateText(phone, isActive: isActive)
                    Button("Rename…") { controller.beginRename(phone) }
                    if !isActive {
                        Button("Use") { controller.use(phone) }.buttonStyle(.glass)
                    }
                    Button("Forget", role: .destructive) { forgetting = phone }.buttonStyle(.glass).foregroundStyle(.red)
                }
                VStack(alignment: .trailing, spacing: 6) {
                    PhoneNotifyToggle(deviceId: phone.id)
                    PhoneNotifyClickPicker(deviceId: phone.id)
                    PhoneMutedApps(deviceId: phone.id)
                    PhonePanelIgnorePowerToggle(deviceId: phone.id)
                }
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(controller.displayName(for: phone.ref))
                Text(detail(phone, isActive: isActive)).font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func stateText(_ phone: RememberedPhone, isActive: Bool) -> some View {
        if isActive {
            switch controller.link {
            case .online: Text("Connected").foregroundStyle(.green)
            case .needsPairing: Text("Pair again").foregroundStyle(.orange)
            default: Text("Offline").foregroundStyle(.secondary)
            }
        }
    }

    private func detail(_ phone: RememberedPhone, isActive: Bool) -> String {
        let seen = isActive && controller.link.isOnline
            ? "now" : phone.lastSeen.formatted(.relative(presentation: .named))
        return [phone.model, "Last seen \(seen)"].filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

/// Per-phone notify toggle storage (privacy: default OFF, docs/design/notify.md).
enum NotifyToggle {
    static func key(deviceId: String) -> String { "notify.\(deviceId)" }

    /// A phone has no stored value until a person opted in: off until then.
    static func isEnabled(deviceId: String, defaults: UserDefaults) -> Bool {
        defaults.bool(forKey: key(deviceId: deviceId))
    }
}

/// The per-phone opt-in row (privacy default OFF; docs/design/notify.md). The
/// change tells the live session right away; a fresh session picks it up from
/// the stored flag.
/// "Keep the phone screen off until I turn it on from the Mac": what a press
/// of the phone's own power button does while the Mac holds the screen off.
/// Off by default; the phone stays locked either way.
private struct PhonePanelIgnorePowerToggle: View {
    let deviceId: String

    private var defaults: UserDefaults { Profile.active.defaults }

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Toggle(isOn: Binding(
                get: { PhonePanelIgnorePowerSetting.read(from: defaults, deviceId: deviceId) },
                set: { PhonePanelIgnorePowerSetting.write($0, for: deviceId, to: defaults) },
            )) {
                Text("Keep the phone screen off until I turn it on from the Mac")
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            Text("A press of the phone's power button lights its screen for a moment, then it goes dark again.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
    }
}

private struct PhoneNotifyToggle: View {
    let deviceId: String

    @Environment(ConnectionController.self) private var controller

    private var defaults: UserDefaults { Profile.active.defaults }
    private var key: String { NotifyToggle.key(deviceId: deviceId) }

    var body: some View {
        Toggle(isOn: Binding(
            get: { defaults.bool(forKey: key) },
            set: { controller.notifySettingChanged(deviceId: deviceId, on: $0) },
        )) {
            Text("Show notifications + Now Playing")
        }
        .toggleStyle(.switch)
        .controlSize(.small)
    }
}

/// "When I click a phone notification" (ROADMAP D2): the same per-phone row,
/// enabled only while the notification toggle above it is on. The choice is
/// stored beside `notify.<deviceId>` and read on every click.
private struct PhoneNotifyClickPicker: View {
    let deviceId: String

    @Environment(ConnectionController.self) private var controller
    @AppStorage private var notifyEnabled: Bool

    init(deviceId: String) {
        self.deviceId = deviceId
        _notifyEnabled = AppStorage(
            wrappedValue: false,
            NotifyToggle.key(deviceId: deviceId),
            store: Profile.active.defaults,
        )
    }

    private var defaults: UserDefaults { Profile.active.defaults }
    private var selection: Binding<NotifyClickTarget> {
        Binding(
            get: { NotifyClickTarget.stored(deviceId: deviceId, defaults: defaults) },
            set: { controller.notifyClickSettingChanged(deviceId: deviceId, target: $0) },
        )
    }

    var body: some View {
        Picker("When I click a phone notification", selection: selection) {
            ForEach(NotifyClickTarget.allCases) { target in
                Text(target.label).tag(target)
            }
        }
        .pickerStyle(.menu)
        .controlSize(.small)
        .disabled(!notifyEnabled)
        .help("What a click on this phone's notification does.")
    }
}

/// "Muted apps" (ROADMAP v0.2 #8): the packages this phone's notifications came
/// from this session, plus the already muted ones, toggled per phone. Package
/// names and labels only — never any notification text.
private struct PhoneMutedApps: View {
    let deviceId: String

    @Environment(ConnectionController.self) private var controller
    @AppStorage private var notifyEnabled: Bool
    @State private var muted: Set<String> = []

    init(deviceId: String) {
        self.deviceId = deviceId
        _notifyEnabled = AppStorage(
            wrappedValue: false,
            NotifyToggle.key(deviceId: deviceId),
            store: Profile.active.defaults,
        )
    }

    private var packages: [String] {
        Array(Set(controller.notifyMutedAppChoices(deviceId: deviceId)).union(muted)).sorted()
    }

    var body: some View {
        if notifyEnabled, !packages.isEmpty {
            DisclosureGroup("Muted apps") {
                ForEach(packages, id: \.self) { pkg in
                    Toggle(isOn: Binding(
                        get: { muted.contains(pkg) },
                        set: { on in
                            if on { muted.insert(pkg) } else { muted.remove(pkg) }
                            controller.notifyMuteChanged(deviceId: deviceId, pkg: pkg, muted: on)
                        },
                    )) {
                        Text(controller.appLabel(for: pkg) ?? pkg)
                    }
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
                }
            }
            .controlSize(.small)
            .onAppear { muted = NotifyMute.muted(deviceId: deviceId, defaults: Profile.active.defaults) }
        }
    }
}
