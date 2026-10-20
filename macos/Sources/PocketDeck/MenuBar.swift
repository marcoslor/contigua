// The menu bar item and the app's menu commands (docs/design/mac-redesign.md §3.8, §5).

import AppKit
import SwiftUI

struct MenuBarIcon: View {
    @Environment(ConnectionController.self) private var controller
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack(spacing: 3) {
            icon
            if controller.mcp.clientCount > 0 {
                Image(systemName: "circle.fill")
                    .font(.system(size: 5))
                    .accessibilityLabel("An AI agent is connected")
            }
        }
        .task {
            // This view exists from launch. Started from a shell (the test
            // harness) SwiftUI sometimes does not present the Deck by itself.
            try? await Task.sleep(for: .seconds(0.5))
            if DeckWindow.window == nil { openWindow(id: DeckWindow.id) }
        }
    }

    @ViewBuilder
    private var icon: some View {
        switch controller.link {
        case .online, .connecting, .pairing, .idle, .needsPairing:
            Image(systemName: "apps.iphone")
        case .reconnecting:
            Image(systemName: "apps.iphone").symbolEffect(.pulse)
        case .offline:
            Image(systemName: "iphone.slash")
        }
    }
}

struct MenuBarContent: View {
    @Environment(ConnectionController.self) private var controller
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(statusLine)
        if controller.mcp.clientCount > 0 {
            Text("AI agent connected (\(controller.mcp.clientCount))")
            Button("Disconnect agent") { controller.mcp.disconnectAgents() }
        }
        Divider()
        Button("Open PocketDeck") { showDeck() }.keyboardShortcut("k")
        Button("Phone screen") { controller.openPhoneWindow() }
            .keyboardShortcut("p")
            .disabled(!controller.link.isOnline)
        Button("Continue on Mac") { controller.continueOnMac() }
            .disabled(!controller.link.isOnline)
        Button("Ring Phone") { controller.ringPhone() }
            .disabled(!controller.link.isOnline)
        Button("Stop Ringing") { controller.stopRingingPhone() }
            .disabled(!controller.link.isOnline)
        Button("Install APK…") { controller.chooseApk() }
            .disabled(controller.apkInstaller.isBusy)
        Divider()
        audioSection
        Divider()
        SettingsLink { Text("Settings…") }
        Divider()
        Button("Quit PocketDeck") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }

    @ViewBuilder
    private var audioSection: some View {
        if controller.audioOn {
            Text("Phone audio: on")
            Slider(value: Binding(
                get: { Double(controller.audioVolume) },
                set: { controller.audioVolume = Float($0) },
            ), in: 0...1) {
                Text("Volume")
            }
            Toggle("Mute", isOn: Binding(
                get: { controller.audioMuted },
                set: { controller.audioMuted = $0 },
            ))
        } else {
            Text("Phone audio: off")
        }
    }

    private var statusLine: String {
        guard let phone = controller.activePhone else { return "No phone paired" }
        let name = controller.displayName(for: phone, fallback: "your phone")
        switch controller.link {
        case .online: return "● Connected to \(name)"
        case .connecting: return "Connecting…"
        case .reconnecting: return "Reconnecting…"
        case .offline: return "Offline"
        case .needsPairing: return "Pair \(name) again"
        case .pairing, .idle: return "No phone paired"
        }
    }

    private func showDeck() {
        if DeckWindow.window == nil { openWindow(id: DeckWindow.id) }
        DeckWindow.show()
        controller.requestSearchFocus()
    }
}

