// The automation server's failures (docs/design/mcp.md "Errors", MCP-6): one
// closed code a program switches on, one sentence that names the next step for
// a model, and the code's extra fields. Every throw a tool meets maps here.

import Foundation

/// MCP-6's closed set. A code is never added without a spec row.
enum MCPErrorCode: String, CaseIterable {
    case noPhone = "no_phone"
    case phoneOffline = "phone_offline"
    case noWindow = "no_window"
    case notReady = "not_ready"
    case staleRef = "stale_ref"
    case offScreen = "off_screen"
    case covered
    case noField = "no_field"
    case notFound = "not_found"
    case ambiguous
    case tooManyWindows = "too_many_windows"
    case badURL = "bad_url"
    case badFile = "bad_file"
    case noFrame = "no_frame"
    case notSupported = "not_supported"
    case timeout
    case failed
}

struct MCPToolError: Error {
    let code: MCPErrorCode
    let message: String
    /// The code's extra fields (design/mcp.md's table), beside code and message.
    let extra: [String: Any]

    init(_ code: MCPErrorCode, _ message: String, _ extra: [String: Any] = [:]) {
        self.code = code
        self.message = message
        self.extra = extra
    }

    /// `{"error": {"code", "message", …extra}}`.
    var object: [String: Any] {
        var error = extra
        error["code"] = code.rawValue
        error["message"] = message
        return ["error": error]
    }
}

extension MCPToolError: Equatable {
    static func == (lhs: MCPToolError, rhs: MCPToolError) -> Bool {
        MCPJSON.string(lhs.object) == MCPJSON.string(rhs.object)
    }
}

// MARK: - The sentences

extension MCPToolError {
    static func noWindow(_ id: Int) -> MCPToolError {
        MCPToolError(.noWindow, "No window \(id). Call list_windows to see what is open.", ["window": id])
    }

    static func phoneOffline(_ phone: String?) -> MCPToolError {
        MCPToolError(.phoneOffline,
                     "\(phone ?? "The phone") is not connected. Wait until phone_status says connected, then try again.")
    }

    static let noPhone = MCPToolError(
        .noPhone, "No phone is paired with Contigua. Pair one in Contigua's Settings, then try again.")

    /// Phones are paired, but none is the one in use (several, none connected).
    static func noPhoneInUse(paired: Int) -> MCPToolError {
        MCPToolError(.noPhone,
                     "No phone is in use: \(paired) phones are paired and none is connected. Connect one in Contigua, then call phone_status.")
    }

    static let appsNotReady = MCPToolError(
        .notReady, "The phone's app list has not arrived yet; try again in a few seconds.")

    static func notFound(_ query: String) -> MCPToolError {
        MCPToolError(.notFound, "No app on the phone matches \"\(query)\". Call list_apps with a query to find it.")
    }

    static func ambiguous(_ query: String, matches: [AppInfo]) -> MCPToolError {
        MCPToolError(.ambiguous, "Several apps match \"\(query)\". Pass one of these packages as app.",
                     ["matches": matches.map { ["label": $0.label, "package": $0.pkg] }])
    }

    static let badURL = MCPToolError(
        .badURL, "That link can't be opened: only http, https, geo, tel and mailto links up to 8 KiB are allowed.")

    static let badFile = MCPToolError(
        .badFile, "That file can't be sent: it must be an absolute path to a readable regular file of at most \(DropLimits.maxMegabytes) MB.")

    /// `state` is the window's state word (live, offline, …).
    static func noFrame(window id: Int, state: String) -> MCPToolError {
        MCPToolError(.noFrame, "Window \(id) is \(state): no new picture arrived in 2 s. Use ui_tree, or try again.",
                     ["window": id, "state": state])
    }

    static func timeout(_ phone: String?) -> MCPToolError {
        MCPToolError(.timeout,
                     "\(phone ?? "The phone") did not answer in time. Try again; if it keeps failing, check phone_status.")
    }

    static func failed(_ sentence: String, window: Int? = nil) -> MCPToolError {
        MCPToolError(.failed, sentence, window.map { ["window": $0] } ?? [:])
    }
}

// MARK: - Mapping

