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
//   swift scripts/menubar-item.swift panel PID
//       "shown" when the app has an on-screen window at the status bar level
//       (its menu bar panel), "gone" otherwise.

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

func panelShown(_ pid: pid_t) -> Bool {
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
        as? [[String: Any]] ?? []
    return list.contains { entry in
        (entry[kCGWindowOwnerPID as String] as? pid_t) == pid
            && ((entry[kCGWindowLayer as String] as? Int) ?? 0) >= 25
    }
}

func click(_ point: CGPoint, hold: UInt32) {
    func post(_ type: CGEventType) {
        CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)?
            .post(tap: .cghidEventTap)
    }
    post(.mouseMoved)
    usleep(30_000)
    post(.leftMouseDown)
    usleep(hold * 1000)
    post(.leftMouseUp)
}

switch CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "" {
case "frame":
    guard let pid = number(2), let rect = frame(pid) else { exit(1) }
    print("\(Int(rect.origin.x)) \(Int(rect.origin.y)) \(Int(rect.width)) \(Int(rect.height))")
case "click":
    guard let pid = number(2), let rect = frame(pid) else { exit(1) }
    let hold = CommandLine.arguments.count > 3 ? UInt32(CommandLine.arguments[3]) ?? 90 : 90
    click(CGPoint(x: rect.midX, y: rect.midY), hold: hold)
case "panel":
    guard let pid = number(2) else { exit(1) }
    print(panelShown(pid) ? "shown" : "gone")
default:
    FileHandle.standardError.write(Data("usage: frame|click|panel PID\n".utf8))
    exit(2)
}
