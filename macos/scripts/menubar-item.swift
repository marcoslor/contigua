// menubar-item.swift — the menu bar item of one PocketDeck process, for the
// real-click check (scripts/menubar-toggle.sh).
//
// The item is not in the app's window list: it is an accessibility child of
// AXExtrasMenuBar. Finding it by the process id (never by its title) is the
// rule the checks follow: the person's own PocketDeck item is right next to it.
//
// Usage:
//   swift scripts/menubar-item.swift frame PID
//       "x y width height" of the item, in Quartz global coordinates.
//   swift scripts/menubar-item.swift click PID [HOLD_MS]
//       a real click (CGEvent through the window server) at its centre;
//       HOLD_MS is the mouse-down stretch, 90 ms by default.
//   swift scripts/menubar-item.swift rclick PID [HOLD_MS]
//       the same click with the right button: the item's secondary click.
//   swift scripts/menubar-item.swift panel PID
//       "shown" when the app has an on-screen window at the status bar level
//       (its menu bar panel), "gone" otherwise.
//   swift scripts/menubar-item.swift menu PID
//       "shown" when the app has an open menu (a window above the panel's
//       level), "gone" otherwise.
//   swift scripts/menubar-item.swift layers PID
//       every on-screen window of the process: "id layer x y w h", for a failed
//       answer above.

import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

func number(_ index: Int) -> pid_t? {
    let args = CommandLine.arguments
    guard args.count > index, let value = pid_t(args[index]) else { return nil }
    return value
}

/// The item's element: the first child of the app's extras menu bar.
func statusItem(_ pid: pid_t) -> AXUIElement? {
    let app = AXUIElementCreateApplication(pid)
    var bar: CFTypeRef?
    guard AXUIElementCopyAttributeValue(app, "AXExtrasMenuBar" as CFString, &bar) == .success,
          let bar else { return nil }
    var children: CFTypeRef?
    guard AXUIElementCopyAttributeValue(bar as! AXUIElement, kAXChildrenAttribute as CFString, &children) == .success,
          let items = children as? [AXUIElement] else { return nil }
    return items.first
}

func frame(_ pid: pid_t) -> CGRect? {
    guard let item = statusItem(pid) else { return nil }
    var position: CFTypeRef?
    var size: CFTypeRef?
    guard AXUIElementCopyAttributeValue(item, kAXPositionAttribute as CFString, &position) == .success,
          AXUIElementCopyAttributeValue(item, kAXSizeAttribute as CFString, &size) == .success,
          let position, let size else { return nil }
    var point = CGPoint.zero
    var extent = CGSize.zero
    AXValueGetValue(position as! AXValue, .cgPoint, &point)
    AXValueGetValue(size as! AXValue, .cgSize, &extent)
    return CGRect(origin: point, size: extent)
}

func shown(_ pid: pid_t, levels: Range<Int>, minSize: CGSize = .zero) -> Bool {
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
        as? [[String: Any]] ?? []
    return list.contains { entry in
        guard (entry[kCGWindowOwnerPID as String] as? pid_t) == pid,
              levels.contains((entry[kCGWindowLayer as String] as? Int) ?? 0),
              let bounds = entry[kCGWindowBounds as String] as? [String: Any],
              let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return false }
        return rect.width >= minSize.width && rect.height >= minSize.height
    }
}

/// The panel is level .statusBar (25); a menu is far above it (101), so the two
/// never answer for each other. The menu's size floor keeps the item's tooltip
/// (also above the panel, but one line tall) out of the answer.
func panelShown(_ pid: pid_t) -> Bool { shown(pid, levels: 25..<100) }
func menuShown(_ pid: pid_t) -> Bool {
    shown(pid, levels: 100..<1000, minSize: CGSize(width: 100, height: 60))
}

func click(_ point: CGPoint, hold: UInt32, button: CGMouseButton = .left) {
    func post(_ type: CGEventType) {
        CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: button)?
            .post(tap: .cghidEventTap)
    }
    post(.mouseMoved)
    usleep(30_000)
    post(button == .right ? .rightMouseDown : .leftMouseDown)
    usleep(hold * 1000)
    post(button == .right ? .rightMouseUp : .leftMouseUp)
}

switch CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "" {
case "frame":
    guard let pid = number(2), let rect = frame(pid) else { exit(1) }
    print("\(Int(rect.origin.x)) \(Int(rect.origin.y)) \(Int(rect.width)) \(Int(rect.height))")
case "click":
    guard let pid = number(2), let rect = frame(pid) else { exit(1) }
    let hold = CommandLine.arguments.count > 3 ? UInt32(CommandLine.arguments[3]) ?? 90 : 90
    click(CGPoint(x: rect.midX, y: rect.midY), hold: hold)
case "rclick":
    guard let pid = number(2), let rect = frame(pid) else { exit(1) }
    let hold = CommandLine.arguments.count > 3 ? UInt32(CommandLine.arguments[3]) ?? 90 : 90
    click(CGPoint(x: rect.midX, y: rect.midY), hold: hold, button: .right)
case "panel":
    guard let pid = number(2) else { exit(1) }
    print(panelShown(pid) ? "shown" : "gone")
case "menu":
    guard let pid = number(2) else { exit(1) }
    print(menuShown(pid) ? "shown" : "gone")
case "layers":
    guard let pid = number(2) else { exit(1) }
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
        as? [[String: Any]] ?? []
    for entry in list where (entry[kCGWindowOwnerPID as String] as? pid_t) == pid {
        let layer = entry[kCGWindowLayer as String] as? Int ?? -1
        let number = entry[kCGWindowNumber as String] as? Int ?? -1
        let bounds = (entry[kCGWindowBounds as String] as? [String: Any]).flatMap {
            CGRect(dictionaryRepresentation: $0 as CFDictionary)
        } ?? .zero
        print("\(number) \(layer) \(Int(bounds.minX)) \(Int(bounds.minY)) \(Int(bounds.width)) \(Int(bounds.height))")
    }
default:
    FileHandle.standardError.write(Data("usage: frame|click|rclick|panel|menu|layers PID\n".utf8))
    exit(2)
}
