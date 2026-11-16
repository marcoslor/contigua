// The app's end of the Control Center controls (docs/design/controls.md): it
// writes the snapshot the extension draws from into the App Group container and
// answers the extension's one-line requests on a private UNIX socket there.
//
// The socket is the generic MCPSocketServer (peer uid checked, 0600, at most
// four clients) rather than a second implementation. Every request runs the
// same IntentsBridge / controller code as the menu bar and the App Intents, so a
// control's DND counts as "set by the Mac" for the phone's restore rule.

import AppKit
import Foundation
import WidgetKit

@MainActor
final class ControlsHost {
    /// Where the snapshot and socket live: the App Group container, or
    /// `--controls-dir` for the e2e check (no extension needed there).
    let directory: URL
    private weak var controller: ConnectionController?
    private var server: MCPSocketServer?
    private var timer: Timer?
    private var last: ControlsSnapshot?
    /// One reload at a time, off the main actor.
    private var reloadQueued = false

    init?(controller: ConnectionController, directory: URL?) {
        guard let directory else { return nil }
        self.controller = controller
        self.directory = directory
    }

    /// The profile's real group folder when the bundle carries the entitlement,
    /// else nil; `--controls-dir` wins.
    static func directory(options: LaunchOptions) -> URL? {
        if let path = options.controlsDirectory, !path.isEmpty {
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
        }
        return ControlsPaths.groupDirectory()
    }

    func start() {
        let manager = FileManager.default
        try? manager.createDirectory(at: directory, withIntermediateDirectories: true,
                                     attributes: [.posixPermissions: 0o700])
        try? manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let server = MCPSocketServer(path: ControlsPaths.socketPath(in: directory)) { [weak self] line, _ in
            await self?.handle(line)
        }
        do {
            try server.start()
            self.server = server
        } catch {
            Log.app.notice("controls socket \(ControlsPaths.socketPath(in: self.directory), privacy: .private) failed: \(String(describing: error), privacy: .private)")
        }
        refresh(force: true)
        // A one-second read of the controller is the change detector: @Observable
        // has no single "any state changed" callback, and a snapshot write is
        // only 300 bytes. Controls reload only when a value really changed.
        let timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        Log.app.notice("controls host at \(self.directory.path, privacy: .private)")
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        server?.stop()
        server = nil
    }

    /// Writes the snapshot when one of its values changed, then asks Control
    /// Center to reload the controls. `force` writes even an identical snapshot
    /// (launch: the file may be missing after a crash).
    func refresh(force: Bool = false) {
        guard let controller else { return }
        let snapshot = makeSnapshot(controller)
        guard force || snapshot != last else { return }
        var stamped = snapshot
        stamped.updated = Date().timeIntervalSince1970
        guard stamped.write(to: ControlsPaths.snapshotURL(in: directory)) else { return }
        last = stamped
        reloadControls()
    }

    private func makeSnapshot(_ controller: ConnectionController) -> ControlsSnapshot {
        let online = controller.link.isOnline
        var snapshot = ControlsSnapshot()
        snapshot.connected = online
        if online, let phone = controller.link.phone {
            snapshot.phone = controller.displayName(for: phone)
            snapshot.dnd = controller.phoneDnd?.rawValue
            snapshot.ringer = controller.phoneRinger?.rawValue
        }
        snapshot.ringing = controller.ringing
        return snapshot
    }

    private func reloadControls() {
        // Control Center's reload is an XPC round trip that can block for
        // seconds when nothing is registered (a host e2e bundle has no
        // extension). It must never block the main actor: the snapshot write
        // and the request reply come first, the reload rides behind.
        guard !reloadQueued else { return }
        reloadQueued = true
        let kinds = ControlsPaths.kinds
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.05) { [weak self] in
            for kind in kinds {
                ControlCenter.shared.reloadControls(ofKind: kind)
            }
            DispatchQueue.main.async { self?.reloadQueued = false }
        }
    }

    // MARK: Requests

    private func handle(_ line: Data) async -> Data? {
        guard let request = ControlsRequest.parse(line) else {
            return ControlsReply.badRequest.line()
        }
        let reply = perform(request)
        refresh()
        Log.app.notice("controls \(request.command, privacy: .public): \(reply.ok ? "ok" : reply.error ?? "failed", privacy: .public)")
        return reply.line()
    }


    private func perform(_ request: ControlsRequest) -> ControlsReply {
        guard let controller else { return .notConnected }
        guard controller.link.isOnline else { return .notConnected }
        switch request {
        case .dnd(let on):
            do {
                let phone = try IntentsBridge.resolve(nil)
                _ = try IntentsBridge.setPhoneDnd(on: on, mode: .priority, on: phone)
                return .ok
            } catch {
                return failure(error)
            }
        case .ring:
            do {
                let phone = try IntentsBridge.resolve(nil)
                _ = try IntentsBridge.ring(phone, seconds: 30)
                return .ok
            } catch {
                return failure(error)
            }
        case .ringStop:
            guard controller.ringing else { return .ok }
            controller.stopRingingPhone()
            return .ok
        case .ringer(let mode):
            guard controller.phoneRinger != nil else { return .noRinger }
            guard controller.phoneDnd?.isOn != true else { return .dndOn }
            guard controller.setPhoneRinger(mode) else { return .notConnected }
            return .ok
        case .open:
            NSApp.activate(ignoringOtherApps: true)
            DeckWindow.show()
            return .ok
        }
    }

    private func failure(_ error: Error) -> ControlsReply {
        if let intent = error as? IntentFailure {
            switch intent {
            case .noPhone, .phoneNotConnected: return .notConnected
            case .phoneNoDnd: return .noDnd
            default: return ControlsReply.failure(intent.code, intent.message)
            }
        }
        return .badRequest
    }
}
