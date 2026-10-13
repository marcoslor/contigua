// Scripted input for the end-to-end checks. A script (one action per line) is
// turned into real NSEvents and delivered straight to the stream's
// VideoLayerView, so the path under test is still NSEvent -> VideoLayerView ->
// InputMapper -> Session, but it does not depend on which app has focus, what
// window sits on top, or where the window is on screen. Enabled only by the
// --debug-input-script launch argument; no UI reaches it.
//
// Script grammar (blank lines and lines starting with # are ignored):
//   click NX NY              left click
//   rightclick NX NY         right click (nav back)
//   drag NX1 NY1 NX2 NY2     left-button drag
//   scroll DY [NX NY]        wheel scroll, default at the centre
//   pinch NX NY SCALE        trackpad pinch around NX NY (SCALE > 0, e.g. 1.5)
//   rotate NX NY DEGREES     trackpad rotate around NX NY (positive = counter-clockwise)
//   type TEXT                text typed as key presses (rest of the line)
//   key [cmd+][shift+][ctrl+][opt+]NAME
// NX/NY are video-space coordinates in 0...1 with a top-left origin.

import AppKit

struct NormalizedPoint: Equatable {
    var nx: Double
    var ny: Double

    static let center = NormalizedPoint(nx: 0.5, ny: 0.5)
}

struct KeyStroke: Equatable {
    var keyCode: UInt16
    var characters: String
    var command = false
    var shift = false
    var control = false
    var option = false
}

enum DebugInputAction: Equatable {
    case click(NormalizedPoint)
    case rightClick(NormalizedPoint)
    case drag(from: NormalizedPoint, to: NormalizedPoint)
    case scroll(dy: Int, at: NormalizedPoint)
    case pinch(at: NormalizedPoint, scale: Double)
    case rotate(at: NormalizedPoint, degrees: Double)
    case type(String)
    case key(KeyStroke)
}

struct DebugInputParseError: Error, Equatable, CustomStringConvertible {
    let line: Int
    let message: String

    var description: String { "line \(line): \(message)" }
}

enum DebugInputScript {
    private struct LineError: Error {
        let message: String
    }

    static func parse(_ text: String) throws -> [DebugInputAction] {
        var actions: [DebugInputAction] = []
        for (index, raw) in text.components(separatedBy: .newlines).enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            do {
                actions.append(try parseLine(line))
            } catch let error as LineError {
                throw DebugInputParseError(line: index + 1, message: error.message)
            }
        }
        return actions
    }

    private static func parseLine(_ line: String) throws -> DebugInputAction {
        let head = line.split(separator: " ", maxSplits: 1).map(String.init)
        let verb = head[0].lowercased()
        let rest = head.count > 1 ? head[1] : ""
        let args = rest.split(separator: " ").map(String.init)
        switch verb {
        case "click":
            return .click(try point(args, count: 2))
        case "rightclick":
            return .rightClick(try point(args, count: 2))
        case "drag":
            guard args.count == 4 else { throw LineError(message: "drag needs NX1 NY1 NX2 NY2") }
            return .drag(from: try point(Array(args[0...1]), count: 2),
                         to: try point(Array(args[2...3]), count: 2))
        case "scroll":
            guard args.count == 1 || args.count == 3, let dy = Int(args[0]) else {
                throw LineError(message: "scroll needs DY and optionally NX NY")
            }
            let at = try args.count == 3 ? point(Array(args[1...2]), count: 2) : .center
            return .scroll(dy: dy, at: at)
        case "pinch":
            guard args.count == 3, let scale = Double(args[2]), scale > 0 else {
                throw LineError(message: "pinch needs NX NY SCALE (SCALE > 0)")
            }
            return .pinch(at: try point(Array(args[0...1]), count: 2), scale: scale)
        case "rotate":
            guard args.count == 3, let degrees = Double(args[2]) else {
                throw LineError(message: "rotate needs NX NY DEGREES")
            }
            return .rotate(at: try point(Array(args[0...1]), count: 2), degrees: degrees)
        case "type":
            guard !rest.isEmpty else { throw LineError(message: "type needs text") }
            return .type(rest)
        case "key":
            guard args.count == 1 else { throw LineError(message: "key needs one key name") }
            return .key(try keyStroke(args[0].lowercased()))
        default:
            throw LineError(message: "unknown action '\(verb)'")
        }
    }

    private static func point(_ args: [String], count: Int) throws -> NormalizedPoint {
        guard args.count == count else { throw LineError(message: "expected \(count) coordinates") }
        let values = try args.map { text -> Double in
            guard let value = Double(text), (0...1).contains(value) else {
                throw LineError(message: "coordinate '\(text)' is not in 0...1")
            }
            return value
        }
        return NormalizedPoint(nx: values[0], ny: values[1])
    }

    private static func keyStroke(_ spec: String) throws -> KeyStroke {
        var parts = spec.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        guard let name = parts.popLast(), !name.isEmpty else { throw LineError(message: "key needs a name") }
        var stroke: KeyStroke
        if let named = namedKeys[name] {
            stroke = KeyStroke(keyCode: named.keyCode, characters: named.characters)
        } else if let code = ansiKeyCodes[name] {
            stroke = KeyStroke(keyCode: code, characters: name)
        } else {
            throw LineError(message: "unknown key '\(name)'")
        }
        for modifier in parts {
            switch modifier {
            case "cmd", "command": stroke.command = true
            case "shift": stroke.shift = true
            case "ctrl", "control": stroke.control = true
            case "opt", "option", "alt": stroke.option = true
            default: throw LineError(message: "unknown modifier '\(modifier)'")
            }
        }
        if stroke.shift, stroke.characters.count == 1 {
            stroke.characters = stroke.characters.uppercased()
        }
        return stroke
    }

    private static let namedKeys: [String: (keyCode: UInt16, characters: String)] = [
        "esc": (53, "\u{1b}"),
        "return": (36, "\r"),
        "tab": (48, "\t"),
        "delete": (51, "\u{7f}"),
        "left": (123, "\u{F702}"),
        "right": (124, "\u{F703}"),
        "down": (125, "\u{F701}"),
        "up": (126, "\u{F700}"),
        "home": (115, "\u{F729}"),
        "end": (119, "\u{F72B}"),
        "pageup": (116, "\u{F72C}"),
        "pagedown": (121, "\u{F72D}"),
    ]

    /// ANSI virtual key codes for the printable keys a script can name.
    private static let ansiKeyCodes: [String: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
        "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19,
        "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28,
        "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "l": 37, "j": 38,
        "k": 40, ",": 43, "/": 44, "n": 45, "m": 46, ".": 47,
    ]
}

