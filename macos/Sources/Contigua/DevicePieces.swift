// The rows the Settings sidebar draws for a phone, and the staged state the
// `--preview` screenshot runs use (docs/specs/settings.md). No tab lives here:
// the phones are sidebar entries and their page is `PhoneSettingsPage`.

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
        if controller.activePhone?.id == phone.id { return controller.presentation.settingsPresence }
        // PAIR-32/SET-DEV-17: a phone whose record says trust was lost reads
        // Pair again even when its key is still on disk.
        if controller.remembered.trustLost(id: phone.id) != nil { return .pairAgain }
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
