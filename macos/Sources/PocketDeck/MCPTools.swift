// The automation server's tools (docs/design/mcp.md): validated `MCPCall`s are
// carried out over the same layers the UI uses — IntentsBridge for phone/app/
// link/file resolution, WindowManager for windows, Session for input, FrameGrab
// for a screenshot. Nothing here synthesizes NSEvents or reimplements a policy.

import AVFoundation
import Foundation

@MainActor
struct MCPToolHost {
    unowned let controller: ConnectionController

    func perform(_ call: MCPCall) async -> MCPToolResult {
        do {
            switch call {
            case .phoneStatus:
                return .text(try json(phoneStatus()))
            case .listApps:
                return .text(try json(listApps()))
            case .openApp(let query):
                return .text(try json(openApp(query)))
            case .listWindows:
                return .text(try json(listWindows()))
            case .screenshot(let window):
                return try await screenshot(window)
            case .tap(let window, let x, let y):
                return try tap(window: window, x: x, y: y)
            case .longPress(let window, let x, let y, let ms):
                return try await longPress(window: window, x: x, y: y, ms: ms)
            case .swipe(let window, let x1, let y1, let x2, let y2, let ms):
                return try await swipe(window: window, x1: x1, y1: y1, x2: x2, y2: y2, ms: ms)
            case .typeText(let window, let text):
                return try typeText(window: window, text: text)
            case .pressKey(let window, let key):
                return try pressKey(window: window, key: key)
            case .closeWindow(let window):
                return try closeWindow(window)
            case .sendLink(let url):
                return try sendLink(url)
            case .sendFile(let path):
                return try sendFile(path)
            }
        } catch let failure as IntentFailure {
            return .error(failure.message)
        } catch let failure as MCPToolFailure {
            return .error(failure.message)
        } catch {
            return .error("PocketDeck could not do that.")
        }
    }

    // MARK: Phone-level reads

    private func phoneStatus() throws -> [String: Any] {
        let windows = controller.windows.openStreams.count
        guard let phone = try? IntentsBridge.resolve(nil) else {
            return ["connected": false, "name": NSNull(), "battery": NSNull(),
                    "charging": false, "locked": false, "windows": windows]
        }
        let battery = IntentsBridge.battery(for: phone)
        return [
            "connected": controller.link.isOnline,
            "name": phone.name,
            "battery": battery.level.map { $0 as Any } ?? NSNull(),
            "charging": battery.charging,
            "locked": controller.link.isOnline ? (controller.status?.locked ?? false) : false,
            "windows": windows,
        ]
    }

    private func listApps() throws -> [String: Any] {
        let phone = try IntentsBridge.resolve(nil)
        let apps = IntentAppCatalog.search("", in: IntentsBridge.apps(for: phone), limit: 10_000)
        return ["apps": apps.map { ["label": $0.label, "package": $0.pkg] }]
    }

    private func openApp(_ query: String) throws -> [String: Any] {
        let phone = try IntentsBridge.resolve(nil)
        guard controller.link.isOnline, controller.link.phone?.id == phone.id else {
            throw IntentFailure.phoneNotConnected
        }
        switch IntentAppCatalog.app(named: query, in: IntentsBridge.apps(for: phone)) {
        case .app(let app):
            controller.intentsOpenApp(app.pkg, on: phone.id)
            // The window is created synchronously above; the newest stream for
            // that package is the one this call opened.
            let stream = controller.windows.openStreams
                .filter { (controller.windows.controller(for: $0) as? AppWindowController)?.pkg == app.pkg }
                .max()
            guard let stream else {
                throw MCPToolFailure("The app couldn't open a window.")
            }
            return ["window": Int(stream), "package": app.pkg, "label": app.label]
        case .ambiguous(let apps):
            throw IntentFailure.severalApps(query)
        case .none:
            throw IntentFailure.appNotFound(query)
        }
    }

    private func listWindows() -> [String: Any] {
        let windows: [[String: Any]] = controller.windows.openStreams.compactMap { stream in
            guard let window = controller.windows.controller(for: stream) else { return nil }
            var row: [String: Any] = [
                "id": Int(stream),
                "width": Int(window.videoView.videoSize.width.rounded()),
                "height": Int(window.videoView.videoSize.height.rounded()),
            ]
            row["package"] = package(of: window).map { $0 as Any } ?? NSNull()
            return row
        }
        return ["windows": windows]
    }

    private func package(of window: StreamWindowController) -> String? {
        if let app = window as? AppWindowController { return app.pkg }
        if let link = window as? LinkWindowController { return link.pkg }
        if let handoff = window as? HandoffWindowController { return handoff.pkg }
        return nil
    }

    // MARK: Screenshot

    private func screenshot(_ id: Int) async throws -> MCPToolResult {
        let window = try requireWindow(id)
        // The same two routes as Live Text's freeze: the frame the display
        // layer shows (what the person sees), else the phone's next keyframe
        // decoded once, for a window whose layer reports no displayed buffer
        // (occluded, or a quiet/headless run).
        if let buffer = window.videoView.copyDisplayedFrame(),
           let data = await encode(buffer) {
            return .image(data)
        }
        if let buffer = await snapshot(window), let data = await encode(buffer) {
            return .image(data)
        }
        throw MCPToolFailure("No frame on window \(id) yet.")
    }

    private func encode(_ buffer: CVPixelBuffer) async -> Data? {
        await Task.detached(priority: .userInitiated) {
            FrameGrab.png(from: buffer)
        }.value
    }

