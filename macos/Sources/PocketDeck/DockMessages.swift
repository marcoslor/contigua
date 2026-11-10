// The messages between PocketDeck and its Dock apps (docs/design/dock.md). Also
// compiled into the shim binary (Shim/main.swift), so it uses Foundation only.

import Foundation

enum DockMessage {
    /// Shim → host: open or focus this app's window. userInfo: deviceId, pkg, pid.
    static let open = Notification.Name("dev.pocketdeck.dock.open")
    /// Shim → host (automatic path): the shim is listening and its window is
    /// already open. userInfo: deviceId, pkg, pid, token. The host answers a
    /// bound pid with `opened`; an unbound one is answered by its own bind.
    static let ready = Notification.Name("dev.pocketdeck.dock.ready")
    /// Host → shim: the request arrived. userInfo: pid.
    static let opened = Notification.Name("dev.pocketdeck.dock.opened")
    /// Host → shim: the window is gone; the shim exits. userInfo: pid.
    static let closed = Notification.Name("dev.pocketdeck.dock.closed")
    /// Shim → host: the shim is quitting; close its window. userInfo: pid.
    static let quit = Notification.Name("dev.pocketdeck.dock.quit")
    /// Host → shim: the app's window menu, front to back (WIN-26). userInfo:
    /// pid and `rows` (an array of dictionaries: title, enabled, checked, help,
    /// key, action, stream).
    static let menu = Notification.Name("dev.pocketdeck.dock.menu")
    /// Shim → host: a row of that menu was picked. userInfo: deviceId, pkg,
    /// pid, token, action ("new" or "raise") and stream (0 for "new").
    static let pick = Notification.Name("dev.pocketdeck.dock.pick")

    static let rowsKey = "rows"
    static let actionKey = "action"
    static let streamKey = "stream"

    static let deviceIdKey = "deviceId"
    static let pkgKey = "pkg"
    static let pidKey = "pid"
    /// Shim → host: the shim's per-bundle token (sec L-8). The host ignores an
    /// open/quit message whose token is not the one in that shim's Info.plist.
    static let tokenKey = "token"

    /// Info.plist keys of a shim bundle.
    static let plistDeviceId = "PDDeviceId"
    static let plistPackage = "PDPackage"
    static let plistProfile = "PDProfile"
    static let plistHostPath = "PDHostPath"
    /// A random per-bundle token, written when the bundle is built.
    static let plistToken = "PDToken"
    /// e2e only: hold the shim's observer registration back that many seconds,
    /// the way a slow launch does. Written only when the host is given
    /// `--dock-debug-listen-delay` in a build with the test hooks.
    static let plistListenDelay = "PDListenDelay"
    /// SHA-256 of the shim executable this bundle was built from. The copy is
    /// re-signed per bundle id, so its bytes never equal the app's shim; the
    /// refresh compares this hash and rebuilds a bundle from an older build.
    static let plistShimHash = "PDShimHash"
    /// Why the bundle exists (docs/design/dock.md §Shortcuts): an array of
    /// `dock`, `manual`, `all`, `window`. Written by every current build.
    static let plistOrigins = "PDOrigins"
    /// The app's label as the phone sent it, so a rebuild that only changes the
    /// origins keeps the name without the phone part.
    static let plistLabel = "PDLabel"
    /// The renderer version the shim's icon was made with (docs/design/dock.md
    /// §Icons): a bundle with an older or missing one is rebuilt.
    static let plistIconVersion = "PDIconVersion"
    /// Whether that icon was drawn from the phone's adaptive layers (true) or
    /// from a flat icon on the plate (false). Layers arriving later make a
    /// plate-built shim stale, so it is rebuilt the next time it is followed.
    static let plistIconLayers = "PDIconLayers"
    /// e2e only: where the shim dumps its built window menu and reads a press
    /// (a `--debug-control` directory; never written by a normal run).
    static let plistMenuDebugDir = "PDMenuDebugDir"

    /// The shim executable inside PocketDeck.app/Contents/MacOS and every shim bundle.
    static let shimExecutable = "PocketDeckShim"
}

/// The per-shim token (sec L-8): random when the bundle is written, carried in
/// its Info.plist and in every message it posts. The host accepts an open/quit
/// message only when the token equals the one stored for that shim, so a local
/// process that merely knows a package name cannot drive a session.
enum DockToken {
    static let byteCount = 16

    /// 32 lowercase hex characters.
    static func make() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    static func isWellFormed(_ token: String) -> Bool {
        token.count == byteCount * 2 && token.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }

    /// Both present, well-formed and equal (compared byte by byte).
    static func matches(message: String?, stored: String?) -> Bool {
        guard let message, let stored,
              isWellFormed(message), isWellFormed(stored) else { return false }
        var diff = 0
        for (a, b) in zip(Array(message.utf8), Array(stored.utf8)) { diff |= Int(a ^ b) }
        return diff == 0
    }
}

// MARK: - The shim's lifecycle (docs/design/dock.md §Launch → window)

