// The windows ledger (docs/design/mcp.md "Windows and who opened them",
// MCP-50…53, MCP-102): each open window's kind, opener and opening time, and
// the last 16 closes of the last 10 minutes with their reason and closer.
// Pure: the caller passes the time; `openedBy`/`closedBy` are answered relative
// to the asking connection.

import Foundation

struct MCPWindowLedger {
    enum Kind: String { case app, link, handoff, mirror }

    /// Who opened a window. A connection keeps its id after it ends (MCP-102).
    enum Opener: Equatable { case client(MCPClientID), person, app }

    /// Who closed a window from the Mac.
    enum MacCloser: Equatable { case client(MCPClientID), person }

    /// Why a window closed, as the Mac learns it.
    enum Cause: Equatable {
        /// The phone's `window.closed` reason (the wire's token).
        case phone(String)
        /// The Mac's own `window.close`: ⌘W, the close light, Close All, or a
        /// connection's `close_window`.
        case mac(MacCloser)
        case openFailed
        case phoneSwitched
    }

    /// A close as one connection sees it (MCP-53).
    struct Closed: Equatable {
        let reason: String
        let closedBy: String
        let closedAgoMs: Int

        var object: [String: Any] {
            ["reason": reason, "closedBy": closedBy, "closedAgoMs": closedAgoMs]
        }
    }

    private struct Open {
        let kind: Kind
        var package: String?
        let opener: Opener
        let at: TimeInterval
    }

    private struct Close {
        let id: UInt32
        let kind: Kind
        let package: String?
        let reason: String
        let closer: Closer
        let at: TimeInterval
    }

    private enum Closer: Equatable { case client(MCPClientID), person, phone }

    static let keep = 16
    static let keepSeconds: TimeInterval = 600

    private var open: [UInt32: Open] = [:]
    private var closes: [Close] = []

    /// An open or a raise: a raise keeps the first opener (MCP-51).
    mutating func opened(_ id: UInt32, kind: Kind, package: String?, by opener: Opener, now: TimeInterval) {
        guard open[id] == nil else { return }
        open[id] = Open(kind: kind, package: package, opener: opener, at: now)
    }

    /// MCP-52: a window learns the package that displays it after it opened
    /// (`window.title`), and its close record must keep that one.
    mutating func setPackage(_ package: String, for id: UInt32) {
        guard !package.isEmpty else { return }
        open[id]?.package = package
    }

    mutating func closed(_ id: UInt32, cause: Cause, now: TimeInterval) {
        let entry = open.removeValue(forKey: id)
        guard entry != nil || !closes.contains(where: { $0.id == id }) else { return }
        let (reason, closer) = Self.map(cause)
        closes.append(Close(id: id, kind: entry?.kind ?? .app, package: entry?.package,
                            reason: reason, closer: closer, at: now))
        if closes.count > Self.keep { closes.removeFirst(closes.count - Self.keep) }
    }

    /// MCP-102: a connection's end closes nothing and keeps its openers.
    mutating func clientGone(_ client: MCPClientID) {}

    /// design/mcp.md's mapping table.
    private static func map(_ cause: Cause) -> (String, Closer) {
        switch cause {
        case .phone(let wire): return (MCPCloseReason.token(phone: wire), .phone)
        case .mac(.client(let id)): return ("closed", .client(id))
        case .mac(.person): return ("closed", .person)
        case .openFailed: return ("open_failed", .phone)
        case .phoneSwitched: return ("phone_switched", .person)
        }
    }

    /// A window the ledger never saw open was opened by a person's path.
    func openedBy(_ id: UInt32, asker: MCPClientID?) -> String {
        switch open[id]?.opener ?? .person {
        case .client(let c): return c == asker ? "you" : "another_agent"
        case .person: return "person"
        case .app: return "app"
        }
    }

    /// `kind`, `openedBy`, `openedAgoMs` for an open window (MCP-50).
    func row(_ id: UInt32, asker: MCPClientID?, now: TimeInterval) -> [String: Any]? {
        guard let entry = open[id] else { return nil }
        return ["kind": entry.kind.rawValue, "openedBy": openedBy(id, asker: asker),
                "openedAgoMs": Self.ms(now - entry.at)]
    }

    func closeRecord(_ id: UInt32, asker: MCPClientID?, now: TimeInterval) -> Closed? {
        guard let close = live(now).last(where: { $0.id == id }) else { return nil }
        return closed(close, asker: asker, now: now)
    }

    /// MCP-52: newest first.
    func recentlyClosed(asker: MCPClientID?, now: TimeInterval) -> [[String: Any]] {
        live(now).reversed().map { close in
            var row = closed(close, asker: asker, now: now).object
            row["id"] = Int(close.id)
            row["kind"] = close.kind.rawValue
            row["package"] = close.package.map { $0 as Any } ?? NSNull()
            return row
        }
    }

    private func live(_ now: TimeInterval) -> [Close] {
        closes.filter { now - $0.at <= Self.keepSeconds }
    }

    private func closed(_ close: Close, asker: MCPClientID?, now: TimeInterval) -> Closed {
        let by: String
        switch close.closer {
        case .client(let c): by = c == asker ? "you" : "another_agent"
        case .person: by = "person"
        case .phone: by = "phone"
        }
        return Closed(reason: close.reason, closedBy: by, closedAgoMs: Self.ms(now - close.at))
    }

    private static func ms(_ seconds: TimeInterval) -> Int { Int((seconds * 1000).rounded()) }
}