    /// The phone's next keyframe, decoded (VideoLayerView.beginFrameSnapshot).
    /// nil after 2 s: no format yet, the phone is gone, or Live Text took the
    /// decoder for its own freeze in the meantime.
    private func snapshot(_ window: StreamWindowController) async -> CVPixelBuffer? {
        final class Once {
            var continuation: CheckedContinuation<CVPixelBuffer?, Never>?
            func finish(_ buffer: CVPixelBuffer?) {
                continuation?.resume(returning: buffer)
                continuation = nil
            }
        }
        let once = Once()
        let view = window.videoView
        let buffer = await withCheckedContinuation { continuation in
            once.continuation = continuation
            view.beginFrameSnapshot { buffer in MainActor.assumeIsolated { once.finish(buffer) } }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                MainActor.assumeIsolated {
                    guard once.continuation != nil else { return }
                    view.cancelFrameSnapshot()
                    once.finish(nil)
                }
            }
        }
        return buffer
    }

    // MARK: Input

    private func tap(window id: Int, x: Double, y: Double) throws -> MCPToolResult {
        let window = try requireInputWindow(id)
        send(.touch(TouchEvent(action: .down, nx: Float(x), ny: Float(y))), to: window)
        send(.touch(TouchEvent(action: .up, nx: Float(x), ny: Float(y))), to: window)
        return .text(try json(["ok": true, "window": id]))
    }

    private func longPress(window id: Int, x: Double, y: Double, ms: Int) async throws -> MCPToolResult {
        let window = try requireInputWindow(id)
        send(.touch(TouchEvent(action: .down, nx: Float(x), ny: Float(y))), to: window)
        try? await Task.sleep(for: .milliseconds(ms))
        send(.touch(TouchEvent(action: .up, nx: Float(x), ny: Float(y))), to: window)
        return .text(try json(["ok": true, "window": id, "ms": ms]))
    }

    /// Down, ~60 Hz interpolated moves for `ms`, up. The endpoints are exact;
    /// intermediate steps never overshoot either end.
    private func swipe(window id: Int, x1: Double, y1: Double,
                      x2: Double, y2: Double, ms: Int) async throws -> MCPToolResult {
        let window = try requireInputWindow(id)
        let steps = max(1, Int((Double(ms) / 1000 * 60).rounded()))
        let interval = ms / steps
        send(.touch(TouchEvent(action: .down, nx: Float(x1), ny: Float(y1))), to: window)
        for step in 1...steps {
            if interval > 0 {
                try? await Task.sleep(for: .milliseconds(interval))
            }
            let t = Double(step) / Double(steps)
            let nx = x1 + (x2 - x1) * t
            let ny = y1 + (y2 - y1) * t
            send(.touch(TouchEvent(action: .move, nx: Float(nx), ny: Float(ny))), to: window)
        }
        send(.touch(TouchEvent(action: .up, nx: Float(x2), ny: Float(y2))), to: window)
        return .text(try json(["ok": true, "window": id, "ms": ms]))
    }

    private func typeText(window id: Int, text: String) throws -> MCPToolResult {
        let window = try requireInputWindow(id)
        controller.windows.session.text(stream: window.stream, text: text)
        return .text(try json(["ok": true, "window": id, "characters": text.count]))
    }

    private func pressKey(window id: Int, key: MCPKey) throws -> MCPToolResult {
        let window = try requireInputWindow(id)
        if let action = key.navAction {
            controller.windows.session.nav(stream: window.stream, action: action)
        } else if let keycode = key.keycode {
            controller.windows.session.key(KeyEvent(action: 0, keycode: keycode), stream: window.stream)
            controller.windows.session.key(KeyEvent(action: 1, keycode: keycode), stream: window.stream)
        }
        return .text(try json(["ok": true, "window": id, "key": key.rawValue]))
    }

    private func send(_ command: InputMapper.Command, to window: StreamWindowController) {
        let session = controller.windows.session
        switch command {
        case .touch(let event): session.touch(event, stream: window.stream)
        case .key(let event): session.key(event, stream: window.stream)
        case .text(let text): session.text(stream: window.stream, text: text)
        case .nav(let action): session.nav(stream: window.stream, action: action)
        default: break
        }
    }

    private func closeWindow(_ id: Int) throws -> MCPToolResult {
        let window = try requireWindow(id)
        window.window?.close()
        return .text(try json(["ok": true, "window": id]))
    }

    // MARK: Links and files

    private func sendLink(_ url: String) throws -> MCPToolResult {
        let phone = try IntentsBridge.resolve(nil)
        return .text(try IntentsBridge.sendLink(url, on: phone))
    }

    private func sendFile(_ path: String) throws -> MCPToolResult {
        let phone = try IntentsBridge.resolve(nil)
        return .text(try IntentsBridge.sendFiles([path], on: phone))
    }

    // MARK: Helpers

    private func requireWindow(_ id: Int) throws -> StreamWindowController {
        guard let window = controller.windows.controller(for: UInt32(id)) else {
            throw MCPToolFailure("No window \(id).")
        }
        return window
    }

    private func requireInputWindow(_ id: Int) throws -> StreamWindowController {
        let window = try requireWindow(id)
        guard controller.link.isOnline else { throw IntentFailure.phoneNotConnected }
        return window
    }

    private func json(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }
}

/// A tool failure that is not one of the intent failures.
struct MCPToolFailure: Error, Equatable {
    let message: String
    init(_ message: String) { self.message = message }
}