/// The shim's handshake (DockApps.swift owns the origin events, so these live
/// under the machine). Pure, so K2 runs every transition.
enum DockShimMachine {
    /// What the shim is waiting for: a person's launch (`open`) or the host's
    /// answer to an automatic launch's `ready`.
    enum WaitKind: Equatable {
        case open
        case ready
    }

    /// The shim's whole state: one enum, not a set of flags (CONV-PD-08).
    enum State: Equatable {
        /// Observers are not registered yet: a slow launch (e2e) or the instant
        /// between `init` and `applicationDidFinishLaunching`.
        case starting
        /// `hostSeen` means the shim has seen the host running: at listen time,
        /// or when its own `launchHost` action ran. A host exit is only news
        /// once it was seen (DOCK-19).
        case waiting(kind: WaitKind, since: Date, hostSeen: Bool)
        case bound
        case quitting

        /// A closed set of labels for the transition log.
        var label: String {
            switch self {
            case .starting: return "starting"
            case .waiting(let kind, _, let hostSeen):
                return "waiting(\(kind == .open ? "open" : "ready"), hostSeen: \(hostSeen))"
            case .bound: return "bound"
            case .quitting: return "quitting"
            }
        }
    }

    enum Event: Equatable {
        /// Observers are registered: an automatic launch waits for `opened`, a
        /// manual one asks for the window. `hostSeen` is whether the host was
        /// already running when the shim started listening.
        case launch(automatic: Bool, hostSeen: Bool, now: Date)
        case tick(now: Date)
        case opened
        case closed
        /// Dock click, ⌘-Tab or reopen.
        case activate
        case reopen(now: Date)
        case terminate
        /// `NSWorkspace` says the host process ended (quit, crash or force quit).
        case hostExited

        var label: String {
            switch self {
            case .launch(let automatic, _, _): return automatic ? "launch(auto)" : "launch(open)"
            case .tick: return "tick"
            case .opened: return "opened"
            case .closed: return "closed"
            case .activate: return "activate"
            case .reopen: return "reopen"
            case .terminate: return "terminate"
            case .hostExited: return "hostExited"
            }
        }
    }

    /// What the shim sends the host.
    enum Message: Equatable {
        case open
        case ready
        case quit
    }

    /// Side effects the driver (Shim/main.swift) performs, never the transition.
    enum Action: Equatable {
        case post(Message)
        case launchHost
        case startRetry
        case stopRetry
        case terminate
        case exit
    }

    /// No answer for this long means no host: the shim quits, so a lost host
    /// never leaves a Dock tile behind. A bound shim never reaches it.
    static let noAnswerQuitAfter: TimeInterval = 30
    /// An `open` with no host running starts the host after this.
    static let launchHostAfter: TimeInterval = 2

    /// The one transition function: every event in every state.
    static func transition(_ state: State, _ event: Event) -> (State, [Action]) {
        switch event {
        case .launch(let automatic, let hostSeen, let now):
            guard case .starting = state else { return (state, []) }
            let kind: WaitKind = automatic ? .ready : .open
            return (.waiting(kind: kind, since: now, hostSeen: hostSeen),
                    [.post(kind == .open ? .open : .ready), .startRetry])

        case .tick(let now):
            guard case .waiting(let kind, let since, let hostSeen) = state else { return (state, []) }
            let waited = now.timeIntervalSince(since)
            if waited > noAnswerQuitAfter {
                // Quit first, then terminate: the self-quit keeps the Quit ↔
                // close rule, and applicationWillTerminate has nothing to add.
                return (.quitting, [.post(.quit), .terminate])
            }
            var next = state
            var actions: [Action] = []
            if kind == .open, !hostSeen, waited >= launchHostAfter {
                next = .waiting(kind: kind, since: since, hostSeen: true)
                actions.append(.launchHost)
            }
            actions.append(.post(kind == .open ? .open : .ready))
            return (next, actions)

        case .opened:
            // Starting means the answer arrived before our own launch event:
            // the host has bound us, so the window is ours now.
            if case .starting = state { return (.bound, [.stopRetry]) }
            guard case .waiting = state else { return (state, []) }
            return (.bound, [.stopRetry])

        case .closed:
            return (.quitting, [.exit])

        case .activate:
            guard case .bound = state else { return (state, []) }
            return (state, [.post(.open)])

        case .reopen(let now):
            if case .quitting = state { return (state, []) }
            return (.waiting(kind: .open, since: now, hostSeen: false),
                    [.post(.open), .startRetry])

        case .terminate:
            if case .quitting = state { return (state, []) }
            return (.quitting, [.post(.quit)])

        case .hostExited:
            // DOCK-19 (ISS-6): the process that bound (or was about to bind)
            // this shim is gone. There is no host left to post `quit` to; the
            // same `[.exit]` a `closed` takes removes the Dock tile at once.
            if case .bound = state { return (.quitting, [.exit]) }
            if case .waiting(_, _, true) = state { return (.quitting, [.exit]) }
            return (state, [])
        }
    }
}
