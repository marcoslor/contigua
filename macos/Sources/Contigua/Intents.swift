// The App Intents themselves (docs/design/intents.md): open a phone app or the
// whole phone, send a link or files, read the battery. The decisions live in
// IntentsCore, the app side in IntentsBridge; this file is the system-facing
// shape (titles, entities, phrases). Every intent takes an optional phone,
// defaults to the connected one, and throws a one-sentence LocalizedError.

import AppIntents
import Foundation

/// A paired phone, so Shortcuts can say which one an action is for.
struct PhoneEntity: AppEntity, Identifiable {
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Phone")
    static var defaultQuery = PhoneEntityQuery()

    var id: String
    var name: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }

    init(_ phone: IntentPhone) {
        id = phone.id
        name = phone.name
    }
}

struct PhoneEntityQuery: EntityStringQuery {
    @MainActor
    func entities(for identifiers: [String]) async throws -> [PhoneEntity] {
        IntentsBridge.phones().filter { identifiers.contains($0.id) }.map(PhoneEntity.init)
    }

    @MainActor
    func entities(matching string: String) async throws -> [PhoneEntity] {
        let folded = IntentPhoneResolver.fold(string)
        return IntentsBridge.phones()
            .filter { folded.isEmpty || IntentPhoneResolver.fold($0.name).contains(folded) }
            .map(PhoneEntity.init)
    }

    @MainActor
    func suggestedEntities() async throws -> [PhoneEntity] {
        IntentsBridge.phones().map(PhoneEntity.init)
    }
}

/// An app installed on a phone: the same list Spotlight indexes.
struct PhoneAppEntity: AppEntity, Identifiable {
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Phone App")
    static var defaultQuery = PhoneAppEntityQuery()

    /// The package name is the stable identity; the label is what a person sees.
    var id: String
    var label: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(label)", subtitle: "\(id)")
    }

    init(pkg: String, label: String) {
        id = pkg
        self.label = label
    }

    init(_ app: AppInfo) {
        id = app.pkg
        label = app.label
    }
}

struct PhoneAppEntityQuery: EntityStringQuery {
    /// The apps of the phone an intent would act on (connected first).
    @MainActor
    private func catalog() -> [AppInfo] {
        guard let phone = try? IntentsBridge.resolve(nil) else { return [] }
        return IntentsBridge.apps(for: phone)
    }

    @MainActor
    func entities(for identifiers: [String]) async throws -> [PhoneAppEntity] {
        let apps = catalog()
        return identifiers.map { pkg in
            if let app = apps.first(where: { $0.pkg == pkg }) { return PhoneAppEntity(app) }
            // A shortcut may outlive an uninstall; keep the name it was saved with
            // rather than dropping it from the parameter.
            return PhoneAppEntity(pkg: pkg, label: pkg)
        }
    }

    @MainActor
    func entities(matching string: String) async throws -> [PhoneAppEntity] {
        IntentAppCatalog.search(string, in: catalog()).map(PhoneAppEntity.init)
    }

    @MainActor
    func suggestedEntities() async throws -> [PhoneAppEntity] {
        IntentAppCatalog.search("", in: catalog()).map(PhoneAppEntity.init)
    }
}

// MARK: Intents

struct OpenPhoneAppIntent: AppIntent {
    static var title: LocalizedStringResource = "Open Phone App"
    static var description = IntentDescription("Opens an app from your phone in its own window on this Mac.")
    static var openAppWhenRun: Bool = true

    @Parameter(title: "App")
    var app: PhoneAppEntity

    @Parameter(title: "Phone")
    var phone: PhoneEntity?

    @Parameter(title: "Open Another Window", default: false)
    var newWindow: Bool

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let target = try IntentsBridge.resolve(phone?.id)
        return .result(dialog: "\(try IntentsBridge.openApp(app.id, on: target, newWindow: newWindow))")
    }
}

struct OpenPhoneScreenIntent: AppIntent {
    static var title: LocalizedStringResource = "Open Phone Mirror"
    static var description = IntentDescription("Opens the Phone Mirror on this Mac.")
    static var openAppWhenRun: Bool = true

    @Parameter(title: "Phone")
    var phone: PhoneEntity?

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let target = try IntentsBridge.resolve(phone?.id)
        return .result(dialog: "\(try IntentsBridge.openPhoneScreen(on: target))")
    }
}

struct SendLinkToPhoneIntent: AppIntent {
    static var title: LocalizedStringResource = "Send Link to Phone"
    static var description = IntentDescription("Opens a link on your phone, in the app that handles it there.")

