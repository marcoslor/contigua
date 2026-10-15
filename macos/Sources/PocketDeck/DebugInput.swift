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
//   trackscroll DY [NX NY]   two-finger trackpad scroll (phased, then momentum events)
//                            of DY points; positive moves the content down
//   fingerscroll DY [NX NY]  the same with the raw fingers on the pad as well
//   pinch NX NY SCALE        trackpad pinch around NX NY (SCALE > 0, e.g. 1.5); the
//                            coarse magnify-event emulation
//   rotate NX NY DEGREES     trackpad rotate around NX NY (positive = counter-clockwise)
//   fingerpinch NX NY SCALE [HOLD]  the same pinch from raw trackpad fingers; HOLD seconds
//                            with the fingers down at the end (for looking at the overlay)
//   fingerrotate NX NY DEGREES [HOLD]  the same rotate from raw trackpad fingers
//   showtouches on|off             View > Show Touches
//   windowstyle framed|immersive|toggle   the key window's chrome style
//                                  (View > Window Style / its ⌥⌘F toggle)
//   dropfile PATH                  the Finder drag that would land here: the absolute
//                                  file path (the drag destination's own handler runs;
//                                  an .apk keeps its install route)
//   hover NX NY                    the pointer moves to NX NY (in immersive, the window
//                                  in the dwell pill's hot zone)
//   notifyclick ID           the same routing a click on that phone notification runs
//                            (opens the app's window); not a stream action
//   mediacmd ACTION          the same routing a Now Playing control runs: play, pause,
//                            next or prev (`media.command`); not a stream action
//   wait SECONDS             let the app run (timers, animations) before the next action
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
    case trackScroll(dy: Int, at: NormalizedPoint)
    case fingerScroll(dy: Int, at: NormalizedPoint)
    case pinch(at: NormalizedPoint, scale: Double)
    case rotate(at: NormalizedPoint, degrees: Double)
    case fingerPinch(at: NormalizedPoint, scale: Double, hold: Double)
    case fingerRotate(at: NormalizedPoint, degrees: Double, hold: Double)
    case showTouches(Bool)
    case windowStyle(String)
    case dropFile(String)
    case hover(NormalizedPoint)
    case notifyClick(String)
    case mediaCommand(String)
    case wait(Double)
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
        case "trackscroll", "fingerscroll":
            guard args.count == 1 || args.count == 3, let dy = Int(args[0]) else {
                throw LineError(message: "\(verb) needs DY and optionally NX NY")
            }
            let at = try args.count == 3 ? point(Array(args[1...2]), count: 2) : .center
            return verb == "trackscroll" ? .trackScroll(dy: dy, at: at) : .fingerScroll(dy: dy, at: at)
        case "pinch", "fingerpinch":
            let maxArgs = verb == "pinch" ? 3 : 4
            guard (3...maxArgs).contains(args.count), let scale = Double(args[2]), scale > 0 else {
                throw LineError(message: "\(verb) needs NX NY SCALE (SCALE > 0)\(verb == "pinch" ? "" : " and optionally HOLD")")
            }
            let at = try point(Array(args[0...1]), count: 2)
            if verb == "pinch" { return .pinch(at: at, scale: scale) }
            return .fingerPinch(at: at, scale: scale, hold: try hold(args, index: 3))
        case "rotate", "fingerrotate":
            let maxArgs = verb == "rotate" ? 3 : 4
            guard (3...maxArgs).contains(args.count), let degrees = Double(args[2]) else {
                throw LineError(message: "\(verb) needs NX NY DEGREES\(verb == "rotate" ? "" : " and optionally HOLD")")
            }
            let at = try point(Array(args[0...1]), count: 2)
            if verb == "rotate" { return .rotate(at: at, degrees: degrees) }
            return .fingerRotate(at: at, degrees: degrees, hold: try hold(args, index: 3))
        case "showtouches":
            switch args.first {
            case "on" where args.count == 1: return .showTouches(true)
            case "off" where args.count == 1: return .showTouches(false)
            default: throw LineError(message: "showtouches needs on or off")
            }
        case "windowstyle":
            switch args.first {
            case "framed" where args.count == 1: return .windowStyle("framed")
            case "immersive" where args.count == 1: return .windowStyle("immersive")
            case "toggle" where args.count == 1: return .windowStyle("toggle")
            default: throw LineError(message: "windowstyle needs framed, immersive or toggle")
            }
        case "hover":
            return .hover(try point(args, count: 2))
        case "dropfile":
            guard args.count == 1, !args[0].isEmpty else {
                throw LineError(message: "dropfile needs an absolute PATH")
            }
            var path = args[0]
            if path.hasPrefix("~") {
                path = String(path.dropFirst(1))
                let home = FileManager.default.homeDirectoryForCurrentUser.path
                path = home + path
            }
            guard path.hasPrefix("/") else {
                throw LineError(message: "dropfile needs an absolute PATH (got relative '\(args[0])')")
            }
            guard FileManager.default.fileExists(atPath: path) else {
                throw LineError(message: "dropfile: no such file: \(path)")
            }
            return .dropFile(path)
        case "notifyclick":
            guard args.count == 1, !args[0].isEmpty else { throw LineError(message: "notifyclick needs an id") }
            return .notifyClick(args[0])
        case "mediacmd":
            guard args.count == 1, ["play", "pause", "next", "prev"].contains(args[0]) else {
                throw LineError(message: "mediacmd needs play, pause, next or prev")
            }
            return .mediaCommand(args[0])
        case "wait":
            guard args.count == 1, let seconds = Double(args[0]), (0...60).contains(seconds) else {
                throw LineError(message: "wait needs SECONDS (0...60)")
            }
            return .wait(seconds)
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

    private static func hold(_ args: [String], index: Int) throws -> Double {
        guard args.count > index else { return 0 }
        guard let seconds = Double(args[index]), (0...60).contains(seconds) else {
            throw LineError(message: "HOLD is seconds, 0...60")
        }
        return seconds
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
    /// A trackpad scroll event arrives about once per display refresh; Android
    /// computes its fling velocity from that cadence.
    static let scrollSteps = 12
    static var scrollStepInterval: TimeInterval { InputMapper.displayRefreshInterval }
    /// The trackpad as the raw-finger actions imagine it: a Magic Trackpad,
    /// fingers 32 mm apart.
    static let fingerSpanMillimetres = 32.0

    private let actions: [DebugInputAction]
    private var observer: NSObjectProtocol?
    /// `notifyclick ID`: true once that notification is known (it may not have
    /// arrived yet, so the driver retries for a while).
    var notifyClick: ((String) -> Bool)?
    /// `mediacmd ACTION`: the Now Playing transport controls' target.
    var mediaCommand: ((String) -> Void)?

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
            // The note is posted from a main-queue block, and the script's waits
            // spin the run loop: inside that block the main queue cannot drain, so
            // the video frames enqueued on it would wait for the whole script.
            // A run-loop block starts the script outside any main-queue block.
            RunLoop.main.perform { self.run(on: view) }
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
        Letterbox.viewPoint(nx: Float(point.nx), ny: Float(point.ny), videoRect: videoRect, flipped: flipped)
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
        case .trackScroll(let dy, let target):
            trackScroll(dy: dy, at: location(target, in: view), in: view, fingers: false)
        case .fingerScroll(let dy, let target):
            trackScroll(dy: dy, at: location(target, in: view), in: view, fingers: true)
        case .fingerPinch(let target, let scale, let hold):
            let span = Self.fingerSpanMillimetres
            fingerGesture(at: location(target, in: view), in: view, hold: hold) { fraction in
                Self.fingers(spanMillimetres: span * (1 + (scale - 1) * fraction), degrees: 0)
            }
        case .fingerRotate(let target, let degrees, let hold):
            let span = Self.fingerSpanMillimetres
            fingerGesture(at: location(target, in: view), in: view, hold: hold) { fraction in
                Self.fingers(spanMillimetres: span, degrees: degrees * fraction)
            }
        case .showTouches(let enabled):
            (view.window?.windowController as? StreamWindowController)?.manager.showTouches = enabled
        case .windowStyle(let target):
            guard let controller = view.window?.windowController as? StreamWindowController else { return }
            switch target {
            case "framed": controller.setStyle(.framed)
            case "immersive": controller.setStyle(.immersive)
            default: controller.toggleStyle()
            }
        case .dropFile(let path):
            view.onDroppedFiles?([URL(fileURLWithPath: path)])
        case .hover(let target):
            let point = view.convert(location(target, in: view), to: nil)
            (view.window?.windowController as? StreamWindowController)?.pointerMoved(toWindowPoint: point)
        case .notifyClick(let id):
            // The phone's posts arrive on their own schedule; give a late one
            // ~10 s, pumping the run loop so its frames can land.
            for _ in 0..<40 {
                if notifyClick?(id) == true { return }
                RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.25))
            }
        case .mediaCommand(let action):
            mediaCommand?(action)
        case .wait(let seconds):
            RunLoop.current.run(until: Date(timeIntervalSinceNow: seconds))
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
            // AppKit's charactersIgnoringModifiers keeps Shift ("H" for ⇧⌘H);
            // a lowercased one would match ⌘H (Hide) in the menu instead.
            press(keyCode: stroke.keyCode, characters: stroke.characters,
                  ignoring: stroke.characters, flags: flags, in: view)
        }
    }

    /// A two-finger scroll the way a trackpad delivers it: began, changed events a
    /// display refresh apart, ended, then the momentum the system adds after a
    /// flick (which must reach nobody). With `fingers` the raw fingers travel
    /// along, so the arbitration between the two paths is exercised too.
    private func trackScroll(dy: Int, at point: CGPoint, in view: VideoLayerView, fingers: Bool) {
        let step = Double(dy) / Double(Self.scrollSteps)
        // Content moving down is the fingers moving down the pad, about 4 points per millimetre.
        let padTravel = -Double(dy) / TrackpadPinch.defaultPointsPerMillimetre
        func land(_ fraction: Double) {
            guard fingers else { return }
            let list = Self.fingers(spanMillimetres: Self.fingerSpanMillimetres, degrees: 0,
                                    shiftMillimetres: padTravel * fraction)
            view.trackpadFingers(list, surface: .fallback, cursor: point)
        }
        land(0)
        if let began = scrollEvent(phase: 1, momentum: 0, dy: 0, at: point, in: view) { view.scrollWheel(with: began) }
        for index in 1...Self.scrollSteps {
            land(Double(index) / Double(Self.scrollSteps))
            if let changed = scrollEvent(phase: 2, momentum: 0, dy: step, at: point, in: view) {
                view.scrollWheel(with: changed)
            }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: Self.scrollStepInterval))
        }
        if let ended = scrollEvent(phase: 4, momentum: 0, dy: 0, at: point, in: view) { view.scrollWheel(with: ended) }
        if fingers { view.trackpadFingers([], surface: .fallback, cursor: point) }
        for (momentum, factor) in [(Int64(1), 2.0), (2, 1.5), (2, 1.0), (3, 0.0)] {
            if let event = scrollEvent(phase: 0, momentum: momentum, dy: step * factor, at: point, in: view) {
                view.scrollWheel(with: event)
            }
        }
    }

    /// Two fingers centred on the pad, `spanMillimetres` apart, the pair turned
    /// by `degrees` (counter-clockwise on the pad) and moved up by `shiftMillimetres`.
    static func fingers(spanMillimetres: Double, degrees: Double, shiftMillimetres: Double = 0) -> [TrackpadFinger] {
        let surface = TrackpadSurface.fallback
        let width = surface.widthPoints * TrackpadSurface.millimetresPerPoint
        let height = surface.heightPoints * TrackpadSurface.millimetresPerPoint
        let radians = degrees * .pi / 180
        let half = spanMillimetres / 2
        let dx = cos(radians) * half, dy = sin(radians) * half
        let cx = width / 2, cy = height / 2 + shiftMillimetres
        return [TrackpadFinger(id: 1, x: (cx - dx) / width, y: (cy - dy) / height),
                TrackpadFinger(id: 2, x: (cx + dx) / width, y: (cy + dy) / height)]
    }

    /// Fingers land, travel along `path` (fraction 0...1) in steps a display
    /// refresh apart, and lift.
    private func fingerGesture(at point: CGPoint, in view: VideoLayerView, hold: Double = 0,
                               path: (Double) -> [TrackpadFinger]) {
        view.trackpadFingers(path(0), surface: .fallback, cursor: point)
        for step in 1...Self.gestureSteps {
            view.trackpadFingers(path(Double(step) / Double(Self.gestureSteps)), surface: .fallback, cursor: point)
            pumpRunLoop()
        }
        if hold > 0 { RunLoop.current.run(until: Date(timeIntervalSinceNow: hold)) }
        let last = path(1)
        view.trackpadFingers([last[0]], surface: .fallback, cursor: point)
        view.trackpadFingers([], surface: .fallback, cursor: point)
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

    /// A continuous (pixel) scroll event with a gesture phase, in the values
    /// CGEvent uses: phase 1 began, 2 changed, 4 ended; momentum 1 begin, 2
    /// continue, 3 end.
    private func scrollEvent(phase: Int64, momentum: Int64, dy: Double, at point: CGPoint,
                             in view: VideoLayerView) -> NSEvent? {
        guard view.window != nil,
              let cgEvent = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                                    wheel1: Int32(dy.rounded()), wheel2: 0, wheel3: 0) else { return nil }
        cgEvent.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        cgEvent.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
        cgEvent.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum)
        cgEvent.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: dy)
        cgEvent.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: dy)
        let inWindow = view.convert(point, to: nil)
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        cgEvent.location = CGPoint(x: inWindow.x, y: primaryHeight - inWindow.y)
        return NSEvent(cgEvent: cgEvent)
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
        var menuAte = false
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags,
                                               timestamp: ProcessInfo.processInfo.systemUptime,
                                               windowNumber: windowNumber, context: nil,
                                               characters: characters, charactersIgnoringModifiers: ignoring,
                                               isARepeat: false, keyCode: keyCode) else { continue }
            if type == .keyDown {
                // A real press runs through the menu bar first: its key
                // equivalents (⌥⌘F's Toggle Window Style) are AppKit's own
                // dispatch. An equivalent, not matched by any menu, goes on to
                // the view as before.
                if !flags.isEmpty, NSApp.mainMenu?.performKeyEquivalent(with: event) == true {
                    menuAte = true
                    continue
                }
                view.keyDown(with: event)
            } else if !menuAte {
                view.keyUp(with: event)
            }
        }
    }
}
