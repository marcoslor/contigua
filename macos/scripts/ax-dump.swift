// ax-dump.swift — what a screen reader hears inside one process's windows.
//
// SwiftUI publishes a control's VoiceOver name and help tag to the accessibility
// server, not to the NSViews a test can walk in-process, so a check reads them
// through AX. The server talks per element, not `entire contents`: this asks for
// each window's children and prints one line per element that carries a title,
// a description, a help text or an identifier.
//
// Usage:
//   swift scripts/ax-dump.swift PID
//       AXWindow/AXButton/… title=[…] desc=[…] help=[…] id=[…], one per line.
//       Exits 1 with NO-WINDOWS when the process exposes none.
//
// The app's elements carry their SwiftUI identifiers (`panel.gear`,
// `panel.dnd`, …), so a check can name the control it means instead of its
// position. Read-only: nothing is pressed.

import AppKit
import ApplicationServices
import Foundation

func text(_ element: AXUIElement, _ name: String) -> String {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return "" }
    return value as? String ?? ""
}

func walk(_ element: AXUIElement, _ depth: Int) {
    guard depth < 14 else { return }
    let role = text(element, kAXRoleAttribute)
    let title = text(element, kAXTitleAttribute)
    let description = text(element, kAXDescriptionAttribute)
    let help = text(element, kAXHelpAttribute)
    let identifier = text(element, "AXIdentifier")
    if !title.isEmpty || !description.isEmpty || !help.isEmpty || !identifier.isEmpty {
        print("\(String(repeating: "  ", count: depth))\(role) title=[\(title)] desc=[\(description)] help=[\(help)] id=[\(identifier)]")
    }
    var children: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success,
          let kids = children as? [AXUIElement] else { return }
    for child in kids { walk(child, depth + 1) }
}

let arguments = CommandLine.arguments
guard arguments.count > 1, let pid = pid_t(arguments[1]) else {
    FileHandle.standardError.write(Data("usage: ax-dump.swift PID\n".utf8))
    exit(2)
}
let app = AXUIElementCreateApplication(pid)
var windows: CFTypeRef?
guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windows) == .success,
      let list = windows as? [AXUIElement], !list.isEmpty else {
    print("NO-WINDOWS")
    exit(1)
}
for window in list { walk(window, 0) }