    @Parameter(title: "Link")
    var url: URL

    @Parameter(title: "Phone")
    var phone: PhoneEntity?

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let target = try IntentsBridge.resolve(phone?.id)
        return .result(dialog: "\(try IntentsBridge.sendLink(url.absoluteString, on: target))")
    }
}

struct SendFileToPhoneIntent: AppIntent {
    static var title: LocalizedStringResource = "Send File to Phone"
    static var description = IntentDescription("Sends files to your phone's Download/Contigua folder.")

    @Parameter(title: "Files")
    var files: [IntentFile]

    @Parameter(title: "Phone")
    var phone: PhoneEntity?

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let target = try IntentsBridge.resolve(phone?.id)
        let paths = try files.map { file -> String in
            guard let path = file.fileURL?.path else { throw IntentFailure.fileMissing(file.filename) }
            return path
        }
        return .result(dialog: "\(try IntentsBridge.sendFiles(paths, on: target))")
    }
}

struct PhoneBatteryIntent: AppIntent {
    static var title: LocalizedStringResource = "Phone Battery"
    static var description = IntentDescription(
        "Reads the battery your phone last reported. It never wakes the phone.")
    static var parameterSummary: some ParameterSummary {
        Summary("Battery of \(\.$phone)")
    }

    @Parameter(title: "Phone")
    var phone: PhoneEntity?

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<Int> {
        let target = try IntentsBridge.resolve(phone?.id)
        let answer = IntentsBridge.battery(for: target)
        // -1 when this phone never reported a level; the dialog says so.
        return .result(value: answer.level ?? -1, dialog: "\(target.name): \(answer.text)")
    }
}

struct RingPhoneIntent: AppIntent {
    static var title: LocalizedStringResource = "Ring Phone"
    static var description = IntentDescription(
        "Rings your phone at its alarm volume, over the lock screen, for up to 30 seconds.")
    static var parameterSummary: some ParameterSummary {
        Summary("Ring \(\.$phone) for \(\.$seconds) seconds")
    }

    @Parameter(title: "Phone")
    var phone: PhoneEntity?

    @Parameter(title: "Seconds", default: 30)
    var seconds: Int

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let target = try IntentsBridge.resolve(phone?.id)
        return .result(dialog: "\(try IntentsBridge.ring(target, seconds: max(1, min(30, seconds))))")
    }
}

// MARK: Spoken phrases (Siri, Spotlight actions)
struct ContiguaShortcuts: AppShortcutsProvider {
    static var shortcutTileColor: ShortcutTileColor = .navy

    @AppShortcutsBuilder
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: OpenPhoneScreenIntent(),
            phrases: [
                "Open my phone in \(.applicationName)",
                "Open \(.applicationName) phone"
            ],
            shortTitle: "Phone Mirror",
            systemImageName: "iphone"
        )
        AppShortcut(
            intent: PhoneBatteryIntent(),
            phrases: [
                "Phone battery in \(.applicationName)",
                "How much battery is left on my phone in \(.applicationName)"
            ],
            shortTitle: "Phone Battery",
            systemImageName: "battery.75percent"
        )
        AppShortcut(
            intent: RingPhoneIntent(),
            phrases: [
                "Ring my phone in \(.applicationName)"
            ],
            shortTitle: "Ring Phone",
            systemImageName: "iphone.radiowaves.left.and.right"
        )
        AppShortcut(
            intent: OpenPhoneAppIntent(),
            phrases: [
                "Open \(\.$app) on my phone in \(.applicationName)"
            ],
            shortTitle: "Open Phone App",
            systemImageName: "apps.iphone"
        )
        AppShortcut(
            intent: SendLinkToPhoneIntent(),
            phrases: [
                "Send a link to my phone in \(.applicationName)"
            ],
            shortTitle: "Send Link to Phone",
            systemImageName: "link"
        )
        AppShortcut(
            intent: SendFileToPhoneIntent(),
            phrases: [
                "Send a file to my phone in \(.applicationName)"
            ],
            shortTitle: "Send File to Phone",
            systemImageName: "doc.badge.arrow.up"
        )
        AppShortcut(
            intent: SetPhoneDNDIntent(),
            phrases: [
                "Set phone Do Not Disturb in \(.applicationName)"
            ],
            shortTitle: "Phone Do Not Disturb",
            systemImageName: "moon.fill"
        )
    }
}