struct AppCommands: Commands {
    let controller: ConnectionController
    private let streamMenu = StreamMenuState.shared
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        // ⌘P is "Phone Window" (docs/design/mac-redesign.md §5); the app prints nothing.
        CommandGroup(replacing: .printItem) {}
        CommandGroup(after: .newItem) {
            Button {
                show()
                controller.sheet = .addPhone
            } label: {
                Label("Add Phone…", systemImage: "plus")
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
        }
        CommandGroup(after: .toolbar) {
            Button {
                show()
                controller.requestSearchFocus()
            } label: {
                Label("Find Apps", systemImage: "magnifyingglass")
            }
            .keyboardShortcut("k")
            Button {
                controller.openPhoneWindow()
            } label: {
                Label("Phone Window", systemImage: "iphone")
            }
            .keyboardShortcut("p")
            Button {
                controller.continueOnMac()
            } label: {
                Label("Continue on Mac", systemImage: "arrow.up.forward.app")
            }
            .keyboardShortcut("c", modifiers: [.command, .shift])
            Divider()
            Toggle(isOn: Binding(
                get: { streamMenu.showTouches },
                set: { controller.windows.showTouches = $0 })) {
                Label("Show Touches", systemImage: "hand.tap")
            }
            Toggle(isOn: Binding(
                get: { streamMenu.liveText },
                set: { controller.windows.setKeyWindowLiveText($0) })) {
                Label("Live Text", systemImage: "text.viewfinder")
            }
            .keyboardShortcut("t", modifiers: [.command, .shift])
            Divider()
            // The key stream window's style as two radio items: no section
            // title (a Picker's inline header does not look like a Mac menu),
            // just the two checks between dividers. The checked item's own
            // click sets true again; an uncheck is not a style.
            Toggle(isOn: Binding(
                get: { streamMenu.style == .framed },
                set: { if $0 { controller.windows.setKeyWindowStyle(.framed) } })) {
                Text(WindowStyle.framed.label)
            }
            Toggle(isOn: Binding(
                get: { streamMenu.style == .immersive },
                set: { if $0 { controller.windows.setKeyWindowStyle(.immersive) } })) {
                Text(WindowStyle.immersive.label)
            }
            Divider()
            // View ▸ Density: the key stream window's app override, remembered
            // per app (WindowDensityStore) and applied to every open window of
            // that app. "Default" clears it; the check mark follows the
            // override (none checked when ⌘+/⌘- landed between two options).
            // Disabled without a key stream window that shows an app.
            Menu {
                Toggle("Default (\(DensityRules.percentLabel(streamMenu.settingsDensity)))",
                       isOn: Binding(get: { densityCheck == .defaultItem },
                                     set: { _ in pickDensity(nil) }))
                Divider()
                ForEach(WindowDensity.options, id: \.value) { option in
                    Toggle(option.label, isOn: Binding(
                        get: { densityCheck == .value(option.value) },
                        set: { _ in pickDensity(option.value) }))
                }
            } label: {
                Label("Density", systemImage: "textformat.size")
            }
            .disabled(!streamMenu.hasStream || streamMenu.densityPackage == nil)
            // No disabled gate here: key equivalents do not get re-evaluated
            // when the state changes, and a disabled item eats its shortcut
            // silently under NSEvent.performKeyEquivalent. The binding itself
            // no-ops without a key stream window.
            Button {
                controller.windows.toggleKeyWindowStyle()
            } label: {
                Label("Toggle Window Style", systemImage: "rectangle.topthird.inset.filled")
            }
            .keyboardShortcut("f", modifiers: [.command, .option])
        }
        // Full screen is AppKit's own item, moved into the Window menu at
        // launch (FullScreenMenu.swift): only a system-provided item can carry
        // the standard 🌐F shortcut. Its title and symbol follow the key
        // window through StreamMenuState.
        CommandMenu("Navigate") {
            Button {
                send(#selector(StreamWindowController.navigateBack(_:)))
            } label: {
                Label("Back", systemImage: "chevron.backward")
            }
            .keyboardShortcut("[")
            Button {
                send(#selector(PhoneWindowController.navigateHome(_:)))
            } label: {
                Label("Home", systemImage: "house")
            }
            .keyboardShortcut("h", modifiers: [.command, .shift])
            Button {
                send(#selector(PhoneWindowController.navigateRecents(_:)))
            } label: {
                Label("Recents", systemImage: "square.stack")
            }
            .keyboardShortcut(.upArrow, modifiers: .command)
        }
    }

    private func show() {
        if DeckWindow.window == nil { openWindow(id: DeckWindow.id) }
        DeckWindow.show()
    }

    /// Which View ▸ Density item is checked for the key stream window.
    private var densityCheck: DensityCheck {
        DensityCheck.forOverride(streamMenu.densityOverride)
    }

    private func pickDensity(_ value: Double?) {
        controller.windows.setKeyWindowDensity(value)
    }

    /// Stream windows implement these; the key window's controller answers.
    private func send(_ action: Selector) {
        NSApp.sendAction(action, to: nil, from: nil)
    }
}
