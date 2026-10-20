// The "Show phone files in Finder" surface: the Deck's one-time System Settings
// prompt and the Settings row (docs/design/files.md §1 "Product consequence").

import SwiftUI

/// The Deck line for the one-time switch: a new domain stays user-disabled
/// until the person turns PocketDeck on in Login Items & Extensions.
struct FilesFinderPromptLine: View {
    @Environment(ConnectionController.self) private var controller

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "folder.badge.questionmark")
                .foregroundStyle(.secondary)
            Text("Turn on PocketDeck in System Settings › Login Items & Extensions to show phone files in Finder.")
                .font(.callout)
            Spacer(minLength: 8)
            Button("Open System Settings") { controller.filesDomain.openSystemSettings() }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }
}

/// Settings › General: the toggle, what it does, and the switch prompt with the
/// deep link and a re-check for after the person flips it.
struct FilesFinderSettings: View {
    @Environment(ConnectionController.self) private var controller

    var body: some View {
        Section {
            Toggle("Show phone files in Finder", isOn: Binding(
                get: { controller.filesDomain.enabled },
                set: { controller.filesDomain.setEnabled($0) }))
            Text("The phone's storage appears as a location in Finder: browse folders, open files and copy them out. Read-only for now; the phone stays awake only while you browse.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if controller.filesDomain.needsSwitch {
                Text("Turn on PocketDeck in System Settings › Login Items & Extensions, then come back. Finder stays empty until then.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Button("Open System Settings") { controller.filesDomain.openSystemSettings() }
                    Button("Check again") { controller.filesDomain.refresh() }
                }
            }
            if controller.filesDomain.state == .failed {
                Text("Finder files could not be turned on. Restart PocketDeck and try again.")
                    .font(.subheadline)
                    .foregroundStyle(.red)
            }
        }
    }
}
