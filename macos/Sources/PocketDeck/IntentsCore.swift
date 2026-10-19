// The decisions behind the App Intents (docs/design/intents.md): which phone an
// intent acts on, which app it names, what the battery answer reads like, and
// whether a link or a file is one we may send. No AppIntents import on purpose:
// the e2e debug hook and the unit tests exercise the same core the intents do.

import Foundation

/// A phone as an intent sees it: the remembered list plus the live id.
struct IntentPhone: Equatable, Hashable {
    var id: String
    var name: String
    var model: String
}

/// What resolving a requested phone gave: the picked phone, or why there is none.
enum IntentPhoneChoice: Equatable {
    case phone(IntentPhone)
    /// A name matched several phones; the intent says so instead of guessing.
    case ambiguous([IntentPhone])
    /// No phone is paired.
    case missing
    /// A name was given but no paired phone has it.
    case unknown(String)
    /// Several phones are paired and none is connected: the person must name one.
    case needPhone([IntentPhone])
}

enum IntentPhoneResolver {
    /// The phone an intent acts on. A name (id or display name) wins; without
    /// one the connected phone does, then the only paired phone. Several paired
    /// phones with none connected ask for a name rather than acting on a guess.
    static func resolve(requested: String?, phones: [IntentPhone], connectedId: String?) -> IntentPhoneChoice {
        if let raw = requested?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            if let byId = phones.first(where: { $0.id == raw }) { return .phone(byId) }
            let folded = fold(raw)
            let exact = phones.filter { fold($0.name) == folded }
            if exact.count == 1 { return .phone(exact[0]) }
            if exact.count > 1 { return .ambiguous(exact) }
            let prefixed = phones.filter { fold($0.name).hasPrefix(folded) }
            if prefixed.count == 1 { return .phone(prefixed[0]) }
            if prefixed.count > 1 { return .ambiguous(prefixed) }
            return .unknown(raw)
        }
        guard !phones.isEmpty else { return .missing }
        if let connectedId, let connected = phones.first(where: { $0.id == connectedId }) {
            return .phone(connected)
        }
        if phones.count == 1 { return .phone(phones[0]) }
        return .needPhone(phones)
    }

    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// What naming an app gave: one app, several equally good matches, or none.
enum IntentAppChoice: Equatable {
    case app(AppInfo)
    case ambiguous([AppInfo])
    case none
}

/// The phone's app list, the same one Spotlight indexes and the Deck caches.
enum IntentAppCatalog {
    /// The `EntityStringQuery` behind `PhoneApp`: blank lists every app (label
    /// order), anything else matches the label or the package, label hits first.
    static func search(_ query: String, in apps: [AppInfo], limit: Int = 20) -> [AppInfo] {
        let folded = IntentPhoneResolver.fold(query)
        let sorted = apps.sorted { ($0.label.lowercased(), $0.pkg) < ($1.label.lowercased(), $1.pkg) }
        guard !folded.isEmpty else { return Array(sorted.prefix(limit)) }
        let labelHits = sorted.filter { IntentPhoneResolver.fold($0.label).contains(folded) }
        let pkgHits = sorted.filter {
            !labelHits.contains($0) && IntentPhoneResolver.fold($0.pkg).contains(folded)
        }
        return Array((labelHits + pkgHits).prefix(limit))
    }

    /// An app named exactly, else by a unique name/package prefix. A package
    /// name always wins outright: it cannot mean two apps.
    static func app(named query: String, in apps: [AppInfo]) -> IntentAppChoice {
        let raw = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return .none }
        if let byPkg = apps.first(where: { $0.pkg == raw }) { return .app(byPkg) }
        let folded = IntentPhoneResolver.fold(raw)
        let exact = apps.filter { IntentPhoneResolver.fold($0.label) == folded }
        if exact.count == 1 { return .app(exact[0]) }
        if exact.count > 1 { return .ambiguous(exact.sorted { $0.pkg < $1.pkg }) }
        let prefixed = apps.filter {
            IntentPhoneResolver.fold($0.label).hasPrefix(folded) || IntentPhoneResolver.fold($0.pkg).hasPrefix(folded)
        }
        if prefixed.count == 1 { return .app(prefixed[0]) }
        if prefixed.count > 1 { return .ambiguous(prefixed.sorted { $0.pkg < $1.pkg }) }
        return .none
    }
}

/// The last battery report a phone sent, kept across disconnects (the intent
/// answers from it instead of waking the phone).
struct BatteryReading: Codable, Equatable {
    var level: Int
    var charging: Bool
    var at: Date
}

struct BatteryAnswer: Equatable {
    /// nil when this phone never reported a level.
    var level: Int?
    var charging: Bool
    var live: Bool
    /// "72 %, charging", "72 % 14 min ago" or "Battery unknown."
    var text: String
}

