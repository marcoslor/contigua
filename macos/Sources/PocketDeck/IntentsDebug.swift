// `--debug-intent` (PD_TEST_HOOKS only): the e2e checks run an intent's
// perform path through the same bridge Shortcuts uses, and read one JSON line
// per intent from stderr (the harness captures it into app.log). Link URLs and
// file names never appear in a line: only counts, booleans and the dialog.
//
//   --debug-intent "battery [--phone ID_OR_NAME]"
//   --debug-intent "open-app PKG_OR_NAME [--phone …]"
//   --debug-intent "open-phone [--phone …]"
//   --debug-intent "send-link URL [--phone …]"
//   --debug-intent "send-file PATH [PATH …] [--phone …]"
//
// Results: {"intent":"battery","ok":true,"level":72,"live":false,
// "dialog":"Pixel: 72 % 14 min ago"} or {"intent":"…","ok":false,
// "error":"not_connected","message":"Your phone isn't connected."}.

import Foundation

enum DebugIntent: Equatable {
    case battery(phone: String?)
    case openApp(String, phone: String?)
    case openPhone(phone: String?)
    case sendLink(String, phone: String?)
    case sendFile([String], phone: String?)

    /// The battery answer needs no session, so it runs at launch.
    var isImmediate: Bool {
        if case .battery = self { return true }
        return false
    }

    var name: String {
        switch self {
        case .battery: return "battery"
        case .openApp: return "open-app"
        case .openPhone: return "open-phone"
        case .sendLink: return "send-link"
        case .sendFile: return "send-file"
        }
    }

    /// What a log line carries besides the outcome; names that are not secrets.
    var context: [String: Any] {
        switch self {
        case .openApp(let app, _): return ["args": app]
        case .sendFile(let paths, _): return ["files": paths.count]
        default: return [:]
        }
    }

    var phone: String? {
        switch self {
        case .battery(let phone), .openApp(_, let phone), .openPhone(let phone),
             .sendLink(_, let phone), .sendFile(_, let phone):
            return phone
        }
    }

    /// Parses one flag value; throws `IntentFailure`-like text for the log.
    static func parse(_ line: String) throws -> DebugIntent {
        var words = line.split(separator: " ").map(String.init)
        guard let name = words.first?.lowercased() else { throw DebugIntentError.empty }
        words.removeFirst()
        var phone: String?
        if let index = words.firstIndex(of: "--phone") {
            guard index + 1 < words.count else { throw DebugIntentError.usage("--phone needs a value") }
            phone = words[index + 1]
            words.removeSubrange(index...(index + 1))
        }
        switch name {
        case "battery":
            guard words.isEmpty else { throw DebugIntentError.usage("battery takes only --phone") }
            return .battery(phone: phone)
        case "open-phone":
            guard words.isEmpty else { throw DebugIntentError.usage("open-phone takes only --phone") }
            return .openPhone(phone: phone)
        case "open-app":
            guard words.count == 1 else { throw DebugIntentError.usage("open-app needs one APP") }
            return .openApp(words[0], phone: phone)
        case "send-link":
            guard words.count == 1 else { throw DebugIntentError.usage("send-link needs one URL") }
            return .sendLink(words[0], phone: phone)
        case "send-file":
            guard !words.isEmpty else { throw DebugIntentError.usage("send-file needs at least one PATH") }
            return .sendFile(words, phone: phone)
        default:
            throw DebugIntentError.usage("unknown intent \(name)")
        }
    }
}

enum DebugIntentError: Error, CustomStringConvertible {
    case empty
    case usage(String)

    var description: String {
        switch self {
        case .empty: return "usage: <intent> [args] [--phone ID_OR_NAME]"
        case .usage(let text): return text
        }
    }
}

@MainActor
enum IntentDebugLog {
    /// One line per intent, keys sorted so a check can match on the prefix.
    static func write(intent: String, ok: Bool, fields: [String: Any] = [:]) {
        var object: [String: Any] = ["intent": intent, "ok": ok]
        for (key, value) in fields { object[key] = value }
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              var text = String(data: data, encoding: .utf8) else { return }
        text += "\n"
        FileHandle.standardError.write(Data(text.utf8))
    }
}

@MainActor
enum IntentDebugRunner {
    /// Runs one parsed intent through IntentsBridge — the same calls the
    /// AppIntents make — and logs the outcome.
    static func run(_ intent: DebugIntent) {
        do {
            switch intent {
            case .battery(let requested):
                let phone = try IntentsBridge.resolve(requested)
                let answer = IntentsBridge.battery(for: phone)
                IntentDebugLog.write(intent: intent.name, ok: true,
                                     fields: ["dialog": "\(phone.name): \(answer.text)",
                                              "level": answer.level ?? -1,
                                              "live": answer.live,
                                              "text": answer.text])
            case .openApp(let app, let requested):
                let phone = try IntentsBridge.resolve(requested)
                let dialog = try IntentsBridge.openApp(app, on: phone)
                IntentDebugLog.write(intent: intent.name, ok: true,
                                     fields: intent.context.merging(["dialog": dialog]) { first, _ in first })
            case .openPhone(let requested):
                let phone = try IntentsBridge.resolve(requested)
                let dialog = try IntentsBridge.openPhoneScreen(on: phone)
                IntentDebugLog.write(intent: intent.name, ok: true, fields: ["dialog": dialog])
            case .sendLink(let url, let requested):
                let phone = try IntentsBridge.resolve(requested)
                let dialog = try IntentsBridge.sendLink(url, on: phone)
                IntentDebugLog.write(intent: intent.name, ok: true, fields: ["dialog": dialog])
            case .sendFile(let paths, let requested):
                let phone = try IntentsBridge.resolve(requested)
                let dialog = try IntentsBridge.sendFiles(paths, on: phone)
                IntentDebugLog.write(intent: intent.name, ok: true,
                                     fields: intent.context.merging(["dialog": dialog]) { first, _ in first })
            }
        } catch {
            let failure = error as? IntentFailure
            IntentDebugLog.write(intent: intent.name, ok: false,
                                 fields: intent.context.merging(
                                    ["error": failure?.code ?? "error",
                                     "message": failure?.message ?? "\(error)"]) { first, _ in first })
        }
    }
}