extension MCPToolError {
    /// Any error a tool threw, as one closed code. `phone` fills a sentence's
    /// blank; it is on-screen content and stays in the result (MCP-14).
    static func mapping(_ error: Error, phone: String?) -> MCPToolError {
        switch error {
        case let failure as MCPToolError:
            return failure
        case let failure as IntentFailure:
            switch failure {
            case .noPhone, .unknownPhone: return noPhone
            case .choosePhone(let names): return noPhoneInUse(paired: names.count)
            case .phoneNotConnected, .phoneNotReady: return phoneOffline(phone)
            case .phoneNoDnd: return MCPToolError(.notSupported, failure.message)
            case .appNotFound(let query): return notFound(query)
            case .severalApps(let query):
                // This path has no list to give (open_app's own chooseApp
                // does); point at the call that lists them.
                return MCPToolError(.ambiguous,
                    "Several apps match \"\(query)\". Call list_apps with a query to see them.", ["matches": [Any]()])
            case .badLink: return badURL
            case .fileMissing, .fileUnreadable: return badFile
            }
        case let failure as UITreeError:
            switch failure {
            case .notConnected: return phoneOffline(phone)
            case .timedOut: return timeout(phone)
            }
        default:
            return failed("Contigua could not do that. Try again; if it keeps failing, check phone_status.")
        }
    }

    /// MCP-70: the phone's `ui.tree` failure codes.
    static func uiTreeFailed(code: String?, message: String?, window id: Int, phone: String?) -> MCPToolError {
        switch code {
        case "no_window":
            return noWindow(id)
        case "no_display":
            // The Mac has the window (requireWindow ran first); its display
            // has no accessibility window yet: an app still opening.
            return MCPToolError(.notReady,
                                "Window \(id) has nothing on screen to read yet: its app may still be opening. Try again in a moment.",
                                ["window": id])
        case "not_available", "no_a11y":
            return MCPToolError(.notSupported,
                                "\(phone ?? "The phone") can't read this window's accessibility tree.",
                                ["window": id])
        default:
            return failed(message ?? "The phone could not read that display's accessibility tree.", window: id)
        }
    }

    /// #162's ref refusals (WIN-79): every refusal but the off-screen one is
    /// `stale_ref`, with #162's sentence kept. nil when the ref resolves.
    static func tapRefusal(_ resolution: UITreeResolution, ref: String, window id: Int) -> MCPToolError? {
        switch resolution {
        case .placed(_, let placed):
            guard placed.point == nil || placed.off else { return nil }
            return MCPToolError(.offScreen, UITreeRefusal.offScreen(ref), ["window": id, "ref": ref])
        case .stale(let stale, let snapshot, let latest):
            return MCPToolError(.staleRef, UITreeRefusal.stale(ref: stale, snapshot: snapshot, latest: latest),
                                ["window": id, "ref": ref, "snapshot": latest])
        case .noTree:
            return MCPToolError(.staleRef, UITreeRefusal.noTree(ref), ["window": id, "ref": ref])
        }
    }
}

// MARK: - JSON

/// JSON text with sorted keys and shortest round-trip numbers: a 0.651 prints
/// as 0.651, never as 17 digits (the `UITree.encoded` rule, WIN-79).
enum MCPJSON {
    static func string(_ value: Any) -> String {
        var out = ""
        write(value, into: &out)
        return out
    }

    static func data(_ value: Any) -> Data { Data(string(value).utf8) }

    private static func write(_ value: Any, into out: inout String) {
        switch value {
        case let dictionary as [String: Any]:
            out += "{"
            for (index, key) in dictionary.keys.sorted().enumerated() {
                if index > 0 { out += "," }
                writeString(key, into: &out)
                out += ":"
                write(dictionary[key] as Any, into: &out)
            }
            out += "}"
        case let array as [Any]:
            out += "["
            for (index, element) in array.enumerated() {
                if index > 0 { out += "," }
                write(element, into: &out)
            }
            out += "]"
        case let string as String:
            writeString(string, into: &out)
        case is NSNull:
            out += "null"
        case let number as NSNumber:
            if MCPValue.isBool(number) {
                out += number.boolValue ? "true" : "false"
            } else if CFNumberIsFloatType(number) {
                let double = number.doubleValue
                guard double.isFinite else { out += "null"; return }
                if double == double.rounded(), abs(double) < 1e15 {
                    out += String(Int64(double))
                } else {
                    out += "\(double)"
                }
            } else {
                out += number.stringValue
            }
        default:
            // A nil that reached a dictionary as Any, or a value with no JSON form.
            let mirror = Mirror(reflecting: value)
            if mirror.displayStyle == .optional {
                if let wrapped = mirror.children.first?.value {
                    write(wrapped, into: &out)
                } else {
                    out += "null"
                }
            } else {
                // A Date, a struct or another type with no JSON form reached an
                // answer: a schema's non-null field would silently become null.
                assertionFailure("MCPJSON: no JSON form for \(type(of: value))")
                out += "null"
            }
        }
    }

    private static func writeString(_ string: String, into out: inout String) {
        out += "\""
        for scalar in string.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{8}": out += "\\b"
            case "\u{c}": out += "\\f"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out += "\""
    }
}
