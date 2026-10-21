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

/// The menu bar's window panel: the shared phone controls with the menu bar's
/// own way of creating the Deck window (the Deck popover needs none).
struct MenuBarContent: View {
    @Environment(ConnectionController.self) private var controller
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        PhonePanelView(
            state: PhoneControlsState(controller: controller),
            actions: PhoneControlsActions(controller: controller) {
                if DeckWindow.window == nil { openWindow(id: DeckWindow.id) }
                DeckWindow.show()
            },
        )
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
            // View ▸ Framed / Immersive: one radio pair for the key stream
            // window, built by the commands themselves. A Picker's inline style
            // renders the pair as checkmarked radio items and re-reads the
            // selection when the menu updates; a Toggle does not (both radios
            // stay checked after a pick), and an AppKit item inserted here is
            // dropped the moment SwiftUI rebuilds the menu — how the person's
            // v104 and v107 menus lost these.
            Picker(selection: Binding(
                get: { streamMenu.style },
                set: { controller.windows.setKeyWindowStyle($0) })) {
                ForEach(MenuModel.styles, id: \.self) { style in
                    Text(style.label).tag(style)
                }
            } label: {
                EmptyView()
            }
            .pickerStyle(.inline)
            .labelsHidden()
            // The reveal choice: enabled only while the window is immersive, so
            // a choice is never also a submenu's parent (Framed/Immersive above
            // own the style).
            Menu {
                ForEach(MenuModel.hideControls, id: \.self) { entry in
                    if entry == .separator {
                        Divider()
                    } else {
                        Toggle(entry.title, isOn: Binding(
                            get: { ImmersiveMenuModel.isChecked(entry, reveal: streamMenu.revealDelay) },
                            set: { _ in controller.windows.pickImmersive(entry) }))
                    }
                }
            } label: {
                Text("Hide Controls")
            }
            .disabled(!MenuModel.hideControlsEnabled(style: streamMenu.style))
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
            .disabled(streamMenu.frozen)
            Button {
                send(#selector(PhoneWindowController.navigateHome(_:)))
            } label: {
                Label("Home", systemImage: "house")
            }
            .keyboardShortcut("h", modifiers: [.command, .shift])
            .disabled(streamMenu.frozen)
            Button {
                send(#selector(PhoneWindowController.navigateRecents(_:)))
            } label: {
                Label("Recents", systemImage: "square.stack")
            }
            .keyboardShortcut(.upArrow, modifiers: .command)
            .disabled(streamMenu.frozen)
            Divider()
            // Phone window only: the phone holds its own panel's power off while
            // the mirror keeps rendering (docs/design/phone-mirror.md). The
            // check follows the phone's `state.panel`, never a local guess.
            Toggle(isOn: Binding(
                get: { streamMenu.panelOff },
                set: { _ in controller.windows.togglePhonePanelOff() })) {
                Label("Turn Off Phone Screen", systemImage: "iphone.slash")
            }
            .disabled(!streamMenu.phoneWindow)
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
