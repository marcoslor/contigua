// cgevent-input.swift — synthesize real mouse/keyboard events at a Contigua
// window's coordinates so the automated checks exercise the same code path as a
// human (NSEvent -> InputMapper -> protocol).
//
// Usage:
//   swift scripts/cgevent-input.swift list
//   swift scripts/cgevent-input.swift titles
//   swift scripts/cgevent-input.swift all
//   swift scripts/cgevent-input.swift click  --window ID [--dx N --dy N]
//   swift scripts/cgevent-input.swift drag   --window ID --dx 200 --dy 0 [--steps 20]
//   swift scripts/cgevent-input.swift drag   --window ID --right-edge --dx 100   (resize from the right edge)
//   swift scripts/cgevent-input.swift scroll --window ID [--dy 3 --dx 0] [--repeat N] [--delay-ms M] [--pixels]
//       --repeat posts N wheel events in one gesture (a scripted scroll), with
//       --delay-ms between them (default 0). --pixels counts the deltas in
//       pixels instead of lines, so a check can move a known distance.
//   swift scripts/cgevent-input.swift rclick --window ID
//   swift scripts/cgevent-input.swift bpress --window ID [--button 3] [--dx N --dy N --steps N] [--hold 0.4]
//       an extra mouse button's press: otherMouseDown with
//       kCGMouseEventButtonNumber = button, a held stretch (otherMouseDragged
//       events across --steps) after --hold seconds when --steps is set, then
//       otherMouseUp; button 3 is the usual side Back button
//   swift scripts/cgevent-input.swift move   --window ID --top N   (N pt below the window's top edge, centred)
//   swift scripts/cgevent-input.swift move   --window ID [--dx N --dy N]
//   swift scripts/cgevent-input.swift click  --window ID --top N [--dx N]   (N pt below the top edge)
//   swift scripts/cgevent-input.swift backdrop --file F --seconds N [--virtual]   (--virtual: on the
//                                     e2e app's virtual display, whenever there is one)
//       a plain window over the main screen just below the floating level: above every
//       normal window (the Deck included), behind `--float-windows` stream windows;
//       every click it receives is appended to F as "x y" (Quartz points)
//   swift scripts/cgevent-input.swift moveat  --x N --y N        (absolute Quartz point)
//   swift scripts/cgevent-input.swift clickat --x N --y N
//   swift scripts/cgevent-input.swift rclickat --x N --y N
//   swift scripts/cgevent-input.swift dragat  --x N --y N --x2 N --y2 N [--steps N]
//   swift scripts/cgevent-input.swift axmove --pid N --dx N --dy N [--title TITLE]
//       move the app's windows (or the one titled TITLE) through Accessibility,
//       the path a tiler takes, and print each window's position read back
//   swift scripts/cgevent-input.swift type   --text hi
//   swift scripts/cgevent-input.swift key    --keycode 36 [--cmd] [--shift] [--ctrl] [--option] [--fn] [--hold 0.04]
//   swift scripts/cgevent-input.swift release-all
//       lifts every key the checks press (and the modifiers) plus every mouse
//       button, for a run that finds a key or button left down
//
// A SIGTERM/SIGINT/SIGHUP lifts whatever this process still holds (a held key
// from `key --hold`, a button mid-drag or mid-`bpress`), so a killed run can
// never leave an input down.
//
// Window coordinates are Quartz global coordinates (top-left origin). The
// default `--inset 28` skips the standard title bar so the click lands in the
// window's content area.

import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

struct Target {
    let id: CGWindowID
    let x: Double
    let y: Double
    let width: Double
    let height: Double
}

func argument(_ name: String) -> String? {
    let args = CommandLine.arguments
    guard let index = args.firstIndex(of: name), index + 1 < args.count else { return nil }
    return args[index + 1]
}

func hasFlag(_ name: String) -> Bool { CommandLine.arguments.contains(name) }

