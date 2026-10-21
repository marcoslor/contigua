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
//   immersive instantly|short|long|always   View > Immersive's pick: the reveal
//                                  choice (stored globally) and the immersive style
//   nav back|home|recents          the Navigate menu's own action for the window
//                                  (what a bar button and the shortcut run)
//   opensettings                   open the Settings window (⌘,)
//   fullscreen                     native full screen on the key window
//                                  (View > Enter Full Screen / ⌃⌘F)
//   density PKG PERCENT|default    the app's density override (View > Density):
//                                  75, 100, 125 or 150, or default to clear it
//                                  (⌘0's effect)
//   dropfile PATH                  the Finder drag that would land here: the absolute
//                                  file path (the drag destination's own handler runs;
//                                  an .apk keeps its install route)
//   hover NX NY                    the pointer moves to NX NY (in immersive, the window
//                                  in the dwell pill's hot zone); over the video it is
//                                  a mouse hover on the phone
//   hoverout                       the pointer leaves the video (hover EXIT)
//   hoversetting on|off            Settings ▸ Input "Hover over Android apps"
//   menudump PATH                  the main menu tree as JSON (MenuDump.swift):
//                                  titles, images, shortcuts, state, submenus
//   hoverat DX TOP                 the pointer at a window point: DX pt right of the
//                                  window's centre, TOP pt below its top edge
//   clickat DX TOP                 a left click there, through the window's own event
//                                  dispatch (it reaches the window's chrome, e.g. a light)
//   sidebutton N [HOLD DX DY STEPS]  mouse button N (3 = Back, 4 = Forward) at the stream's
//                                  centre, delivered to the view under it; held HOLD seconds
//                                  (default 0.08), dragged DX DY pt over STEPS moves
//   windowtop                      the window moved up to the screen's visible top (where
//                                  dragging its bar upward pins it)
//   waitfile PATH [SECONDS]        wait until PATH exists (default 30 s): the check script
//                                  says when the next step may run
//   notifyclick ID           the same routing a click on that phone notification runs
//                            (opens the app's window); not a stream action
//   notifyaction ID I [TEXT] the same routing a banner button (or reply, with TEXT)
//                            runs: `notify.action` for that advertised index
//   notifydismiss ID         the same routing a banner clear runs: `notify.dismiss`
//   notifycopy ID            the same routing Copy code runs (clipboard rule applies)
//   mediacmd ACTION [VALUE]  the same routing a Now Playing control runs: play, pause,
//                            next or prev; seek MS (the position bar); volume LEVEL
//                            (the media row's slider) — all `media.command`; choose KEY
//                            (`media.choose`) picks another playing app. Not a stream action
//   panelopen                the menu bar's window panel in a plain window (the
//                            status item is the window server's; a quiet run cannot
//                            open it) — the real SwiftUI content
//   panelclose               hide that window
//   deckpanel                open the Deck's phone-controls popover (its status
//                            pill is a toolbar item; opening it is setup)
//   paneldump HOST PATH      the panel's rows and the laid-out controls as JSON;
//                            HOST is panel or deck
//   panelclick HOST ID       a click at that control's own frame, through the
//                            window's event dispatch (panel.dnd, panel.ring, …)
//   paneldrag HOST ID FRACTION  the volume slider, dragged to FRACTION of its track
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
    case dockApps(Bool)
    case windowStyle(String)
    /// View ▸ Immersive's pick (the reveal choice and the immersive style).
    case immersive(ImmersiveMenuItem)
    /// The Navigate menu's action: back, home or recents.
    case nav(String)
    /// Open the Settings window (⌘,).
    case openSettings
    case fullScreen
    /// An app's density override; nil is "Default" (clear it).
    case density(pkg: String, value: Double?)
    case dropFile(String)
    case hover(NormalizedPoint)
    case hoverOut
    case hoverSetting(Bool)
    case hoverAt(dx: Double, top: Double)
    case clickAt(dx: Double, top: Double)
    /// The main menu tree written as JSON (e2e menus check).
    case menuDump(String)
    /// The menu bar's Live section written as JSON (e2e notify-media check).
    case liveDump(String)
    case sideButton(Int, hold: Double, dx: Double, dy: Double, steps: Int)
    case windowTop
    case waitFile(String, timeout: Double)
    case notifyClick(String)
    case notifyAction(String, Int, String?)
    case notifyDismiss(String)
    case notifyCopy(String)
    case mediaCommand(String)
    case mediaSeek(Int64)
    case mediaVolume(Int)
    case mediaChoose(String)
    /// The menu bar panel's debug host: open, close, dump, click a control, drag
    /// the volume slider.
    case panelOpen
    case panelClose
    case panelDump(host: String, path: String)
    case panelClick(host: String, id: String)
    case panelDrag(host: String, id: String, fraction: Double)
    /// Open the Deck's phone-controls popover (setup for its own checks).
    case deckPanel
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
        case "dockapps":
            switch args.first {
            case "on" where args.count == 1: return .dockApps(true)
            case "off" where args.count == 1: return .dockApps(false)
            default: throw LineError(message: "dockapps needs on or off")
            }
        case "windowstyle":
            switch args.first {
            case "framed" where args.count == 1: return .windowStyle("framed")
            case "immersive" where args.count == 1: return .windowStyle("immersive")
            case "toggle" where args.count == 1: return .windowStyle("toggle")
            default: throw LineError(message: "windowstyle needs framed, immersive or toggle")
            }
        case "immersive":
            switch args.first {
            case "instantly" where args.count == 1: return .immersive(.delay(.instantly))
            case "short" where args.count == 1: return .immersive(.delay(.short))
            case "long" where args.count == 1: return .immersive(.delay(.long))
            case "always" where args.count == 1: return .immersive(.alwaysVisible)
            default: throw LineError(message: "immersive needs instantly, short, long or always")
            }
        case "nav":
            guard args.count == 1, ["back", "home", "recents"].contains(args[0]) else {
                throw LineError(message: "nav needs back, home or recents")
            }
            return .nav(args[0])
        case "opensettings":
            guard args.isEmpty else { throw LineError(message: "opensettings takes no arguments") }
            return .openSettings
        case "fullscreen":
            guard args.isEmpty else { throw LineError(message: "fullscreen takes no arguments") }
            return .fullScreen
        case "density":
            guard args.count == 2 else { throw LineError(message: "density needs PKG and PERCENT or default") }
            if args[1] == "default" { return .density(pkg: args[0], value: nil) }
            guard let percent = Double(args[1]), percent > 0 else {
                throw LineError(message: "density needs PERCENT (75, 100, 125, 150) or default")
            }
            return .density(pkg: args[0], value: percent / 100)
        case "hover":
            return .hover(try point(args, count: 2))
        case "hoverout":
            guard args.isEmpty else { throw LineError(message: "hoverout takes no arguments") }
            return .hoverOut
        case "hoversetting":
            switch args.first {
            case "on" where args.count == 1: return .hoverSetting(true)
            case "off" where args.count == 1: return .hoverSetting(false)
            default: throw LineError(message: "hoversetting needs on or off")
            }
        case "hoverat", "clickat":
            guard args.count == 2, let dx = Double(args[0]), let top = Double(args[1]) else {
                throw LineError(message: "\(verb) needs DX TOP (points)")
            }
            return verb == "hoverat" ? .hoverAt(dx: dx, top: top) : .clickAt(dx: dx, top: top)
        case "menudump":
            guard args.count == 1, args[0].hasPrefix("/") else {
                throw LineError(message: "menudump needs an absolute PATH")
            }
            return .menuDump(args[0])
        case "livedump":
            guard args.count == 1, args[0].hasPrefix("/") else {
                throw LineError(message: "livedump needs an absolute PATH")
            }
            return .liveDump(args[0])
        case "sidebutton":
            guard [1, 5].contains(args.count), let button = Int(args[0]), (2...31).contains(button) else {
                throw LineError(message: "sidebutton needs N (2...31) and optionally HOLD DX DY STEPS")
            }
            guard args.count == 5 else { return .sideButton(button, hold: 0.08, dx: 0, dy: 0, steps: 0) }
            guard let dx = Double(args[2]), let dy = Double(args[3]), let steps = Int(args[4]), steps >= 0 else {
                throw LineError(message: "sidebutton DX DY are points, STEPS a count")
            }
            return .sideButton(button, hold: try hold(args, index: 1), dx: dx, dy: dy, steps: steps)
        case "windowtop":
            guard args.isEmpty else { throw LineError(message: "windowtop takes no arguments") }
            return .windowTop
        case "waitfile":
            guard (1...2).contains(args.count), args[0].hasPrefix("/") else {
                throw LineError(message: "waitfile needs an absolute PATH and optionally SECONDS")
            }
            var timeout = 30.0
            if args.count == 2 {
                guard let seconds = Double(args[1]), (1...600).contains(seconds) else {
                    throw LineError(message: "waitfile SECONDS is seconds, 1...600")
                }
                timeout = seconds
            }
            return .waitFile(args[0], timeout: timeout)
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
        case "notifyaction":
            guard args.count >= 2, !args[0].isEmpty, let index = Int(args[1]), index >= 0 else {
                throw LineError(message: "notifyaction needs an id, an index and optionally TEXT")
            }
            let text = args.count > 2 ? args.dropFirst(2).joined(separator: " ") : nil
            return .notifyAction(args[0], index, text)
        case "notifydismiss":
            guard args.count == 1, !args[0].isEmpty else { throw LineError(message: "notifydismiss needs an id") }
            return .notifyDismiss(args[0])
        case "notifycopy":
            guard args.count == 1, !args[0].isEmpty else { throw LineError(message: "notifycopy needs an id") }
            return .notifyCopy(args[0])
        case "mediacmd":
            if args.count == 1, ["play", "pause", "next", "prev"].contains(args[0]) {
                return .mediaCommand(args[0])
            }
            if args.count == 2, args[0] == "seek", let ms = Int64(args[1]), ms >= 0, ms <= 86_400_000 {
                return .mediaSeek(ms)
            }
            if args.count == 2, args[0] == "volume", let level = Int(args[1]), (0...1000).contains(level) {
                return .mediaVolume(level)
            }
            if args.count == 2, args[0] == "choose", !args[1].isEmpty {
                return .mediaChoose(args[1])
            }
            throw LineError(message: "mediacmd needs play, pause, next, prev, seek MS, volume LEVEL or choose KEY")
        case "panelopen":
            guard args.isEmpty else { throw LineError(message: "panelopen takes no arguments") }
            return .panelOpen
        case "panelclose":
            guard args.isEmpty else { throw LineError(message: "panelclose takes no arguments") }
            return .panelClose
        case "deckpanel":
            guard args.isEmpty else { throw LineError(message: "deckpanel takes no arguments") }
            return .deckPanel
        case "paneldump":
            guard args.count == 2, ["panel", "deck", "real"].contains(args[0]), args[1].hasPrefix("/") else {
                throw LineError(message: "paneldump needs HOST (panel or deck) and an absolute PATH")
            }
            return .panelDump(host: args[0], path: args[1])
        case "panelclick":
            guard args.count == 2, ["panel", "deck", "real"].contains(args[0]), !args[1].isEmpty else {
                throw LineError(message: "panelclick needs HOST (panel or deck) and an item ID")
            }
            return .panelClick(host: args[0], id: args[1])
        case "paneldrag":
            guard args.count == 3, ["panel", "deck", "real"].contains(args[0]), !args[1].isEmpty,
                  let fraction = Double(args[2]), (0...1).contains(fraction) else {
                throw LineError(message: "paneldrag needs HOST (panel or deck), an item ID and FRACTION (0...1)")
            }
            return .panelDrag(host: args[0], id: args[1], fraction: fraction)
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
    /// Set by `cancel()`: the rest of the script is dropped (the check that ran
    /// it is over and the app goes on to the next one).
    private var cancelled = false
    /// `notifyclick ID`: true once that notification is known (it may not have
    /// arrived yet, so the driver retries for a while).
    var notifyClick: ((String) -> Bool)?
    /// `notifyaction ID I [TEXT]`, `notifydismiss ID`, `notifycopy ID`: the same
    /// handlers a banner response runs; also retried until the id is known.
    var notifyAction: ((String, Int, String?) -> Bool)?
    var notifyDismiss: ((String) -> Bool)?
    var notifyCopy: ((String) -> Bool)?
    /// `livedump PATH`: the menu bar's Live section as JSON.
    var liveDump: ((String) -> Bool)?
    /// `opensettings`: the app's own Settings scene opener. The responder
    /// action only exists while the app is active, which a quiet run is not.
    var openSettings: (() -> Void)?
    /// `mediacmd ACTION`, `mediacmd seek MS`, `mediacmd volume LEVEL`: the Now
    /// Playing controls' target (the media row included).
    var mediaCommand: ((String) -> Void)?
    /// `mediacmd seek MS`: the position bar.
    var mediaSeek: ((Int64) -> Void)?
    /// `mediacmd volume LEVEL`: the media row's slider.
    var mediaVolume: ((Int) -> Void)?
    /// `mediacmd choose KEY`: `media.choose`.
    var mediaChoose: ((String) -> Void)?
    /// `dockapps on|off`: the Settings → General toggle, through the same
    /// write-then-handle path its onChange runs (e2e).
    var dockApps: ((Bool) -> Void)?
    /// `panelopen` / `panelclose`: the menu bar panel's debug host window.
    var panelOpen: (() -> Void)?
    var panelClose: (() -> Void)?
    /// `paneldump HOST PATH`: the panel's rows and laid-out controls as JSON.
    var panelDump: ((String, String) -> Bool)?
    /// `panelclick HOST ID`: a click at the control's own frame.
    var panelClick: ((String, String) -> Bool)?
    /// `paneldrag HOST ID FRACTION`: the volume slider's track.
    var panelDrag: ((String, String, Double) -> Bool)?
    /// `deckpanel`: open the Deck's phone-controls popover.
    var deckPanel: (() -> Void)?

    init(actions: [DebugInputAction]) {
        self.actions = actions
    }

    convenience init(scriptPath: String) throws {
        let text = try String(contentsOfFile: scriptPath, encoding: .utf8)
        self.init(actions: try DebugInputScript.parse(text))
    }

    /// arm — start the script at the first video size change. A phone-mode
    /// phase's script (`--open-phone`) belongs to the phone window: the shared
    /// app may reopen an app window in the same breath, and its video size can
    /// arrive first (it did in the VM), which would run the phone's keys on the
    /// app window, where ⇧⌘H/⌘↑ are not nav.
    func arm(phoneOnly: Bool = false) {
        observer = NotificationCenter.default.addObserver(
            forName: VideoLayerView.videoSizeDidChange, object: nil, queue: .main
        ) { [weak self] note in
            guard let self, let view = note.object as? VideoLayerView else { return }
            if phoneOnly, view.inputMapper?.isPhoneMode != true { return }
            self.disarm()
            // The note is posted from a main-queue block, and the script's waits
            // spin the run loop: inside that block the main queue cannot drain, so
            // the video frames enqueued on it would wait for the whole script.
            // A run-loop block starts the script outside any main-queue block.
            let timer = Timer(timeInterval: 0.05, repeats: false) { [weak self] _ in self?.run(on: view) }
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    private func disarm() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
    }

    /// Stops the script: not armed any more, no further action, and a running
    /// wait ends at its next run-loop turn.
    func cancel() {
        cancelled = true
        disarm()
    }

    private func run(on view: VideoLayerView) {
        for action in actions where !cancelled { perform(action, on: view) }
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
        case .dockApps(let on):
            dockApps?(on)
        case .windowStyle(let target):
            guard let controller = view.window?.windowController as? StreamWindowController else { return }
            switch target {
            case "framed": controller.setStyle(.framed)
            case "immersive": controller.setStyle(.immersive)
            default: controller.toggleStyle()
            }
        case .immersive(let item):
            (view.window?.windowController as? StreamWindowController)?.manager.pickImmersive(item)
        case .nav(let target):
            guard let controller = view.window?.windowController as? StreamWindowController else { return }
            switch target {
            case "back": controller.navigateBack(nil)
            case "home": (controller as? PhoneWindowController)?.navigateHome(nil)
            case "recents": (controller as? PhoneWindowController)?.navigateRecents(nil)
            default: break
            }
        case .openSettings:
            if let openSettings {
                openSettings()
            } else {
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            }
        case .fullScreen:
            // The menu item's action, through the responder chain: in full
            // screen the content can live in the system's full-screen window,
            // which is the one that has to toggle back.
            if !NSApp.sendAction(#selector(NSWindow.toggleFullScreen(_:)), to: nil, from: nil) {
                view.window?.toggleFullScreen(nil)
            }
        case .density(let pkg, let value):
            guard let controller = view.window?.windowController as? StreamWindowController else { return }
            controller.manager.setDensity(value, forPackage: pkg)
        case .dropFile(let path):
            view.onDroppedFiles?([URL(fileURLWithPath: path)])
        case .hover(let target):
            let point = view.convert(location(target, in: view), to: nil)
            (view.window?.windowController as? StreamWindowController)?.pointerMoved(toWindowPoint: point)
        case .hoverOut:
            view.inputMapper?.hoverExit()
        case .hoverSetting(let on):
            (view.window?.windowController as? StreamWindowController)?.manager.hoverEnabled = on
        case .hoverAt(let dx, let top):
            guard let window = view.window else { return }
            (window.windowController as? StreamWindowController)?
                .pointerMoved(toWindowPoint: Self.windowPoint(dx: dx, top: top, in: window))
        case .clickAt(let dx, let top):
            guard let window = view.window else { return }
            click(at: Self.windowPoint(dx: dx, top: top, in: window), in: window)
        case .menuDump(let path):
            // The state a person sees: NSMenu.update runs the same validation
            // an open menu does (titles, checks, AppKit's own items).
            NSApp.mainMenu?.update()
            try? MenuDump.write(NSApp.mainMenu, to: path)
        case .liveDump(let path):
            _ = liveDump?(path)
        case .sideButton(let button, let hold, let dx, let dy, let steps):
            sideButton(button, hold: hold, dx: dx, dy: dy, steps: steps, in: view)
        case .windowTop:
            guard let window = view.window, let screen = window.screen else { return }
            window.setFrameTopLeftPoint(NSPoint(x: window.frame.minX, y: screen.visibleFrame.maxY))
        case .waitFile(let path, let timeout):
            let deadline = Date(timeIntervalSinceNow: timeout)
            while !cancelled, !FileManager.default.fileExists(atPath: path), Date() < deadline {
                RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
            }
        case .notifyClick(let id):
            waitForNotify { self.notifyClick?(id) == true }
        case .notifyAction(let id, let index, let text):
            waitForNotify { self.notifyAction?(id, index, text) == true }
        case .notifyDismiss(let id):
            waitForNotify { self.notifyDismiss?(id) == true }
        case .notifyCopy(let id):
            waitForNotify { self.notifyCopy?(id) == true }
        case .mediaCommand(let action):
            mediaCommand?(action)
        case .mediaSeek(let ms):
            mediaSeek?(ms)
        case .mediaVolume(let level):
            mediaVolume?(level)
        case .mediaChoose(let key):
            mediaChoose?(key)
        case .panelOpen:
            panelOpen?()
        case .panelClose:
            panelClose?()
        case .panelDump(let host, let path):
            _ = panelDump?(host, path)
        case .panelClick(let host, let id):
            _ = panelClick?(host, id)
        case .panelDrag(let host, let id, let fraction):
            _ = panelDrag?(host, id, fraction)
        case .deckPanel:
            deckPanel?()
        case .wait(let seconds):
            let deadline = Date(timeIntervalSinceNow: seconds)
            while !cancelled, Date() < deadline {
                RunLoop.current.run(until: min(deadline, Date(timeIntervalSinceNow: 0.1)))
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
            // AppKit's charactersIgnoringModifiers keeps Shift ("H" for ⇧⌘H);
            // a lowercased one would match ⌘H (Hide) in the menu instead.
            press(keyCode: stroke.keyCode, characters: stroke.characters,
                  ignoring: stroke.characters, flags: flags, in: view)
        }
    }

    /// The phone's posts arrive on their own schedule; give a late one ~10 s,
    /// pumping the run loop so its frames can land (also used by the part 2
    /// notify actions, which need the id's record).
    private func waitForNotify(_ ready: () -> Bool) {
        for _ in 0..<40 where !cancelled {
            if ready() { return }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.25))
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
    /// first. In background mode the app is not activated for it.
    private func focus(_ window: NSWindow) {
        guard !window.isKeyWindow else { return }
        BackgroundMode.activateApp()
        window.makeKeyAndOrderFront(nil)
    }

    /// `DX TOP`: DX pt right of the window's centre, TOP pt below its top edge,
    /// in window coordinates (origin bottom-left).
    static func windowPoint(dx: Double, top: Double, in window: NSWindow) -> CGPoint {
        CGPoint(x: window.frame.width / 2 + dx, y: window.frame.height - top)
    }

    /// A left click the way the window dispatches a real one: the up is queued
    /// first, so a control's mouse tracking (a traffic light) finds it.
    private func click(at point: CGPoint, in window: NSWindow) {
        func event(_ type: NSEvent.EventType) -> NSEvent? {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                               timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: window.windowNumber, context: nil,
                               eventNumber: 0, clickCount: 1, pressure: 1)
        }
        guard let down = event(.leftMouseDown), let up = event(.leftMouseUp) else { return }
        NSApp.postEvent(up, atStart: false)
        window.sendEvent(down)
        pumpRunLoop()
    }

    /// A click at a window point on the control the content's hit test finds,
    /// for a check that must click a real control and not call its action.
    /// AppKit's own window dispatch delivers no synthetic mouse event to a
    /// quiet run (the app is never active, its windows sit on a virtual
    /// display), so the pair goes to the view the window would have used.
    static func clickControl(at point: CGPoint, in window: NSWindow) {
        guard let content = window.contentView, let view = content.hitTest(point) else { return }
        func event(_ type: NSEvent.EventType) -> NSEvent? {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                               timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: window.windowNumber, context: nil,
                               eventNumber: 0, clickCount: 1, pressure: 1)
        }
        guard let down = event(.leftMouseDown), let up = event(.leftMouseUp) else { return }
        view.mouseDown(with: down)
        view.mouseUp(with: up)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: Self.gestureStepInterval))
    }

    /// An extra mouse button as AppKit delivers it: an event with that button
    /// number to the view under the pointer (NSEvent.mouseEvent cannot carry a
    /// button number, so the event comes from a CGEvent).
    private func sideButton(_ button: Int, hold: Double, dx: Double, dy: Double, steps: Int, in view: VideoLayerView) {
        guard let window = view.window else { return }
        let start = view.convert(CGPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        func send(_ type: CGEventType, at point: CGPoint) {
            guard let mouseButton = CGMouseButton(rawValue: UInt32(button)),
                  let cgEvent = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: .zero,
                                        mouseButton: mouseButton) else { return }
            cgEvent.setIntegerValueField(.mouseEventButtonNumber, value: Int64(button))
            // As with the wheel events: a window-less NSEvent reads its CG location
            // back as the window point.
            let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
            cgEvent.location = CGPoint(x: point.x, y: primaryHeight - point.y)
            guard let event = NSEvent(cgEvent: cgEvent),
                  let frameView = window.contentView?.superview ?? window.contentView,
                  let target = frameView.hitTest(point) else { return }
            switch type {
            case .otherMouseDown: target.otherMouseDown(with: event)
            case .otherMouseDragged: target.otherMouseDragged(with: event)
            default: target.otherMouseUp(with: event)
            }
        }
        send(.otherMouseDown, at: start)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: hold))
        if steps > 0 {
            for step in 1...steps {
                let fraction = Double(step) / Double(steps)
                send(.otherMouseDragged, at: CGPoint(x: start.x + dx * fraction, y: start.y - dy * fraction))
                RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.008))
            }
            send(.otherMouseDragged, at: start)
        }
        send(.otherMouseUp, at: start)
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

    /// A line-unit wheel event. A window-less NSEvent(cgEvent:) reports its    /// location as a global AppKit point (CG y flipped against the primary
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
