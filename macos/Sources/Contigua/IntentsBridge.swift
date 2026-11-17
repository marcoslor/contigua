// The bridge between the App Intents and the running app (docs/design/intents.md).
// The intents and the `--debug-intent` hook call the same methods, so the e2e
// checks cover exactly what Shortcuts runs. Everything is main-actor: the
// controller owns the windows and the session.

import Foundation

@MainActor
enum IntentsBridge {
    private static var controller: ConnectionController { AppEnvironment.shared.controller }

    /// The paired phones, named as the Deck names them (nickname first).
    static func phones(in given: ConnectionController? = nil) -> [IntentPhone] {
        let controller = given ?? self.controller
        // The store itself, not its published copy: a phone remembered this
        // turn is already one an intent or an MCP call can name.
        return controller.remembered.all.map { phone in
            IntentPhone(id: phone.id, name: controller.displayName(for: phone.ref), model: phone.model)
        }
    }

    /// The connected phone, only while the session is online.
    static func connectedId(in given: ConnectionController? = nil) -> String? {
        let link = (given ?? controller).link
        return link.isOnline ? link.phone?.id : nil
    }

    /// `given`: the controller to ask; the app's own when nil (an MCP host
    /// passes its own, so a test never reaches the app's).
    static func resolve(_ requested: String?, in given: ConnectionController? = nil) throws -> IntentPhone {
        switch IntentPhoneResolver.resolve(requested: requested, phones: phones(in: given),
                                           connectedId: connectedId(in: given)) {
        case .phone(let phone):
            return phone
        case .ambiguous(let phones):
            throw IntentFailure.choosePhone(phones.map(\.name))
        case .needPhone(let phones):
            throw IntentFailure.choosePhone(phones.map(\.name))
        case .unknown(let name):
            throw IntentFailure.unknownPhone(name)
        case .missing:
            throw IntentFailure.noPhone
        }
    }

    /// The app list the Deck shows for that phone: live when it is connected,
    /// the cached one otherwise — the same list Spotlight indexes.
    static func apps(for phone: IntentPhone, in given: ConnectionController? = nil) -> [AppInfo] {
        let controller = given ?? self.controller
        if controller.link.isOnline, controller.link.phone?.id == phone.id, controller.appsLoaded {
            return controller.apps
        }
        return controller.appsCache.load(deviceId: phone.id)
    }

    /// Live `state` while connected, else the last report with its age.
    static func battery(for phone: IntentPhone) -> BatteryAnswer {
        let controller = self.controller
        var live: (level: Int, charging: Bool)?
        if controller.link.isOnline, controller.link.phone?.id == phone.id,
           let status = controller.status, let level = status.battery {
            live = (level, status.charging)
        }
        return IntentBattery.answer(live: live, last: controller.batteryMemory.reading(deviceId: phone.id),
                                    now: Date())
    }

    static func openApp(_ pkg: String, on phone: IntentPhone, newWindow: Bool = false) throws -> String {
        guard case .app(let app) = IntentAppCatalog.app(named: pkg, in: apps(for: phone)) else {
            throw IntentFailure.appNotFound(label(for: pkg, on: phone))
        }
        controller.intentsOpenApp(app.pkg, on: phone.id, newWindow: newWindow)
        if controller.link.isOnline, controller.link.phone?.id == phone.id {
            return "Opened \(app.label) on \(phone.name)."
        }
        return "Connecting to \(phone.name); \(app.label) opens when it's ready."
    }

    static func openPhoneScreen(on phone: IntentPhone) throws -> String {
        controller.intentsOpenPhoneWindow(on: phone.id)
        if controller.link.isOnline, controller.link.phone?.id == phone.id {
            return "Opened \(phone.name)."
        }
        return "Connecting to \(phone.name)."
    }

    static func sendLink(_ raw: String, on phone: IntentPhone) throws -> String {
        let url = try IntentLink.validate(raw)
        controller.intentsSendLink(url, on: phone.id)
        if controller.link.isOnline, controller.link.phone?.id == phone.id {
            return "Sent the link to \(phone.name)."
        }
        return "Connecting to \(phone.name); the link opens when it's ready."
    }

    /// MCP-43: an MCP link opens on the live link path at once and names the
    /// window `WindowManager.openLink` made; a refused URL opens nothing.
    static func openLinkWindow(_ raw: String, controller: ConnectionController) throws -> UInt32 {
        let url = try IntentLink.validate(raw)
        return controller.windows.openLink(url).stream
    }

    /// Files go through the same drop path as a Finder drag (Download/Contigua).
    static func sendFiles(_ paths: [String], on phone: IntentPhone) throws -> String {
        guard !paths.isEmpty else { throw IntentFailure.fileMissing("file") }
        let files = try paths.map { try IntentFilePolicy.validate($0) }
        controller.intentsSendFiles(files, on: phone.id)
        let noun = files.count == 1 ? "file" : "\(files.count) files"
        if controller.link.isOnline, controller.link.phone?.id == phone.id {
            return "Sending \(noun) to \(phone.name)."
        }
        return "Connecting to \(phone.name); \(noun) go when it's ready."
    }

    private static func label(for pkg: String, on phone: IntentPhone) -> String {
        apps(for: phone).first { $0.pkg == pkg }?.label ?? pkg
    }

    /// `phone.ring` needs the live session: the phone rings itself, so there is
    /// nothing to queue for a phone that is still connecting.
    static func ring(_ phone: IntentPhone, seconds: Int) throws -> String {
        let controller = self.controller
        guard controller.link.isOnline, controller.link.phone?.id == phone.id else {
            throw IntentFailure.phoneNotConnected
        }
        controller.ringPhone(seconds: seconds)
        return "Ringing \(phone.name)."
    }

    /// Manual DND (docs/design/focus.md): live only, and only when the phone's
    /// `state` carries `dnd`. The phone's own report updates the menu checkmark.
    static func setPhoneDnd(on: Bool, mode: PhoneDndMode, on phone: IntentPhone) throws -> String {
        let controller = self.controller
        guard controller.link.isOnline, controller.link.phone?.id == phone.id else {
            throw IntentFailure.phoneNotConnected
        }
        guard controller.phoneDnd != nil else { throw IntentFailure.phoneNoDnd }
        let command = FocusReconciler.intentCommand(on: on, mode: mode)
        controller.setPhoneDnd(command)
        return on ? "Phone Do Not Disturb is on." : "Phone Do Not Disturb is off."
    }
}