func doubleArgument(_ name: String) -> Double? { argument(name).flatMap(Double.init) }

func numberArgument(_ name: String) -> Int? { argument(name).flatMap(Int.init) }

func contiguaWindows(owner: String, pid: Int? = nil) -> [Target] {
    let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
    guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return [] }
    var targets: [Target] = []
    for entry in list {
        guard (entry[kCGWindowOwnerName as String] as? String) == owner,
              // 0 = normal; 3 = floating, the level `--float-windows` gives stream windows.
              [0, 3].contains(entry[kCGWindowLayer as String] as? Int ?? -1),
              let number = entry[kCGWindowNumber as String] as? Int,
              let boundsDict = entry[kCGWindowBounds as String] as? [String: Any],
              let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary) else { continue }
        if let pid, (entry[kCGWindowOwnerPID as String] as? Int) != pid { continue }
        targets.append(Target(id: CGWindowID(number), x: bounds.origin.x, y: bounds.origin.y,
                              width: bounds.width, height: bounds.height))
    }
    return targets.sorted { $0.id < $1.id }
}

func windowWithID(_ id: CGWindowID, owner: String, pid: Int?) -> Target? {
    contiguaWindows(owner: owner, pid: pid).first { $0.id == id }
}

/// The accessible titles (the Dock/⌘-Tab names) of the app's on-screen windows.
func axTitles(appName: String, pid: Int?) -> [String] {
    let process: pid_t? = pid.map(pid_t.init) ?? ownerPID(owner: appName)
    guard let process else { return [] }
    let app = AXUIElementCreateApplication(process)
    var windows: CFTypeRef?
    guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windows) == .success,
          let axWindows = (windows as? [AXUIElement]) else { return [] }
    return axWindows.map { window -> String in
        var title: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &title) == .success,
              let name = title as? String else { return "" }
        return name
    }
}

/// One on-screen window of `owner`: its owning pid.
func ownerPID(owner: String) -> pid_t? {
    let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
    guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return nil }
    for entry in list where (entry[kCGWindowOwnerName as String] as? String) == owner {
        return entry[kCGWindowOwnerPID as String] as? pid_t
    }
    return nil
}

func post(_ event: CGEvent?) {
    event?.post(tap: .cghidEventTap)
}

/// A key or mouse button this process posted down and has not lifted yet.
/// Every one of them must be liftable by a signal or `release-all`: a run that
/// dies between a down and its up leaves the whole Mac repeating that input
/// (a held brightness-down key once ran ControlCenter's hotkey for four hours).
final class HeldInputs {
    static let shared = HeldInputs()
    private let lock = NSLock()
    private var keys: [CGKeyCode: CGEventFlags] = [:]
    private var buttons: [Int32: CGPoint] = [:]

    func hold(keyCode: CGKeyCode, flags: CGEventFlags) {
        lock.lock()
        defer { lock.unlock() }
        keys[keyCode] = flags
    }

    func lift(keyCode: CGKeyCode) {
        lock.lock()
        defer { lock.unlock() }
        keys[keyCode] = nil
    }

    func hold(button: Int32, at point: CGPoint) {
        lock.lock()
        defer { lock.unlock() }
        buttons[button] = point
    }

    func lift(button: Int32) {
        lock.lock()
        defer { lock.unlock() }
        buttons[button] = nil
    }

    /// Everything still held, to release it; the ledger starts empty again so a
    /// second release (a signal during `release-all`) posts no stale ups.
    func takeAll() -> (keys: [CGKeyCode: CGEventFlags], buttons: [Int32: CGPoint]) {
        lock.lock()
        defer { lock.unlock() }
        let taken = (keys: keys, buttons: buttons)
        keys.removeAll()
        buttons.removeAll()
        return taken
    }
}

