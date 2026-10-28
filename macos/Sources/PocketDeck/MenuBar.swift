// The menu bar item and the app's menu commands (docs/design/mac-redesign.md §3.8, §5).

import AppKit
import SwiftUI

struct MenuBarIcon: View {
    @Environment(ConnectionController.self) private var controller

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
            DeckWindow.open()
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

    /// Called when a row opens a window: the AppKit panel closes itself, as a
    /// menu bar panel does after its command ran.
    var onOpenWindow: (() -> Void)?

    /// Opens the icon's menu: the right-click and the panel's gear use this one
    /// function, so they cannot drift apart.
    var onSecondaryMenu: (() -> Void)?

    var body: some View {
        PhonePanelView(state: PhoneControlsState(controller: controller),
                       actions: actions,
                       onGear: onSecondaryMenu)
    }

    private var actions: PhoneControlsActions {
        var actions = PhoneControlsActions(controller: controller) { DeckWindow.open() }
        let close = onOpenWindow
        let openPhoneMirror = actions.openPhoneScreen
        let findApps = actions.findApps
        let continueOnMac = actions.continueOnMac
        let installApk = actions.installApk
        actions.openPhoneScreen = { openPhoneMirror(); close?() }
        actions.findApps = { findApps(); close?() }
        actions.continueOnMac = { continueOnMac(); close?() }
        actions.installApk = { installApk(); close?() }
        return actions
    }
}

struct AppCommands: Commands {
    let controller: ConnectionController
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        // The e2e `menus` check counts these: each one is a build of the
        // commands' NSMenu items, and one of them under an open menu is the
        // person's flickering submenu (MenuTrack.swift).
        let _ = Menus.noteBuild()
        // Every value the items show comes from this one snapshot (MenuBarModel):
        // the body reads nothing else that changes with the phone's state, so a
        // battery report, a stall or a Now Playing change does not rebuild the
        // bar under an open menu.
        let menu = MenuBarModel.shared.snapshot
        // The AppKit menu bar item and its panel live outside every scene, so
        // the panel's rows cannot ask SwiftUI to open a window themselves. The
        // commands do have the action, and they exist at launch even when the
        // app was started from a shell and SwiftUI presented no Deck yet.
        let _ = DeckWindow.openAction = { openWindow(id: DeckWindow.id) }

