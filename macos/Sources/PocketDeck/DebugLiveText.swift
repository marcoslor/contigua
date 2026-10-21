// Scripted Live Text steps for the e2e `livetext` check (the pattern of
// FsDebug.swift, without a session channel): a script drives the mode and each
// step's result goes out as one JSON line on stderr, which the harness captures
// into app.log. No recognized text, pixels or file names are ever logged: a
// result carries the state, `hasText`, the transcript's length, and whether one
// token from the script occurs.
//
// Grammar (blank lines and lines starting with # are ignored):
//   enter STREAM                 enter the mode on that stream's window
//   wait-analysis [TOKEN]        wait for VisionKit; contains is TOKEN's answer
//   waitfile PATH [SECONDS]      wait for the harness's go-ahead
//   copy-image OUT               write the frozen frame to OUT (absolute path)
//   drag-check                   the overlay's real hit test + a synthetic drag
//                                 at a recognised word (real-control route)
//   nav back|home|recents        the Navigate menu's action (what the bar's
//                                 buttons and the shortcuts run)
//   exit                         leave the mode
//   resize STREAM W H            change the window's stream size (must leave)
//   wait-idle [SECONDS]          wait for the mode to be idle again
//
// Results: {"op":"enter|analysis|copy|exit|resize|idle","state":...}
// plus "hasText","textLen","contains" (analysis), "ok","bytes","w","h" (copy).
// The last line is {"op":"done"}.

import AppKit
import CoreVideo
import Foundation

enum LiveTextScriptAction: Equatable {
    case enter(UInt32)
    case waitAnalysis(token: String?)
    case waitFile(path: String, timeout: Double)
    case copyImage(String)
    case dragCheck
    case nav(String)
    case exit
    case resize(stream: UInt32, width: Double, height: Double)
    case waitIdle(timeout: Double)
}

struct LiveTextScriptError: Error, CustomStringConvertible {
    let line: Int
    let message: String
    var description: String { "line \(line): \(message)" }
}

enum LiveTextDebugScript {
    private struct LineError: Error { let message: String }

    static func parse(_ text: String) throws -> [LiveTextScriptAction] {
        var actions: [LiveTextScriptAction] = []
        for (index, raw) in text.components(separatedBy: .newlines).enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            let words = line.split(separator: " ").map(String.init)
            do {
                actions.append(try parseLine(words))
            } catch let error as LineError {
                throw LiveTextScriptError(line: index + 1, message: error.message)
            }
        }
        return actions
    }

    private static func parseLine(_ words: [String]) throws -> LiveTextScriptAction {
        switch words.first?.lowercased() {
        case "enter":
            guard words.count == 2, let stream = UInt32(words[1]) else {
                throw LineError(message: "enter needs STREAM")
            }
            return .enter(stream)
        case "wait-analysis":
            guard words.count <= 2 else { throw LineError(message: "wait-analysis takes at most one TOKEN") }
            return .waitAnalysis(token: words.count == 2 ? words[1] : nil)
        case "waitfile":
            guard (2...3).contains(words.count), words[1].hasPrefix("/") else {
                throw LineError(message: "waitfile needs an absolute PATH and optionally SECONDS")
            }
            let timeout = words.count == 3 ? (Double(words[2]) ?? 0) : 30
            guard timeout > 0 else { throw LineError(message: "waitfile SECONDS must be positive") }
            return .waitFile(path: words[1], timeout: timeout)
        case "copy-image":
            guard words.count == 2, words[1].hasPrefix("/") else {
                throw LineError(message: "copy-image needs an absolute OUT path")
            }
            return .copyImage(words[1])
        case "drag-check":
            guard words.count == 1 else { throw LineError(message: "drag-check takes no arguments") }
            return .dragCheck
        case "nav":
            guard words.count == 2, ["back", "home", "recents"].contains(words[1]) else {
                throw LineError(message: "nav needs back, home or recents")
            }
            return .nav(words[1])
        case "exit":
            guard words.count == 1 else { throw LineError(message: "exit takes no arguments") }
            return .exit
        case "resize":
            guard words.count == 4, let stream = UInt32(words[1]),
                  let width = Double(words[2]), let height = Double(words[3]),
                  width > 0, height > 0 else {
                throw LineError(message: "resize needs STREAM W H")
            }
            return .resize(stream: stream, width: width, height: height)
        case "wait-idle":
            guard words.count <= 2 else { throw LineError(message: "wait-idle takes at most SECONDS") }
            let timeout = words.count == 2 ? (Double(words[1]) ?? 0) : 10
            guard timeout > 0 else { throw LineError(message: "wait-idle SECONDS must be positive") }
            return .waitIdle(timeout: timeout)
        default:
            throw LineError(message: "unknown action '\(words.first ?? "")'")
        }
    }
}