/// The CGEvent button number behind a CGMouseButton (0 left, 1 right,
/// everything else its own number, which `otherButton` sets as a field).
func buttonNumber(_ button: CGMouseButton) -> Int32 {
    switch button {
    case .left: return 0
    case .right: return 1
    default: return Int32(button.rawValue)
    }
}

func postKeyUp(_ keyCode: CGKeyCode, flags: CGEventFlags = []) {
    guard let event = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false) else { return }
    event.flags = flags
    post(event)
}

func postMouseUp(_ number: Int32, at point: CGPoint) {
    switch number {
    case 0:
        post(CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left))
    case 1:
        post(CGEvent(mouseEventSource: nil, mouseType: .rightMouseUp, mouseCursorPosition: point, mouseButton: .right))
    default:
        post(otherButton(.otherMouseUp, number: number, at: point))
    }
}

func move(to point: CGPoint) {
    post(CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left))
}

func click(_ point: CGPoint, button: CGMouseButton) {
    let down: CGEventType = button == .right ? .rightMouseDown : .leftMouseDown
    let up: CGEventType = button == .right ? .rightMouseUp : .leftMouseUp
    move(to: point)
    usleep(20_000)
    HeldInputs.shared.hold(button: buttonNumber(button), at: point)
    post(CGEvent(mouseEventSource: nil, mouseType: down, mouseCursorPosition: point, mouseButton: button))
    usleep(60_000)
    post(CGEvent(mouseEventSource: nil, mouseType: up, mouseCursorPosition: point, mouseButton: button))
    HeldInputs.shared.lift(button: buttonNumber(button))
}

func drag(from start: CGPoint, dx: Double, dy: Double, steps: Int) {
    move(to: start)
    usleep(30_000)
    HeldInputs.shared.hold(button: 0, at: start)
    post(CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: start, mouseButton: .left))
    for step in 1...max(steps, 1) {
        let fraction = Double(step) / Double(max(steps, 1))
        let point = CGPoint(x: start.x + dx * fraction, y: start.y + dy * fraction)
        post(CGEvent(mouseEventSource: nil, mouseType: .leftMouseDragged, mouseCursorPosition: point, mouseButton: .left))
        usleep(8_000)
    }
    let end = CGPoint(x: start.x + dx, y: start.y + dy)
    post(CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: end, mouseButton: .left))
    HeldInputs.shared.lift(button: 0)
}

func scroll(_ point: CGPoint, dx: Double, dy: Double, pixels: Bool = false) {
    move(to: point)
    usleep(20_000)
    guard let event = CGEvent(scrollWheelEvent2Source: nil, units: pixels ? .pixel : .line,
                              wheelCount: 2,
                              wheel1: Int32(dy), wheel2: Int32(dx), wheel3: 0) else { return }
    event.location = point
    post(event)
}

// otherButton -- an extra mouse button (2 = middle, 3 = the usual side Back
// button, 4 = Forward). CGEvent reads kCGMouseEventButtonNumber, not the
// CGMouseButton enum, so the field is set for buttons it has no enum for.
func otherButton(_ type: CGEventType, number: Int32, at point: CGPoint) -> CGEvent? {
    let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .center)
    event?.setIntegerValueField(.mouseEventButtonNumber, value: Int64(number))
    return event
}

/// A press of extra button `number`: down, an optional held stretch of
/// otherMouseDragged events, then up (NSEvent otherMouseDown/Dragged/Up).
func pressOtherButton(_ point: CGPoint, number: Int32, dx: Double, dy: Double, steps: Int, hold: Double) {
    move(to: point)
    usleep(20_000)
    HeldInputs.shared.hold(button: number, at: point)
    post(otherButton(.otherMouseDown, number: number, at: point))
    usleep(UInt32(hold * 1_000_000))
    if steps > 0 {
        for step in 1...steps {
            let fraction = Double(step) / Double(steps)
            let at = CGPoint(x: point.x + dx * fraction, y: point.y + dy * fraction)
            post(otherButton(.otherMouseDragged, number: number, at: at))
            usleep(8_000)
        }
        post(otherButton(.otherMouseDragged, number: number, at: point))
    }
    post(otherButton(.otherMouseUp, number: number, at: point))
    HeldInputs.shared.lift(button: number)
}

