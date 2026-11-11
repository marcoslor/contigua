// Control Center controls (docs/design/controls.md): the one JSON snapshot the
// app writes for the controls extension, and the one request line the extension
// sends back over the group socket. No AppKit, no WidgetKit: the app, the
// extension and the unit tests compile this same file (bundle.sh passes it to
// swiftc for Controls.appex).

import Foundation

/// The phone's ringer mode, named as `phone.ringer` and `state.ringer` do.
enum PhoneRingerMode: String, CaseIterable, Equatable {
    case normal
    case vibrate
    case silent

    /// The panel menu's word for the mode (the wire name is `normal`).
    var displayName: String {
        switch self {
        case .normal: return "Ring"
        case .vibrate: return "Vibrate"
        case .silent: return "Silent"
        }
    }

    /// The mode a cycling control moves to next.
    var next: PhoneRingerMode {
        switch self {
        case .normal: return .vibrate
        case .vibrate: return .silent
        case .silent: return .normal
        }
    }
}

/// What the controls need to draw themselves, rewritten by the app whenever one
/// of these values changes. `dnd` and `ringer` are nil when the phone does not
/// report them (an old phone), which is what greys a control out.
struct ControlsSnapshot: Codable, Equatable {
    var version = 1
    var connected = false
    var phone: String?
    /// The `state.dnd` wire name, nil when the phone does not report it.
    var dnd: String?
    /// The `state.ringer` wire name, nil when the phone cannot set it.
    var ringer: String?
    var ringing = false
    /// Epoch seconds of the last real change; only for logs and the check.
    var updated: TimeInterval = 0

    var dndOn: Bool { (dnd ?? "off") != "off" }
    var ringerMode: PhoneRingerMode? { ringer.flatMap(PhoneRingerMode.init(rawValue:)) }


    static let fileName = "controls.json"
    /// A snapshot is a few hundred bytes; anything larger is not one of ours.
    static let maxBytes = 16 * 1024

    /// Decodes a snapshot, refusing one that is not ours or is oversized.
    static func decode(_ data: Data) -> ControlsSnapshot? {
        guard !data.isEmpty, data.count <= maxBytes else { return nil }
        return try? JSONDecoder().decode(ControlsSnapshot.self, from: data)
    }

    func encoded() -> Data? {
        try? JSONEncoder().encode(self)
    }

    /// Atomic and private: written to a sibling temp file (0600 from the first
    /// byte), then renamed over the old one, so a control never reads a half
    /// written snapshot. The caller owns the directory (0700).
    @discardableResult
    func write(to url: URL) -> Bool {
        guard let data = encoded() else { return false }
        let directory = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        let temp = directory.appendingPathComponent(".\(url.lastPathComponent).\(getpid()).tmp")
        do {
            try data.write(to: temp, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temp.path)
            if FileManager.default.fileExists(atPath: url.path), (try? FileManager.default.replaceItemAt(url, withItemAt: temp)) != nil {
                return true
            }
            try? FileManager.default.removeItem(at: url)
            try FileManager.default.moveItem(at: temp, to: url)
            return true
        } catch {
            try? FileManager.default.removeItem(at: temp)
            return false
        }
    }

    static func read(from url: URL) -> ControlsSnapshot? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return decode(data)
    }
}

/// One request from a control. The extension sends it as one JSON line; the app
/// validates it again (the extension is not trusted with the session).
enum ControlsRequest: Equatable {
    case dnd(Bool)
    case ring
    case ringStop
    case ringer(PhoneRingerMode)
    case open

    /// The wire names, also used by the app's debug replies.
    var command: String {
        switch self {
        case .dnd(let on): return on ? "dnd on" : "dnd off"
        case .ring: return "ring"
        case .ringStop: return "ring.stop"
        case .ringer(let mode): return "ringer \(mode.rawValue)"
        case .open: return "open"
        }
    }

    /// nil for a line that is not a well-formed request (unknown `t`, missing or
    /// mistyped fields, more than 4 KiB).
    static func parse(_ data: Data) -> ControlsRequest? {
        guard !data.isEmpty, data.count <= 4096,
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let kind = object["t"] as? String else { return nil }
        switch kind {
        case "dnd":
            guard let on = object["on"] as? Bool else { return nil }
            return .dnd(on)
        case "ring":
            return .ring
        case "ring.stop":
            return .ringStop
        case "ringer":
            guard let raw = object["mode"] as? String,
                  let mode = PhoneRingerMode(rawValue: raw) else { return nil }
            return .ringer(mode)
        case "open":
            return .open
        default:
            return nil
        }
    }

    func encoded() -> Data? {
        var object: [String: Any] = [:]
        switch self {
        case .dnd(let on):
            object["t"] = "dnd"
            object["on"] = on
        case .ring:
            object["t"] = "ring"
        case .ringStop:
            object["t"] = "ring.stop"
        case .ringer(let mode):
            object["t"] = "ringer"
            object["mode"] = mode.rawValue
        case .open:
            object["t"] = "open"
        }
        return try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
}

/// What the app answers one request with. `error` is a stable code a check can
/// match on; `message` is the sentence a control shows when it can show one.
struct ControlsReply: Codable, Equatable {
    var ok: Bool
    var error: String?
    var message: String?

    static let ok = ControlsReply(ok: true)
    static func failure(_ code: String, _ message: String) -> ControlsReply {
        ControlsReply(ok: false, error: code, message: message)
    }

    static let notConnected = failure("not_connected", "Your phone isn't connected.")
    static let noDnd = failure("no_dnd", "This phone can't set Do Not Disturb; update Contigua on the phone.")
    static let noRinger = failure("no_ringer", "This phone can't set its ringer; update Contigua on the phone.")
    static let dndOn = failure("dnd_on", "Turn Do Not Disturb off first; the phone's ringer can't change while it is on.")
    static let badRequest = failure("bad_request", "That control request isn't valid.")

    static func decode(_ data: Data) -> ControlsReply? {
        guard data.count <= 4096 else { return nil }
        return try? JSONDecoder().decode(ControlsReply.self, from: data)
    }

    func encoded() -> Data? { try? JSONEncoder().encode(self) }

    /// One wire line (the socket protocol is newline-delimited).
    func line() -> Data? {
        guard let data = encoded() else { return nil }
        return data + Data("\n".utf8)
    }
}

/// Where the app and the extension meet: the App Group container (the real
/// bundle) or the `--controls-dir` folder (e2e and the VM spike).
enum ControlsPaths {
    /// This epic's own group, never the File Provider experiment's.
    static let groupID = "group.app.contigua.mac.controls"
    static let socketName = "controls.sock"

    /// The folder the app writes into, or nil when the group is unavailable.
    static func groupDirectory() -> URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID)
    }

    static func snapshotURL(in directory: URL) -> URL {
        directory.appendingPathComponent(ControlsSnapshot.fileName)
    }

    static func socketPath(in directory: URL) -> String {
        directory.appendingPathComponent(socketName).path
    }

    /// The kinds Control Center is told to reload after a snapshot change.
    static let kinds = [
        "app.contigua.mac.controls.dnd",
        "app.contigua.mac.controls.ring",
        "app.contigua.mac.controls.ringer",
        "app.contigua.mac.controls.open",
    ]
}
