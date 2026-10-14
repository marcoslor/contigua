// The menu bar item and the app's menu commands (docs/design/mac-redesign.md §3.8, §5).

import AppKit
import SwiftUI

struct MenuBarIcon: View {
    @Environment(ConnectionController.self) private var controller
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        icon
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
        Divider()
        Button("Open PocketDeck") { showDeck() }.keyboardShortcut("k")
        Button("Phone screen") { controller.openPhoneWindow() }
            .keyboardShortcut("p")
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
        guard let name = controller.activePhone?.name else { return "No phone paired" }
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
            Button("Add Phone…") {
                show()
                controller.sheet = .addPhone
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
        }
        CommandGroup(after: .toolbar) {
            Button("Find Apps") {
                show()
                controller.requestSearchFocus()
            }
            .keyboardShortcut("k")
            Button("Phone Window") { controller.openPhoneWindow() }
                .keyboardShortcut("p")
            Divider()
            Toggle("Show Touches", isOn: Binding(
                get: { streamMenu.showTouches },
                set: { controller.windows.showTouches = $0 }))
        }
        CommandMenu("Navigate") {
            Button("Back") { send(#selector(StreamWindowController.navigateBack(_:))) }
                .keyboardShortcut("[")
            Button("Home") { send(#selector(PhoneWindowController.navigateHome(_:))) }
                .keyboardShortcut("h", modifiers: [.command, .shift])
            Button("Recents") { send(#selector(PhoneWindowController.navigateRecents(_:))) }
                .keyboardShortcut(.upArrow, modifiers: .command)
        }
    }

    private func show() {
        if DeckWindow.window == nil { openWindow(id: DeckWindow.id) }
        DeckWindow.show()
    }

    /// Stream windows implement these; the key window's controller answers.
    private func send(_ action: Selector) {
        NSApp.sendAction(action, to: nil, from: nil)
    }
}