let keyCodes: [Character: CGKeyCode] = [
    "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
    "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19,
    "3": 20, "4": 21, "6": 22, "5": 23, "9": 25, "7": 26, "8": 28, "0": 29, "o": 31,
    "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46,
]

func typeText(_ text: String) {
    for character in text {
        let keyCode = keyCodes[character] ?? 0
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false) else { continue }
        var units = Array(String(character).utf16)
        down.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
        HeldInputs.shared.hold(keyCode: keyCode, flags: [])
        post(down)
        usleep(30_000)
        post(up)
        HeldInputs.shared.lift(keyCode: keyCode)
        usleep(30_000)
    }
}

func pressKey(_ keyCode: CGKeyCode, flags: CGEventFlags = [], hold: Double = 0.04) {
    guard let down = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true),
          let up = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false) else { return }
    down.flags = flags
    up.flags = flags
    HeldInputs.shared.hold(keyCode: keyCode, flags: flags)
    post(down)
    usleep(UInt32(max(hold, 0) * 1_000_000))
    post(up)
    HeldInputs.shared.lift(keyCode: keyCode)
}

/// Every keycode the checks press through this tool (the letters and digits of
/// `keyCodes` plus the keys `key` is called with), the modifiers, and F13–F15 —
/// which no app or system shortcut uses, so a hold test can leave one down
/// without typing anything — so `release-all` can lift a key left down without
/// knowing which one it was.
let rigKeyCodes: [CGKeyCode] = Array(Set(keyCodes.values)).sorted() + [36, 48, 49, 51, 53, 105, 107, 113, 122, 123, 124, 125, 126]

/// Every modifier keycode with the flag its key-down carried.
let modifierKeyCodes: [(CGKeyCode, CGEventFlags)] = [
    (54, .maskCommand), (55, .maskCommand), (56, .maskShift), (57, .maskAlphaShift),
    (58, .maskAlternate), (59, .maskControl), (60, .maskShift), (61, .maskAlternate),
    (62, .maskControl), (63, .maskSecondaryFn),
]

/// Lift everything: what this process still holds, then the whole rig set. A
/// key-up for a key that is not down is harmless, and the sweep covers a hold
/// that a dead process could not record.
func releaseAll() {
    let held = HeldInputs.shared.takeAll()
    for (keyCode, flags) in held.keys {
        postKeyUp(keyCode, flags: flags)
    }
    for (number, point) in held.buttons {
        postMouseUp(number, at: point)
    }
    let point = CGEvent(source: nil)?.location ?? .zero
    for keyCode in rigKeyCodes {
        postKeyUp(keyCode)
    }
    for (keyCode, flags) in modifierKeyCodes {
        postKeyUp(keyCode, flags: flags)
    }
    for number in Int32(0)...Int32(4) {
        postMouseUp(number, at: point)
    }
    // The tap delivers asynchronously; a process that exits at once can leave
    // the last of these queued, and a queued key-up is no key-up.
    usleep(100_000)
}

let owner = argument("--owner") ?? "Contigua"
let inset = doubleArgument("--inset") ?? 28
let pid = numberArgument("--pid")

guard AXIsProcessTrusted() else {
    FileHandle.standardError.write(Data("cgevent-input: not trusted for Accessibility; events will be dropped.\n".utf8))
    exit(2)
}