/// Runs a script once, against the first stream whose video size arrives.
/// The size arrives only after the phone has accepted the window, so the
/// session is ready and the view has a layout to aim at.
final class DebugInputDriver {
    static let dragSteps = 20
    /// Changed events per gesture. They are paced one display refresh apart so
    /// the coalesced moves (InputMapper) reach the phone.
    static let gestureSteps = 8
    static var gestureStepInterval: TimeInterval { InputMapper.displayRefreshInterval * 1.5 }

    private let actions: [DebugInputAction]
    private var observer: NSObjectProtocol?

    init(actions: [DebugInputAction]) {
        self.actions = actions
    }

    convenience init(scriptPath: String) throws {
        let text = try String(contentsOfFile: scriptPath, encoding: .utf8)
        self.init(actions: try DebugInputScript.parse(text))
    }

    func arm() {
        observer = NotificationCenter.default.addObserver(
            forName: VideoLayerView.videoSizeDidChange, object: nil, queue: .main
        ) { [weak self] note in
            guard let self, let view = note.object as? VideoLayerView else { return }
            self.disarm()
            self.run(on: view)
        }
    }

    private func disarm() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
    }

    private func run(on view: VideoLayerView) {
        for action in actions { perform(action, on: view) }
    }

    /// The view-space point of a video-space point; the inverse of
    /// `Letterbox.normalized`, so InputMapper recovers the same coordinates.
    static func viewPoint(_ point: NormalizedPoint, videoRect: CGRect, flipped: Bool) -> CGPoint {
        let x = videoRect.minX + CGFloat(point.nx) * videoRect.width
        let fraction = CGFloat(point.ny)
        let y = flipped
            ? videoRect.minY + fraction * videoRect.height
            : videoRect.minY + (1 - fraction) * videoRect.height
        return CGPoint(x: x, y: y)
    }

    private func perform(_ action: DebugInputAction, on view: VideoLayerView) {
        switch action {
        case .click(let target):
            let point = location(target, in: view)
            if let down = mouse(.leftMouseDown, at: point, in: view) { view.mouseDown(with: down) }
            if let up = mouse(.leftMouseUp, at: point, in: view) { view.mouseUp(with: up) }
        case .rightClick(let target):
            if let down = mouse(.rightMouseDown, at: location(target, in: view), in: view) {
                view.rightMouseDown(with: down)
            }
        case .drag(let from, let to):
            let start = location(from, in: view)
            let end = location(to, in: view)
            if let down = mouse(.leftMouseDown, at: start, in: view) { view.mouseDown(with: down) }
            for step in 1...Self.dragSteps {
                let fraction = CGFloat(step) / CGFloat(Self.dragSteps)
                let point = CGPoint(x: start.x + (end.x - start.x) * fraction,
                                    y: start.y + (end.y - start.y) * fraction)
                if let drag = mouse(.leftMouseDragged, at: point, in: view) { view.mouseDragged(with: drag) }
            }
            if let up = mouse(.leftMouseUp, at: end, in: view) { view.mouseUp(with: up) }
        case .scroll(let dy, let target):
            if let scroll = scrollEvent(dy: dy, at: location(target, in: view), in: view) {
                view.scrollWheel(with: scroll)
            }
        case .pinch(let target, let scale):
            let point = location(target, in: view)
            view.magnifyGesture(phase: .began, magnification: 0, at: point)
            for _ in 1...Self.gestureSteps {
                view.magnifyGesture(phase: .changed,
                                    magnification: (scale - 1) / Double(Self.gestureSteps),
                                    at: point)
                pumpRunLoop()
            }
            view.magnifyGesture(phase: .ended, magnification: 0, at: point)
        case .rotate(let target, let degrees):
            let point = location(target, in: view)
            view.rotateGesture(phase: .began, rotation: 0, at: point)
            for _ in 1...Self.gestureSteps {
                view.rotateGesture(phase: .changed,
                                   rotation: degrees / Double(Self.gestureSteps),
                                   at: point)
                pumpRunLoop()
            }
            view.rotateGesture(phase: .ended, rotation: 0, at: point)
        case .type(let text):
            guard let window = view.window else { return }
            focus(window)
            for character in text {
                let characters = String(character)
                press(keyCode: 0, characters: characters, ignoring: characters, flags: [], in: view)
            }
        case .key(let stroke):
            guard let window = view.window else { return }
            focus(window)
            var flags: NSEvent.ModifierFlags = []
            if stroke.command { flags.insert(.command) }
            if stroke.shift { flags.insert(.shift) }
            if stroke.control { flags.insert(.control) }
            if stroke.option { flags.insert(.option) }
            press(keyCode: stroke.keyCode, characters: stroke.characters,
                  ignoring: stroke.characters.lowercased(), flags: flags, in: view)
        }
    }

    /// Escape is only forwarded to a key window, so the window is made key
    /// first. Activation is in-process; the other app's focus is not involved.
    private func focus(_ window: NSWindow) {
        guard !window.isKeyWindow else { return }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// The whole script runs in one run-loop turn; gesture steps hand the
    /// loop back briefly so the display-refresh move flush can run between them.
    private func pumpRunLoop() {
        RunLoop.current.run(until: Date(timeIntervalSinceNow: Self.gestureStepInterval))
    }

    private func location(_ target: NormalizedPoint, in view: VideoLayerView) -> CGPoint {
        Self.viewPoint(target, videoRect: view.videoRect(), flipped: view.isFlipped)
    }

    private func mouse(_ type: NSEvent.EventType, at point: CGPoint, in view: VideoLayerView) -> NSEvent? {
        NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil),
                           modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                           windowNumber: view.window?.windowNumber ?? 0, context: nil,
                           eventNumber: 0, clickCount: 1, pressure: 1)
    }

    /// A line-unit wheel event. A window-less NSEvent(cgEvent:) reports its
    /// location as a global AppKit point (CG y flipped against the primary
    /// screen) and does not convert it, so the CG location is written so that
    /// the event reads back as the window point the view will convert.
    private func scrollEvent(dy: Int, at point: CGPoint, in view: VideoLayerView) -> NSEvent? {
        guard view.window != nil,
              let cgEvent = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1,
                                    wheel1: Int32(dy), wheel2: 0, wheel3: 0) else { return nil }
        let inWindow = view.convert(point, to: nil)
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        cgEvent.location = CGPoint(x: inWindow.x, y: primaryHeight - inWindow.y)
        return NSEvent(cgEvent: cgEvent)
    }

    private func press(keyCode: UInt16, characters: String, ignoring: String,
                       flags: NSEvent.ModifierFlags, in view: VideoLayerView) {
        let windowNumber = view.window?.windowNumber ?? 0
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags,
                                               timestamp: ProcessInfo.processInfo.systemUptime,
                                               windowNumber: windowNumber, context: nil,
                                               characters: characters, charactersIgnoringModifiers: ignoring,
                                               isARepeat: false, keyCode: keyCode) else { continue }
            if type == .keyDown { view.keyDown(with: event) } else { view.keyUp(with: event) }
        }
    }
}
