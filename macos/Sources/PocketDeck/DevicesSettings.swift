// Settings ▸ Devices, the shipped tab (docs/specs/settings-devices.md). One
// grouped Form: a Phones section (a row per phone and Add Phone…), then one
// PhoneSettingsPage for the phone whose information button is open — the in-use
// phone by default. The page owns everything that belongs to that phone, so a
// later Settings sidebar can show it unchanged (reviewer, 10-27).

import AppKit
import SwiftUI

/// What a `--preview devices-…` run stages for the screenshot phones: they have
/// no session and no pins, so their state and seen apps are supplied here.
enum DevicesPreview {
    nonisolated(unsafe) static var stagedPresence: [String: DevicePresence] = [:]
    /// The muted-apps list starts open (the `-muted` screenshots and e2e).
    nonisolated(unsafe) static var openMutedList = false

    /// The live link for the phone in use, a staged value for another.
    @MainActor
    static func presence(of phone: RememberedPhone, in controller: ConnectionController) -> DevicePresence {
        if controller.activePhone?.id == phone.id { return DevicePresence(controller.link) }
        if let staged = stagedPresence[phone.id] { return staged }
        guard controller.hasPinnedKey(deviceId: phone.id) else { return .pairAgain }
        return .offline(phone.lastSeen)
    }

    @MainActor
    static func reset() {
        stagedPresence = [:]
        openMutedList = false
    }
}

// MARK: - Shared pieces

/// A phone's rounded app-icon-sized tile with the phone symbol.
struct DeviceGlyph: View {
    var size: CGFloat = 26

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(.quaternary)
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: "iphone.gen3")
                    .font(.system(size: size * 0.6))
                    .foregroundStyle(.secondary)
            }
            .accessibilityHidden(true)
    }
}

/// A dot and the state's own words (CONV-MAC-23).
struct DeviceStatusLabel: View {
    let presence: DevicePresence

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(tint)
                .frame(width: 7, height: 7)
            Text(presence.text)
                .foregroundStyle(presence.isLive ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
        }
        .font(.subheadline)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(presence.text)
    }

    private var tint: Color {
        switch presence {
        case .connected: return .green
        case .connecting, .reconnecting, .pairAgain: return .orange
        case .offline: return .secondary
        }
    }
}

/// An app's icon in the muted list: the real one when we have it, a neutral
/// tile when we do not (the package name then sits under the row's title).
struct AppRowIcon: View {
    let image: NSImage?

    var body: some View {
        if let image {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .frame(width: 18, height: 18)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                .accessibilityHidden(true)
        } else {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(.quaternary)
                .frame(width: 18, height: 18)
                .overlay {
                    Image(systemName: "app")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
                .accessibilityHidden(true)
        }
    }
}

// MARK: - The tab: the phone list plus one phone's page

struct DevicesSettingsTab: View {
    let onRename: (RememberedPhone) -> Void
    let onForget: (RememberedPhone) -> Void
    let onAdd: () -> Void

    @Environment(ConnectionController.self) private var controller
    @State private var selected: String?

    private var phones: [RememberedPhone] { controller.rememberedPhones }
    private var inUse: RememberedPhone? { phones.first { $0.id == controller.activePhone?.id } }
    private var pageId: String? {
        if let selected, phones.contains(where: { $0.id == selected }) { return selected }
        return (inUse ?? phones.first)?.id
    }

    var body: some View {
        Form {
            phoneList
            if let id = pageId {
                PhoneSettingsPage(deviceId: id, onRename: onRename, onForget: onForget, onAdd: onAdd)
            }
        }
        .formStyle(.grouped)
        .onAppear { selectDefault() }
        .onChange(of: phones.map(\.id)) { _, _ in selectDefault() }
        .onChange(of: controller.devicesReportRequest) { _, _ in
            if pageId == nil { writeEmptyReport() }
        }
    }

    private var phoneList: some View {
        Section {
            if phones.isEmpty {
                Text("No phones yet.")
                    .foregroundStyle(.secondary)
            }
            ForEach(phones) { phone in
                phoneRow(phone)
            }
            Button(action: onAdd) {
                Label(DevicesTabModel.labels.addPhone, systemImage: "plus")
            }
            .help("Pair a phone that is on the same Wi-Fi as this Mac.")
        } header: {
            Text("Phones")
        } footer: {
            if phones.isEmpty {
                Text("Pair a phone that is on the same Wi-Fi as this Mac.")
            }
        }
    }

    private func phoneRow(_ phone: RememberedPhone) -> some View {
        let presence = DevicesPreview.presence(of: phone, in: controller)
        let row = DevicesTabModel.phoneRow(
            id: phone.id, name: displayName(phone), model: phone.model, presence: presence,
            lastSeen: phone.lastSeen.formatted(.relative(presentation: .named)),
            inUse: controller.activePhone?.id == phone.id)
        return HStack(spacing: 10) {
            DeviceGlyph()
            VStack(alignment: .leading, spacing: 1) {
                Text(row.name)
                HStack(spacing: 5) {
                    DeviceStatusLabel(presence: presence)
                    if let seen = row.lastSeenText {
                        Text("· \(seen)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Spacer(minLength: 6)
            if row.inUse {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                    Text("In Use")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(DevicesTabModel.labels.inUse)
            }
            Button {
                selected = (selected == phone.id) ? nil : phone.id
            } label: {
                Image(systemName: selected == phone.id ? "info.circle.fill" : "info.circle")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .help(DevicesTabModel.labels.details(row.name))
            .accessibilityLabel(DevicesTabModel.labels.details(row.name))
        }
    }

    private func selectDefault() {
        let ids = Set(phones.map(\.id))
        if let selected, ids.contains(selected) { return }
        selected = inUse?.id ?? phones.first?.id
    }

    private func displayName(_ phone: RememberedPhone) -> String {
        controller.displayName(for: phone.ref)
    }

    /// The e2e's read of the empty tab (no page exists to report it).
    private func writeEmptyReport() {
        guard let path = controller.devicesReportPath else { return }
        let lines = ["phones=0", "empty=No phones yet.", "selected=-", "inuse=-"]
        try? (lines.joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8)
    }
}