// Lift everything held when the process is asked to stop. sigwait on a thread
// of its own keeps CGEvent out of a signal handler, where it must not run.
// The set is never freed: the thread and the process end together.
let caughtSignals = UnsafeMutablePointer<sigset_t>.allocate(capacity: 1)
sigemptyset(caughtSignals)
for signalNumber in [SIGTERM, SIGINT, SIGHUP] {
    sigaddset(caughtSignals, signalNumber)
}
pthread_sigmask(SIG_BLOCK, caughtSignals, nil)
Thread.detachNewThread {
    var received: Int32 = 0
    sigwait(caughtSignals, &received)
    releaseAll()
    exit(0)
}

switch CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "" {
case "release-all":
    releaseAll()
case "list":
    for target in contiguaWindows(owner: owner, pid: pid) {
        print("\(target.id)\t\(Int(target.x)) \(Int(target.y)) \(Int(target.width)) \(Int(target.height))")
    }
case "titles":
    // The AX title of every window of the app (the Dock/⌘-Tab name the
    // window carries): one per line, so checks can grep for it.
    for title in axTitles(appName: owner, pid: pid) {
        print(title.isEmpty ? "-" : title)
    }
case "all":
    // Debug aid: every on-screen window with owner, pid, layer and bounds.
    // Bounds are printed as one "{{x, y}, {w, h}}" line (a CGWindowBounds
    // dictionary's own description spans lines, which a check's parser cannot
    // read): the menu shot's help-tag probe asks for the new window's bounds.
    for entry in (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? [] {
        var bounds = "?"
        if let dict = entry[kCGWindowBounds as String] as? [String: Any],
           let rect = CGRect(dictionaryRepresentation: dict as CFDictionary) {
            bounds = "{{\(Int(rect.origin.x)), \(Int(rect.origin.y))}, {\(Int(rect.width)), \(Int(rect.height))}}"
        }
        print("owner=\(entry[kCGWindowOwnerName as String] ?? "?") pid=\(entry[kCGWindowOwnerPID as String] ?? "?") id=\(entry[kCGWindowNumber as String] ?? "?") layer=\(entry[kCGWindowLayer as String] ?? "?") bounds=\(bounds)")
    }
case "moveat", "clickat", "rclickat", "dragat":
    // Absolute Quartz points, for a window the CG list cannot see (the
    // status-item panel) or a SwiftUI control inside a window (the rail).
    guard let x = doubleArgument("--x"), let y = doubleArgument("--y") else {
        FileHandle.standardError.write(Data("cgevent-input: moveat/clickat/rclickat/dragat need --x and --y\n".utf8))
        exit(1)
    }
    switch CommandLine.arguments[1] {
    case "moveat":
        move(to: CGPoint(x: x, y: y))
    case "clickat":
        click(CGPoint(x: x, y: y), button: .left)
    case "rclickat":
        click(CGPoint(x: x, y: y), button: .right)
    default:
        guard let x2 = doubleArgument("--x2"), let y2 = doubleArgument("--y2") else {
            FileHandle.standardError.write(Data("cgevent-input: dragat needs --x2 and --y2\n".utf8))
            exit(1)
        }
        drag(from: CGPoint(x: x, y: y), dx: x2 - x, dy: y2 - y,
             steps: numberArgument("--steps") ?? 20)
    }
case "click", "rclick", "drag", "scroll", "move", "bpress":
    guard let id = numberArgument("--window"), let target = windowWithID(CGWindowID(id), owner: owner, pid: pid) else {
        FileHandle.standardError.write(Data("cgevent-input: no such window\n".utf8))
        exit(1)
    }
    let dx = doubleArgument("--dx") ?? 0
    let dy = doubleArgument("--dy") ?? 0
    let centerY = target.y + inset + (target.height - inset) / 2
    let center = CGPoint(x: target.x + target.width / 2, y: centerY)
    let point = CGPoint(x: center.x + dx, y: center.y + dy)
    switch CommandLine.arguments[1] {
    case "click":
        if let top = doubleArgument("--top") {
            click(CGPoint(x: center.x + dx, y: target.y + top), button: .left)
        } else {
            click(point, button: .left)
        }
    case "rclick": click(point, button: .right)
    case "bpress":
        pressOtherButton(point, number: Int32(numberArgument("--button") ?? 3),
                         dx: dx, dy: dy, steps: numberArgument("--steps") ?? 0,
                         hold: doubleArgument("--hold") ?? 0.08)
    case "drag":
        // `--right-edge`: grab the window's right edge (a resize) instead of its centre;
        // `--top N`: grab N pt below the window's top edge (the framed bar, a window move).
        let start: CGPoint
        if hasFlag("--right-edge") {
            start = CGPoint(x: target.x + target.width, y: center.y)
        } else if let top = doubleArgument("--top") {
            start = CGPoint(x: center.x + dx, y: target.y + top)
        } else {
            start = center
        }
        drag(from: start, dx: dx, dy: dy, steps: numberArgument("--steps") ?? 20)
    case "scroll":
        // A scripted scroll: one process posts the whole gesture, so a check
        // can span a folder of thousands of icons without spawning a process
        // per line.
        let times = max(1, numberArgument("--repeat") ?? 1)
        let pause = UInt32(max(0, numberArgument("--delay-ms") ?? 0)) * 1000
        let pixels = hasFlag("--pixels")
        for _ in 0..<times {
            scroll(point, dx: dx, dy: dy, pixels: pixels)
            if pause > 0 { usleep(pause) }
        }
    case "move":
        if let top = doubleArgument("--top") {
            move(to: CGPoint(x: center.x + dx, y: target.y + top))
        } else {
            move(to: point)
        }
    default: break
    }
case "axresize":
    // axresize --width W --height H [--pid N]: set every window of the app to
    // that size through Accessibility (the path a tiler or a script takes),
    // then print one "title<TAB>WxH" line per window with the size read back.
    guard let process = pid.map(pid_t.init) ?? ownerPID(owner: owner) else {
        print("noproc")
        exit(2)
    }
    let app = AXUIElementCreateApplication(process)
    var windowsValue: CFTypeRef?
    guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windowsValue) == .success,
          let axWindows = windowsValue as? [AXUIElement], !axWindows.isEmpty else {
        print("nowindows")
        exit(2)
    }
    let wantSize = CGSize(width: doubleArgument("--width") ?? 4000,
                          height: doubleArgument("--height") ?? 4000)
    for window in axWindows {
        var title: CFTypeRef?
        AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &title)
        let name = (title as? String) ?? "-"
        var asked = wantSize
        if let value = AXValueCreate(.cgSize, &asked) {
            _ = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, value)
        }
        usleep(600_000)
        var actual = CGSize.zero
        var readBack: CFTypeRef?
        if AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &readBack) == .success,
           let readBack, CFGetTypeID(readBack) == AXValueGetTypeID() {
            AXValueGetValue(unsafeBitCast(readBack, to: AXValue.self), .cgSize, &actual)
        }
        print("\(name)\t\(Int(actual.width))x\(Int(actual.height))")
    }
