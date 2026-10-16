// What this Mac remembers about the phones it has paired with, apart from the
// pinned certificates (`PhonePinStoreV2`) and reachability hints
// (`CachedDeviceStore`): name, model, last seen. The UI is driven by this list, so a missing or rejected key
// reads as "pair again" for a named phone, never as a fresh install.
//
// Everything lives in the profile's defaults and support folder (`Profile`).

import Foundation

/// The nickname a phone was given in Settings → Devices: per device id in the
/// profile's defaults, separate from the phone's own (reported) name. Empty
/// after normalizing means "no nickname": the phone's own name is used.
enum PhoneNicknames {
    static let key = "phoneNicknames"
    /// A nickname never shows longer than this; longer input is clamped.
    static let maxLength = 40

    /// Trimmed, whitespace collapsed away, at most `maxLength` characters.
    static func normalize(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let compact = trimmed.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .joined(separator: " ")
        return String(compact.prefix(maxLength))
    }

    static func read(from defaults: UserDefaults, deviceId: String) -> String {
        (defaults.dictionary(forKey: key) as? [String: String])?[deviceId] ?? ""
    }

    static func write(_ raw: String, for deviceId: String, to defaults: UserDefaults) {
        guard !deviceId.isEmpty else { return }
        var all = (defaults.dictionary(forKey: key) as? [String: String]) ?? [:]
        let name = normalize(raw)
        // No nickname stored is the same as an empty one: the phone's own name wins.
        if name.isEmpty { all.removeValue(forKey: deviceId) } else { all[deviceId] = name }
        if all.isEmpty { defaults.removeObject(forKey: key) } else { defaults.set(all, forKey: key) }
    }

    static func remove(for deviceId: String, from defaults: UserDefaults) {
        var all = (defaults.dictionary(forKey: key) as? [String: String]) ?? [:]
        guard all.removeValue(forKey: deviceId) != nil else { return }
        if all.isEmpty { defaults.removeObject(forKey: key) } else { defaults.set(all, forKey: key) }
    }
}

struct RememberedPhone: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var model: String
    var lastSeen: Date

    var ref: PhoneRef { PhoneRef(id: id, name: name, model: model) }
}

final class RememberedPhones {
    private let defaults: UserDefaults
    private static let phonesKey = "rememberedPhones"
    private static let activeKey = "activePhoneId"
    private static let welcomeKey = "welcomeSeen"

    init(defaults: UserDefaults) { self.defaults = defaults }

    convenience init(profile: Profile) { self.init(defaults: profile.defaults) }

    /// Most recently used first.
    var all: [RememberedPhone] {
        guard let data = defaults.data(forKey: Self.phonesKey),
              let phones = try? JSONDecoder().decode([RememberedPhone].self, from: data) else { return [] }
        return phones.sorted { $0.lastSeen > $1.lastSeen }
    }

    func phone(id: String) -> RememberedPhone? { all.first { $0.id == id } }

    /// The phone the Deck shows: the chosen one, else the most recently used.
    var active: RememberedPhone? {
        let phones = all
        if let id = defaults.string(forKey: Self.activeKey), let phone = phones.first(where: { $0.id == id }) {
            return phone
        }
        return phones.first
    }

    func setActive(id: String) { defaults.set(id, forKey: Self.activeKey) }

    func remember(_ ref: PhoneRef, at date: Date = Date(), makeActive: Bool = true) {
        guard !ref.id.isEmpty else { return }
        var phones = all.filter { $0.id != ref.id }
        let name = ref.name.isEmpty ? (phone(id: ref.id)?.name ?? "Phone") : ref.name
        phones.append(RememberedPhone(id: ref.id, name: name, model: ref.model, lastSeen: date))
        save(phones)
        if makeActive { setActive(id: ref.id) }
    }

    func touch(id: String, at date: Date = Date()) {
        var phones = all
        guard let index = phones.firstIndex(where: { $0.id == id }) else { return }
        phones[index].lastSeen = date
        save(phones)
    }

    func forget(id: String) {
        save(all.filter { $0.id != id })
        PhoneNicknames.remove(for: id, from: defaults)
        if defaults.string(forKey: Self.activeKey) == id { defaults.removeObject(forKey: Self.activeKey) }
    }

    func removeAll() {
        defaults.removeObject(forKey: Self.phonesKey)
        defaults.removeObject(forKey: Self.activeKey)
    }

    var welcomeSeen: Bool {
        get { defaults.bool(forKey: Self.welcomeKey) }
        set { defaults.set(newValue, forKey: Self.welcomeKey) }
    }

    private func save(_ phones: [RememberedPhone]) {
        if let data = try? JSONEncoder().encode(phones) { defaults.set(data, forKey: Self.phonesKey) }
    }
}

// MARK: The one phone name

extension RememberedPhones {
    /// THE name this Mac shows for a phone, everywhere it is named (Deck title,
    /// menu bar, banners, notifications, Spotlight, window and Dock titles):
    /// the nickname from Settings → Devices when one is set, else the phone's
    /// own name (ref's reported one, or the remembered one), else `fallback`.
    func displayName(for phone: PhoneRef, fallback: String = "Phone") -> String {
        let nickname = PhoneNicknames.read(from: defaults, deviceId: phone.id)
        if !nickname.isEmpty { return nickname }
        if !phone.name.isEmpty { return phone.name }
        if let remembered = self.phone(id: phone.id), !remembered.name.isEmpty { return remembered.name }
        return fallback
    }
}

/// The last app list of each phone, so the grid is there before the phone answers.
final class AppsCache {
    private let directory: URL

    init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    convenience init(profile: Profile) {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches")
        self.init(directory: base.appendingPathComponent(profile.supportDirectoryName, isDirectory: true))
    }

    private func url(_ deviceId: String) -> URL {
        let safe = deviceId.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        return directory.appendingPathComponent("apps-\(safe).json")
    }

    func store(_ apps: [AppInfo], deviceId: String) {
        let rows = apps.map { ["pkg": $0.pkg, "label": $0.label, "activity": $0.activity ?? ""] }
        if let data = try? JSONSerialization.data(withJSONObject: rows) { try? data.write(to: url(deviceId)) }
    }

    func load(deviceId: String) -> [AppInfo] {
        guard let data = try? Data(contentsOf: url(deviceId)),
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: String]] else { return [] }
        return rows.compactMap { row in
            var json: [String: Any] = row
            if row["activity"]?.isEmpty == true { json["activity"] = nil }
            return AppInfo(json: json)
        }
    }

    func remove(deviceId: String) { try? FileManager.default.removeItem(at: url(deviceId)) }
}