/// Runs the script once, on the first stream whose video size arrives (there
/// is no frame to freeze before that).
@MainActor
final class LiveTextDebugDriver {    private let actions: [LiveTextScriptAction]
    private let windows: WindowManager
    private var observer: NSObjectProtocol?
    /// The stream the last enter/resize named; wait-analysis and copy-image
    /// act on it.
    private var stream: UInt32 = 1

    init(actions: [LiveTextScriptAction], windows: WindowManager) {
        self.actions = actions
        self.windows = windows
    }

    convenience init(scriptPath: String, windows: WindowManager) throws {
        let text = try String(contentsOfFile: scriptPath, encoding: .utf8)
        self.init(actions: try LiveTextDebugScript.parse(text), windows: windows)
    }

    func arm() {
        observer = NotificationCenter.default.addObserver(
            forName: VideoLayerView.videoSizeDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.disarm()
            // A timer, not RunLoop.perform: while another debug script (the
            // input burst) spins the run loop in a nested run(until:), only
            // sources and timers fire there, perform blocks wait.
            let timer = Timer(timeInterval: 0.05, repeats: false) { [weak self] _ in self?.run() }
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    private func disarm() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
    }

    private func run() {
        for action in actions { perform(action) }
        emit(["op": "done", "n": actions.count])
    }

    private func perform(_ action: LiveTextScriptAction) {
        switch action {
        case .enter(let stream):
            self.stream = stream
            let deadline = Date(timeIntervalSinceNow: 15)
            while Date() < deadline {
                if let controller = windows.controller(for: stream), controller.enterLiveText() {
                    report("enter", controller: controller, ok: true)
                    return
                }
                pump(0.1)
            }
            var line = reportLine("enter", controller: windows.controller(for: stream), ok: false)
            line["why"] = windows.controller(for: stream)?.liveText.lastFailure ?? "no window"
            emit(line)
        case .waitAnalysis(let token):
            // VisionKit can take a while under load; the analysis finishes
            // when it finishes.
            let deadline = Date(timeIntervalSinceNow: 90)
            var controller = windows.controller(for: stream)
            while Date() < deadline {
                controller = windows.controller(for: stream)
                if controller?.liveText.state == .shown { break }
                pump(0.1)
            }
            var line: [String: Any] = ["op": "analysis", "ok": controller?.liveText.state == .shown]
            if let controller {
                line["state"] = controller.liveText.state.rawValue
                line["hasText"] = controller.liveText.hasText
                line["textLen"] = controller.liveText.transcriptLength
                line["highlights"] = controller.liveText.selectableItemsHighlighted
                if let token { line["contains"] = controller.liveText.contains(token) }
            }
            emit(line)
        case .waitFile(let path, let timeout):
            let deadline = Date(timeIntervalSinceNow: timeout)
            while Date() < deadline, !FileManager.default.fileExists(atPath: path) {
                pump(0.05)
            }
            emit(["op": "waitfile", "exists": FileManager.default.fileExists(atPath: path)])
        case .copyImage(let path):
            let controller = windows.controller(for: stream)
            let bytes = controller?.liveText.writePNG(to: path)
            var line: [String: Any] = ["op": "copy", "ok": bytes != nil, "bytes": bytes ?? 0]
            if let frame = controller?.liveText.frame {
                line["w"] = CVPixelBufferGetWidth(frame)
                line["h"] = CVPixelBufferGetHeight(frame)
            }
            line["state"] = controller?.liveText.state.rawValue ?? "none"
            emit(line)
        case .dragCheck:
            dragCheck(controller: windows.controller(for: stream))
        case .nav(let action):
            guard let controller = windows.controller(for: stream) else {
                emit(["op": "nav", "action": action, "ok": false, "state": "none"])
                return
            }
            switch action {
            case "back": controller.navigateBack(nil)
            case "home": (controller as? PhoneWindowController)?.navigateHome(nil)
            case "recents": (controller as? PhoneWindowController)?.navigateRecents(nil)
            default: break
            }
            var line = reportLine("nav", controller: controller, ok: true)
            line["action"] = action
            emit(line)
        case .exit:
            let controller = windows.controller(for: stream)
            controller?.exitLiveText(.toggle)
            report("exit", controller: controller)
        case .resize(let stream, let width, let height):
            self.stream = stream
            let controller = windows.controller(for: stream)
            controller?.setContentSize(NSSize(width: width, height: height))
            // The window's resize itself leaves the mode; give the debounce a
            // turn so the state read below is the one after it.
            pump(0.5)
            report("resize", controller: controller)
        case .waitIdle(let timeout):
            let deadline = Date(timeIntervalSinceNow: timeout)
            var controller = windows.controller(for: stream)
            while Date() < deadline {
                controller = windows.controller(for: stream)
                if controller?.liveText.state == .idle { break }
                pump(0.1)
            }
            var line: [String: Any] = ["op": "idle", "ok": controller?.liveText.state == .idle]
            line["state"] = controller?.liveText.state.rawValue ?? "none"
            emit(line)
        }
    }

    /// The overlay's real-control route: the hit test the window would do at
    /// a recognised word, then the down/move/up a person's drag delivers.
    /// Reports the view that took the hit and whether VisionKit selected
    /// anything (state only: no text, no pixels).
    private func dragCheck(controller: StreamWindowController?) {
        guard let controller, let window = controller.window, let content = window.contentView else {
            emit(["op": "drag", "ok": false, "why": "no window"])
            return
        }
        let session = controller.liveText
        let overlay = session.overlay
        var line: [String: Any] = [
            "op": "drag", "ok": false, "state": session.state.rawValue,
            "supplementary": !overlay.isSupplementaryInterfaceHidden,
            "buttonVisible": overlay.liveTextButtonVisible,
            "interactions": overlay.preferredInteractionTypes.rawValue,
        ]
        let frame = overlay.convert(overlay.bounds, to: content)
        var textPoint: NSPoint?
        var overlayHits = 0
        var videoHits = 0
        stride(from: frame.minX + 4, to: frame.maxX - 4, by: 6).forEach { x in
            stride(from: frame.minY + 4, to: frame.maxY - 4, by: 6).forEach { y in
                let point = NSPoint(x: x, y: y)
                guard let hit = content.hitTest(point) else { return }
                if hit === overlay || hit.isDescendant(of: overlay) {
                    overlayHits += 1
                    if textPoint == nil, overlay.hasText(at: overlay.convert(point, from: content)) {
                        textPoint = point
                    }
                } else if hit === controller.videoView || hit.isDescendant(of: controller.videoView) {
                    videoHits += 1
                }
            }
        }
        line["overlayHits"] = overlayHits
        line["videoHits"] = videoHits
        guard let point = textPoint, let target = content.hitTest(point) else {
            line["hit"] = "none"
            emit(line)
            return
        }
        line["hit"] = "overlay"
        // The quiet run keeps the app inactive (activating it changes the
        // desktop's focus), and VisionKit only starts a selection in an active
        // app; the hit route and the interaction set are what the run pins,
        // and the person's Mac is active when they drag.
        line["key"] = window.isKeyWindow
        line["active"] = NSApp.isActive
        func event(_ type: NSEvent.EventType, at point: NSPoint) -> NSEvent? {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                               timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: window.windowNumber, context: nil,
                               eventNumber: 0, clickCount: 1, pressure: 1)
        }
        let start = point
        let end = NSPoint(x: min(point.x + 120, frame.maxX - 4), y: point.y)
        // The overlay's mouseDown enters a tracking loop: queue the drag and
        // the up first, then let the window dispatch the down as a person's
        // click would (an XCTest bundle has no application; the app does).
        if let drag = event(.leftMouseDragged, at: end) { NSApp.postEvent(drag, atStart: false) }
        if let up = event(.leftMouseUp, at: end) { NSApp.postEvent(up, atStart: false) }
        if let down = event(.leftMouseDown, at: start) { window.sendEvent(down) }
        pump(0.4)
        // Anything the overlay did not consume (the video path) is dropped
        // here, so it cannot reach a later step.
        while let extra = NSApp.nextEvent(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp],
                                          until: Date(timeIntervalSinceNow: 0), inMode: .default,
                                          dequeue: true) { _ = extra }
        line["selected"] = overlay.hasActiveTextSelection
        line["ok"] = overlayHits > 0 && overlay.hasActiveTextSelection
        emit(line)
    }

    private func report(_ op: String, controller: StreamWindowController?, ok: Bool = true) {
        emit(reportLine(op, controller: controller, ok: ok))
    }

    private func reportLine(_ op: String, controller: StreamWindowController?,
                            ok: Bool) -> [String: Any] {
        guard let controller else { return ["op": op, "ok": false, "state": "none"] }
        return ["op": op, "ok": ok, "state": controller.liveText.state.rawValue]
    }

    private func pump(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date(timeIntervalSinceNow: seconds))
    }

    private func emit(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return }
        FileHandle.standardError.write(Data("livetext: \(text)\n".utf8))
    }
}