case "axmove":
    // axmove --pid N --dx D --dy D [--title TITLE]: move the app's windows (or
    // just the one whose AX title is TITLE) by that delta through Accessibility
    // — the path a tiler or a script takes — then print one "title<TAB>x,y" line
    // per window with the position read back. AX axes are top-left, y down.
    guard let process = pid.map(pid_t.init) ?? ownerPID(owner: owner) else {
        print("noproc")
        exit(2)
    }
    let app = AXUIElementCreateApplication(process)
    var moveWindowsValue: CFTypeRef?
    guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &moveWindowsValue) == .success,
          let moveWindows = moveWindowsValue as? [AXUIElement], !moveWindows.isEmpty else {
        print("nowindows")
        exit(2)
    }
    let wantTitle = argument("--title")
    let moveX = doubleArgument("--dx") ?? 0
    let moveY = doubleArgument("--dy") ?? 0
    for window in moveWindows {
        var title: CFTypeRef?
        AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &title)
        let name = (title as? String) ?? "-"
        if let wantTitle, name != wantTitle { continue }
        var origin = CGPoint.zero
        var originValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &originValue) == .success,
           let originValue, CFGetTypeID(originValue) == AXValueGetTypeID() {
            AXValueGetValue(unsafeBitCast(originValue, to: AXValue.self), .cgPoint, &origin)
        }
        var target = CGPoint(x: origin.x + moveX, y: origin.y + moveY)
        if let value = AXValueCreate(.cgPoint, &target) {
            _ = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value)
        }
        usleep(400_000)
        var actual = CGPoint.zero
        var readBack: CFTypeRef?
        if AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &readBack) == .success,
           let readBack, CFGetTypeID(readBack) == AXValueGetTypeID() {
            AXValueGetValue(unsafeBitCast(readBack, to: AXValue.self), .cgPoint, &actual)
        }
        print("\(name)\t\(Int(actual.x)),\(Int(actual.y))")
    }
