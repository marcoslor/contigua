// Settings (⌘,): the sidebar window (docs/specs/settings.md) and the Mac-wide
// pages it hosts: General, Input and Automation. The phones live in the
// sidebar, so there is no Devices tab any more.

import AppKit
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    var body: some View {
        SettingsSidebarView()
            .frame(width: SettingsLayout.width)
            // A grouped Form reports its content's ideal height, and the Settings
            // window took it: on a short screen the rows below the fold were
            // clipped and could not scroll. The cap makes the window fit the
            // screen, so the page inside it scrolls; a shorter page keeps its
            // own natural height.
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
            // One compact header row: the page's title beside the sidebar
            // toggle (the default style put the title above an empty row).
            window.toolbarStyle = .unifiedCompact
            window.setContentSize(NSSize(width: SettingsLayout.width, height: height))
            // The source list takes the keyboard, so ↑/↓ work the moment the
            // window opens (SET-WIN-08).
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(250))
                if !SettingsSidebarFocus.take(in: window) {
                    try? await Task.sleep(for: .milliseconds(250))
                    SettingsSidebarFocus.take(in: window)
                }
            }
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

/// Settings' window size rules (docs/specs/settings.md, SET-WIN-07): the
/// smallest supported screen is 1280×800, and the whole window fits it.
enum SettingsLayout {
    /// The window: a 240 pt source list and a 480 pt detail (today's tab width).
    static let width: CGFloat = 720
    static let sidebarWidth: CGFloat = 240
    static var detailWidth: CGFloat { width - sidebarWidth }
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

/// The Forget confirmation (SET-DEV-07): names the phone, says the pairing
/// goes, and keeps the destructive button off the Return key.
struct ForgetConfirmation: View {
    let name: String
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Forget \(name)?")
                .font(.headline)
            Text("Removes this Mac's pairing with \(name). You'll need to pair it again to use it here.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Forget", role: .destructive, action: onConfirm)
            }
        }
        .padding(20)
        .frame(width: 400)
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