enum IntentBattery {
    /// `live` is the connected phone's current `state` (nil when it is away).
    static func answer(live: (level: Int, charging: Bool)?, last: BatteryReading?, now: Date) -> BatteryAnswer {
        if let live {
            return BatteryAnswer(level: live.level, charging: live.charging, live: true,
                                 text: live.charging ? "\(live.level) %, charging" : "\(live.level) %")
        }
        guard let last else {
            return BatteryAnswer(level: nil, charging: false, live: false, text: "Battery unknown.")
        }
        let age = max(0, now.timeIntervalSince(last.at))
        return BatteryAnswer(level: last.level, charging: last.charging, live: false,
                             text: "\(last.level) % \(ageText(age))")
    }

    /// "just now", "14 min ago", "3 h ago", "2 days ago".
    static func ageText(_ seconds: TimeInterval) -> String {
        if seconds < 60 { return "just now" }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(minutes) min ago" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours) h ago" }
        let days = hours / 24
        return days == 1 ? "1 day ago" : "\(days) days ago"
    }
}

/// The last battery per phone, in the profile's defaults (never the phone's).
final class BatteryMemory {
    static let key = "intentBattery"

    private let defaults: UserDefaults

    init(defaults: UserDefaults) { self.defaults = defaults }

    convenience init(profile: Profile) { self.init(defaults: profile.defaults) }

    private func all() -> [String: BatteryReading] {
        guard let data = defaults.data(forKey: Self.key),
              let rows = try? JSONDecoder().decode([String: BatteryReading].self, from: data) else { return [:] }
        return rows
    }

    func reading(deviceId: String) -> BatteryReading? { all()[deviceId] }

    /// Overwrites with the newest report; a level outside 0...100 is dropped
    /// (the phone's own numbers are the only ones this trusts).
    func record(deviceId: String, level: Int, charging: Bool, at: Date = Date()) {
        guard !deviceId.isEmpty, (0...100).contains(level) else { return }
        var rows = all()
        rows[deviceId] = BatteryReading(level: level, charging: charging, at: at)
        if let data = try? JSONEncoder().encode(rows) { defaults.set(data, forKey: Self.key) }
    }

    func remove(deviceId: String) {
        var rows = all()
        guard rows.removeValue(forKey: deviceId) != nil else { return }
        if let data = try? JSONEncoder().encode(rows) { defaults.set(data, forKey: Self.key) }
    }

    func removeAll() { defaults.removeObject(forKey: Self.key) }
}

/// Why an intent cannot do what was asked: one human sentence each, never a
/// crash and never a silent no-op.
enum IntentFailure: Error, Equatable, LocalizedError {
    case noPhone
    case unknownPhone(String)
    case choosePhone([String])
    case phoneNotConnected
    case phoneNotReady
    case appNotFound(String)
    case severalApps(String)
    case badLink
    case fileMissing(String)
    case fileUnreadable(String)

    var message: String {
        switch self {
        case .noPhone:
            return "Pair a phone first, then ask again."
        case .unknownPhone(let name):
            return "No paired phone is called “\(name)”."
        case .choosePhone(let names):
            return "Your phones: \(names.joined(separator: ", ")). Say which one."
        case .phoneNotConnected:
            return "Your phone isn't connected."
        case .phoneNotReady:
            return "Your phone is connecting; try again in a moment."
        case .appNotFound(let name):
            return "No phone app matches “\(name)”."
        case .severalApps(let name):
            return "Several phone apps match “\(name)”; say the full name."
        case .badLink:
            return "Only http, https, geo, tel and mailto links can be sent to the phone."
        case .fileMissing(let name):
            return "“\(name)” isn't there any more."
        case .fileUnreadable(let name):
            return "“\(name)” can't be read."
        }
    }

    /// The stable name a log line or a check matches on.
    var code: String {
        switch self {
        case .noPhone: return "no_phone"
        case .unknownPhone: return "unknown_phone"
        case .choosePhone: return "choose_phone"
        case .phoneNotConnected: return "not_connected"
        case .phoneNotReady: return "not_ready"
        case .appNotFound: return "app_not_found"
        case .severalApps: return "several_apps"
        case .badLink: return "bad_link"
        case .fileMissing: return "file_missing"
        case .fileUnreadable: return "file_unreadable"
        }
    }

    var errorDescription: String? { message }
}

enum IntentLink {
    /// The trimmed URL when the phone may open it (the same policy as the
    /// Share extension and the phone itself), else `IntentFailure.badLink`.
    static func validate(_ raw: String) throws -> String {
        guard let url = LinkPolicy.validate(raw) else { throw IntentFailure.badLink }
        return url
    }
}

enum IntentFilePolicy {
    /// One file an intent may drop: it must exist, be readable, be a regular
    /// file and fit the drop cap. The drop itself goes through FileDrop.
    static func validate(_ path: String) throws -> URL {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        let name = url.lastPathComponent
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw IntentFailure.fileMissing(name)
        }
        guard !isDirectory.boolValue, manager.isReadableFile(atPath: url.path) else {
            throw IntentFailure.fileUnreadable(name)
        }
        let size = ((try? manager.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.intValue ?? 0
        guard size > 0, size <= DropLimits.maxBytes else { throw IntentFailure.fileUnreadable(name) }
        return url
    }
}
