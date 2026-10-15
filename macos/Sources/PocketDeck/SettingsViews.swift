// Settings (⌘,): General and Devices, nothing else (docs/design/mac-redesign.md §3.6).

import AppKit
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") { GeneralSettings() }
            Tab("Devices", systemImage: "iphone.gen3") { DevicesSettings() }
        }
        .frame(width: 480)
    }
}

enum WindowDensity {
    static let key = "defaultDensity"
    static let options: [(label: String, value: Double)] = [("75%", 0.75), ("100%", 1.0), ("125%", 1.25), ("150%", 1.5)]

    static var current: Double {
        let stored = Profile.active.defaults.double(forKey: key)
        return stored == 0 ? 1.0 : stored
    }
}

struct GeneralSettings: View {
    @Environment(ConnectionController.self) private var controller
    @AppStorage("showMenuBar", store: Profile.active.defaults) private var showMenuBar = true
    @AppStorage(ClipboardSync.enabledKey, store: Profile.active.defaults) private var shareClipboard = true
    @AppStorage(WindowDensity.key, store: Profile.active.defaults) private var density = 1.0
    @AppStorage(DockAutoSetting.key, store: Profile.active.defaults) private var showAppsInDock = true
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Form {
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
            Picker("Default window density", selection: $density) {
                ForEach(WindowDensity.options, id: \.value) { Text($0.label).tag($0.value) }
            }
            .pickerStyle(.menu)
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
    }
}

struct DevicesSettings: View {
    @Environment(ConnectionController.self) private var controller
    @State private var forgetting: RememberedPhone?
    @State private var renameText = ""

    var body: some View {
        Form {
            Section {
                if controller.rememberedPhones.isEmpty {
                    Text("No phones yet.").foregroundStyle(.secondary)
                }
                ForEach(controller.rememberedPhones) { phone in row(phone) }
            }
            Section {
                Button("Add phone…") {
                    DeckWindow.show()
                    controller.sheet = .addPhone
                }
                .buttonStyle(.glass)
            }
        }
        .formStyle(.grouped)
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

    private func row(_ phone: RememberedPhone) -> some View {
        let isActive = controller.activePhone?.id == phone.id
        return LabeledContent {
            HStack(spacing: 8) {
                stateText(phone, isActive: isActive)
                Button("Rename…") { controller.beginRename(phone) }
                if !isActive {
                    Button("Use") { controller.use(phone) }.buttonStyle(.glass)
                }
                Button("Forget", role: .destructive) { forgetting = phone }.buttonStyle(.glass).foregroundStyle(.red)
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
