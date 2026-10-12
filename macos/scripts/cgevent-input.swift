// cgevent-input.swift — synthesize real mouse/keyboard events at a PocketDeck
// window's coordinates so the automated checks exercise the same code path as a
// human (NSEvent -> InputMapper -> protocol).
//
// Usage:
//   swift scripts/cgevent-input.swift list
//   swift scripts/cgevent-input.swift all
//   swift scripts/cgevent-input.swift click  --window ID [--dx N --dy N]
//   swift scripts/cgevent-input.swift drag   --window ID --dx 200 --dy 0 [--steps 20]
//   swift scripts/cgevent-input.swift scroll --window ID [--dy 3 --dx 0]
//   swift scripts/cgevent-input.swift rclick --window ID
//   swift scripts/cgevent-input.swift type   --text hi
//   swift scripts/cgevent-input.swift key    --keycode 36 [--cmd]
//
// Window coordinates are Quartz global coordinates (top-left origin). The
// default `--inset 28` skips the standard title bar so the click lands in the
// window's content area.

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

func doubleArgument(_ name: String) -> Double? { argument(name).flatMap(Double.init) }

func numberArgument(_ name: String) -> Int? { argument(name).flatMap(Int.init) }

func pocketDeckWindows(owner: String, pid: Int? = nil) -> [Target] {
    let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
    guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return [] }
    var targets: [Target] = []
    for entry in list {
        guard (entry[kCGWindowOwnerName as String] as? String) == owner,
              (entry[kCGWindowLayer as String] as? Int) == 0,
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
    pocketDeckWindows(owner: owner, pid: pid).first { $0.id == id }
}

func post(_ event: CGEvent?) {
    event?.post(tap: .cghidEventTap)
}

func move(to point: CGPoint) {
    post(CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left))
}

func click(_ point: CGPoint, button: CGMouseButton) {
    let down: CGEventType = button == .right ? .rightMouseDown : .leftMouseDown
    let up: CGEventType = button == .right ? .rightMouseUp : .leftMouseUp
    move(to: point)
    usleep(20_000)
    post(CGEvent(mouseEventSource: nil, mouseType: down, mouseCursorPosition: point, mouseButton: button))
    usleep(60_000)
    post(CGEvent(mouseEventSource: nil, mouseType: up, mouseCursorPosition: point, mouseButton: button))
}

func drag(from start: CGPoint, dx: Double, dy: Double, steps: Int) {
    move(to: start)
    usleep(30_000)
    post(CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: start, mouseButton: .left))
    for step in 1...max(steps, 1) {
        let fraction = Double(step) / Double(max(steps, 1))
        let point = CGPoint(x: start.x + dx * fraction, y: start.y + dy * fraction)
        post(CGEvent(mouseEventSource: nil, mouseType: .leftMouseDragged, mouseCursorPosition: point, mouseButton: .left))
        usleep(8_000)
    }
    let end = CGPoint(x: start.x + dx, y: start.y + dy)
    post(CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: end, mouseButton: .left))
}

func scroll(_ point: CGPoint, dx: Double, dy: Double) {
    move(to: point)
    usleep(20_000)
    guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 2,
                              wheel1: Int32(dy), wheel2: Int32(dx), wheel3: 0) else { return }
    event.location = point
    post(event)
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
        post(down)
        usleep(30_000)
        post(up)
        usleep(30_000)
    }
}

func pressKey(_ keyCode: CGKeyCode, flags: CGEventFlags = []) {
    guard let down = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true),
          let up = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false) else { return }
    down.flags = flags
    up.flags = flags
    post(down)
    usleep(40_000)
    post(up)
}

let owner = argument("--owner") ?? "PocketDeck"
let inset = doubleArgument("--inset") ?? 28
let pid = numberArgument("--pid")

guard AXIsProcessTrusted() else {
    FileHandle.standardError.write(Data("cgevent-input: not trusted for Accessibility; events will be dropped.\n".utf8))
    exit(2)
}

switch CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "" {
case "list":
    for target in pocketDeckWindows(owner: owner, pid: pid) {
        print("\(target.id)\t\(Int(target.x)) \(Int(target.y)) \(Int(target.width)) \(Int(target.height))")
    }
case "all":
    // Debug aid: every on-screen window with owner, pid, layer and bounds.
    for entry in (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? [] {
        print("owner=\(entry[kCGWindowOwnerName as String] ?? "?") pid=\(entry[kCGWindowOwnerPID as String] ?? "?") id=\(entry[kCGWindowNumber as String] ?? "?") layer=\(entry[kCGWindowLayer as String] ?? "?") bounds=\(entry[kCGWindowBounds as String] ?? "?")")
    }
case "click", "rclick", "drag", "scroll":
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
    case "click": click(point, button: .left)
    case "rclick": click(point, button: .right)
    case "drag": drag(from: center, dx: dx, dy: dy, steps: numberArgument("--steps") ?? 20)
    case "scroll": scroll(point, dx: dx, dy: dy)
    default: break
    }
case "type":
    typeText(argument("--text") ?? "")
case "key":
    guard let code = numberArgument("--keycode") else {
        FileHandle.standardError.write(Data("cgevent-input: key needs --keycode\n".utf8))
        exit(1)
    }
    pressKey(CGKeyCode(code), flags: argument("--cmd") != nil ? .maskCommand : [])
default:
    FileHandle.standardError.write(Data("usage: cgevent-input.swift list|click|drag|scroll|rclick|type ...\n".utf8))
    exit(1)
}