        // ⌘P is "Phone Mirror" (docs/design/mac-redesign.md §5); the app prints
        // nothing, so File is Add Phone…, Close and Close All.
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
            // View ▸ Framed / Immersive: one radio pair for the key stream
            // window, built by the commands themselves. An inline Picker renders
            // it as checkmarked radio items with no section title; an AppKit
            // item inserted here is dropped the moment SwiftUI rebuilds the
            // menu — how the person's v104 and v107 menus lost these. ⌥⌘F is
            // the pair's: it re-picks the checked style, which this binding
            // reads as "the other one".
            Picker(selection: Binding(
                get: { MenuBarModel.shared.snapshot.style },
                set: { picked in
                    if picked == MenuBarModel.shared.snapshot.style {
                        controller.windows.toggleKeyWindowStyle()
                    } else {
                        controller.windows.setKeyWindowStyle(picked)
                    }
                })) {
                Text(WindowStyle.framed.label)
                    .tag(WindowStyle.framed)
                    .keyboardShortcut("f", modifiers: [.command, .option])
                Text(WindowStyle.immersive.label)
                    .tag(WindowStyle.immersive)
            } label: {
                EmptyView()
            }
            .pickerStyle(.inline)
            .labelsHidden()
            // The pair acts on the key stream window only, and SwiftUI builds
            // the items once: MenuMarks writes both the mark and the enabled
            // flag when the menu opens and whenever the key window changes.
            // The items stay enabled here on purpose — a disabled menu item
            // eats its key equivalent, and ⌥⌘F is on this pair.
            // The reveal choice: enabled only while the window is immersive, so
            // a choice is never also a submenu's parent (Framed/Immersive above
            // own the style). A pick stores the choice and leaves the style.
            Menu {
                ForEach(MenuModel.hideControls, id: \.self) { entry in
                    if entry == .separator {
                        Divider()
                    } else {
                        Toggle(entry.title, isOn: Binding(
                            get: { ImmersiveMenuModel.isChecked(entry, reveal: MenuBarModel.shared.snapshot.revealDelay) },
                            set: { _ in controller.windows.pickImmersive(entry) }))
                    }
                }
            } label: {
                Text("Hide Controls")
            }
            .disabled(!MenuModel.hideControlsEnabled(style: menu.style))
            Divider()
            Toggle(isOn: Binding(
                get: { menu.showTouches },
                set: { controller.windows.showTouches = $0 })) {
                Label("Show Touches", systemImage: "hand.tap")
            }
            Toggle(isOn: Binding(
                get: { menu.liveText },
                set: { controller.windows.setKeyWindowLiveText($0) })) {
                Label("Live Text", systemImage: "text.viewfinder")
            }
            .keyboardShortcut("t", modifiers: [.command, .shift])
            Divider()
            // View ▸ Density: the key stream window's app override, remembered
            // per app (WindowDensityStore) and applied to every open window of
            // that app. "Default" clears it; the check mark follows the
            // override (none checked when ⌘+/⌘- landed between two options).
            // Disabled without a key stream window that shows an app.
            Menu {
                Toggle(MenuModel.densityDefaultTitle(settings: menu.settingsDensity),
                       isOn: Binding(get: { densityCheck == .defaultItem },
                                     set: { _ in pickDensity(nil) }))
                Divider()
                ForEach(MenuModel.densityOptions(settings: menu.settingsDensity), id: \.value) { option in
                    Toggle(option.label, isOn: Binding(
                        get: { densityCheck == .value(option.value) },
                        set: { _ in pickDensity(option.value) }))
                }
                Divider()
                // The stream window's own ⌘+ ⌘− ⌘0, now visible.
                Button {
                    controller.windows.adjustKeyWindowDensity(DensityRules.step)
                } label: {
                    Label("Larger", systemImage: "plus.magnifyingglass")
                }
                .keyboardShortcut("+", modifiers: .command)
                Button {
                    controller.windows.adjustKeyWindowDensity(-DensityRules.step)
                } label: {
                    Label("Smaller", systemImage: "minus.magnifyingglass")
                }
                .keyboardShortcut("-", modifiers: .command)
                Button {
                    controller.windows.resetKeyWindowDensity()
                } label: {
                    Label("Actual Size", systemImage: "1.magnifyingglass")
                }
                .keyboardShortcut("0", modifiers: .command)
            } label: {
                Label("Density", systemImage: "textformat.size")
            }
            .disabled(!menu.hasStream || menu.densityPackage == nil)
        }
        // Phone ▸ the phone's own controls. The state and the actions are the
        // menu-bar panel's and the Deck popover's (PhonePanel.swift), so one
        // mapping decides what can work and a control that cannot is disabled,
        // never hidden (AGENTS "Honest settings").
        CommandMenu("Phone") {
            // The items read the snapshot's phone block, which is the same
            // PhoneControlsState mapping the panel uses but only its menu
            // values (MenuBarModel.Phone), so a battery or media report cannot
            // rebuild this menu.
            let phone = menu.phone
            let actions = PhoneControlsActions(controller: controller) { show() }
            Button {
                actions.openPhoneScreen()
            } label: {
                Label("Phone Mirror", systemImage: "iphone")
            }
            .keyboardShortcut("p")
            .disabled(!phone.mirrorEnabled)
            Button {
                actions.continueOnMac()
            } label: {
                Label("Move Phone App to Mac", systemImage: "arrow.up.forward.app")
            }
            .keyboardShortcut("c", modifiers: [.command, .shift])
            .disabled(!phone.continueEnabled)
            Divider()
            // The phone holds its own panel's power off while the mirror keeps
            // rendering (docs/design/phone-mirror.md). The check follows the
            // phone's `state.panel`, never a local guess; MenuMarks writes it
            // onto the item when the menu opens too.
            Toggle(isOn: Binding(
                get: { MenuBarModel.shared.snapshot.panelOff },
                set: { _ in controller.windows.togglePhonePanelOff() })) {
                Label("Turn Off Phone Screen", systemImage: "iphone.slash")
            }
            .disabled(!menu.phoneWindow || menu.phoneOffline)
            Toggle(isOn: Binding(
                get: { MenuBarModel.shared.snapshot.phone.dndOn },
                set: { actions.setDnd($0) })) {
                Label(PhonePanelItem.dnd.label, systemImage: "moon.fill")
            }
            .disabled(!phone.dndEnabled)
            Button {
                if phone.ringing {
                    actions.stopRing()
                } else {
                    actions.ring()
                }
            } label: {
                Label(phone.ringTitle,
                      systemImage: phone.ringing ? "bell.slash" : "iphone.radiowaves.left.and.right")
            }
            .disabled(!phone.ringEnabled)
            Divider()
            Button {
                actions.installApk()
            } label: {
                Label(phone.installTitle, systemImage: "arrow.down.app")
            }
            .disabled(!phone.installEnabled)
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
            .disabled(menu.frozen || menu.phoneOffline)
            Button {
                send(#selector(PhoneWindowController.navigateHome(_:)))
            } label: {
                Label("Home", systemImage: "house")
            }
            .keyboardShortcut("h", modifiers: [.command, .shift])
            .disabled(menu.frozen || menu.phoneOffline)
            Button {
                send(#selector(PhoneWindowController.navigateRecents(_:)))
            } label: {
                Label("Recents", systemImage: "square.stack")
            }
            .keyboardShortcut(.upArrow, modifiers: .command)
            .disabled(menu.frozen || menu.phoneOffline)
        }
        // Window ▸ Enter/Exit Full Screen: ⌃⌘F, the system's own full-screen
        // shortcut, and the title follows the key window. The phone window opts
        // out of full screen (it would letterbox the mirror), so the item is
        // disabled for it rather than doing nothing.
        CommandGroup(after: .windowSize) {
            Button {
                guard let window = NSApp.keyWindow ?? NSApp.mainWindow,
                      FullScreenMenu.allowsFullScreen(window) else { return }
                window.toggleFullScreen(nil)
            } label: {
                Label(MenuModel.fullScreenTitle(fullScreen: menu.fullScreen),
                      systemImage: MenuModel.fullScreenSymbol(fullScreen: menu.fullScreen))
            }
            .keyboardShortcut("f", modifiers: [.control, .command])
            // The phone window opts out of full screen, so the item is disabled
            // for it; the action asks the key window again before it acts.
            .disabled(!menu.fullScreenAllowed)
        }
        // Help has no help book and the app has no public issue tracker, so the
        // menu is empty rather than carrying a dead item (AGENTS "Honest
        // settings"). SwiftUI's own sidebar command lands here too; there is no
        // sidebar to toggle.
        CommandGroup(replacing: .help) {}
    }

    private func show() {
        if DeckWindow.window == nil { openWindow(id: DeckWindow.id) }
        DeckWindow.show()
    }

    /// Which View ▸ Density item is checked for the key stream window.
    private var densityCheck: DensityCheck {
        DensityCheck.forOverride(MenuBarModel.shared.snapshot.densityOverride)
    }

    private func pickDensity(_ value: Double?) {
        controller.windows.setKeyWindowDensity(value)
    }

    /// Stream windows implement these; the key window's controller answers.
    private func send(_ action: Selector) {
        NSApp.sendAction(action, to: nil, from: nil)
    }
}