case "backdrop":
    guard let file = argument("--file") else { exit(1) }
    let seconds = doubleArgument("--seconds") ?? 30
    final class Catcher: NSView {
        let file: String
        init(file: String) { self.file = file; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError() }
        override func draw(_ dirtyRect: NSRect) {
            NSColor(srgbRed: 0.18, green: 0.45, blue: 0.85, alpha: 1).setFill()
            dirtyRect.fill()
        }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) {
            let p = NSEvent.mouseLocation
            let height = NSScreen.screens.first?.frame.height ?? 0
            let line = "\(Int(p.x)) \(Int(height - p.y))\n"
            if let handle = FileHandle(forWritingAtPath: file) {
                handle.seekToEndOfFile(); handle.write(Data(line.utf8)); handle.closeFile()
            }
        }
    }
    FileManager.default.createFile(atPath: file, contents: nil)
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let frame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 800, height: 600)
    let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = Catcher(file: file)
    window.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue - 1)
    if hasFlag("--virtual") {
        // Quiet runs: behind the windows on the e2e app's virtual display
        // (VirtualDisplay.swift's ids), which comes and goes with each launch.
        func virtualScreen() -> NSScreen? {
            NSScreen.screens.first { screen in
                guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { return false }
                return CGDisplayVendorNumber(id) == 0x5044 && CGDisplayModelNumber(id) == 0xE2E0
            }
        }
        Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in
            if let screen = virtualScreen() {
                if window.frame != screen.visibleFrame { window.setFrame(screen.visibleFrame, display: true) }
                if !window.isVisible { window.orderFrontRegardless() }
            } else if window.isVisible {
                window.orderOut(nil)
            }
        }
    } else {
        window.orderFrontRegardless()
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { exit(0) }
    app.run()
case "type":
    typeText(argument("--text") ?? "")
case "key":
    guard let code = numberArgument("--keycode") else {
        FileHandle.standardError.write(Data("cgevent-input: key needs --keycode\n".utf8))
        exit(1)
    }
    var keyFlags: CGEventFlags = []
    if hasFlag("--cmd") { keyFlags.insert(.maskCommand) }
    if hasFlag("--shift") { keyFlags.insert(.maskShift) }
    if hasFlag("--ctrl") { keyFlags.insert(.maskControl) }
    if hasFlag("--option") { keyFlags.insert(.maskAlternate) }
    // fn-F is the system's own full-screen shortcut; the globe key is
    // maskSecondaryFn, which AppKit reads as the function modifier.
    if hasFlag("--fn") { keyFlags.insert(.maskSecondaryFn) }
    pressKey(CGKeyCode(code), flags: keyFlags, hold: doubleArgument("--hold") ?? 0.04)
default:
    FileHandle.standardError.write(Data("usage: cgevent-input.swift list|release-all|click|rclick|clickat|rclickat|drag|scroll|type|key ...\n".utf8))
    exit(1)
}
