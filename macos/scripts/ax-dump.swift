// ax-dump.swift — what a screen reader hears inside one process's windows.
//
// SwiftUI publishes a control's VoiceOver name and help tag to the accessibility
// server, not to the NSViews a test can walk in-process, so a check reads them
// through AX. The server talks per element, not `entire contents`: this asks for
// each window's children and prints one line per element that carries a title,
// a description, a help text or an identifier.
//
// Usage:
//   swift scripts/ax-dump.swift PID [--press TITLE]
//       AXWindow/AXButton/… title=[…] desc=[…] help=[…] id=[…], one per line.
//       Exits 1 with NO-WINDOWS when the process exposes none.
//   --press TITLE additionally activates (AXPress) the first button whose
//       title, description or accessibility label is TITLE: a screen reader's
//       own press of that control, for a check whose button is a SwiftUI one.
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
    // A label's words ride AXValue (a static text has no title); including it
    // lets a check read what the cover says, not only what a button is called.
    let value = text(element, kAXValueAttribute)
    // A disabled control is the difference the Deck's offline state makes
    // (PAIR-33/R1): read it, never infer it from opacity.
    var enabledValue: CFTypeRef?
    let enabled = AXUIElementCopyAttributeValue(element, kAXEnabledAttribute as CFString, &enabledValue) == .success
        ? enabledValue as? Bool : nil
    // A button's enabled state is the difference the Deck's offline look makes
    // (PAIR-33/R1) and the cooldown's Try Again (R2), so it is always named
    // for buttons; a disabled other control is named too.
    let enabledMark: String
    if enabled == false { enabledMark = " enabled=[0]" }
    else if enabled == true, role == (kAXButtonRole as String) { enabledMark = " enabled=[1]" }
    else { enabledMark = "" }
    if !title.isEmpty || !description.isEmpty || !help.isEmpty || !identifier.isEmpty || !value.isEmpty {
        print("\(String(repeating: "  ", count: depth))\(role) title=[\(title)] desc=[\(description)] help=[\(help)] id=[\(identifier)] value=[\(value)]\(enabledMark)")
    }
    var children: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success,
          let kids = children as? [AXUIElement] else { return }
    for child in kids { walk(child, depth + 1) }
}

let arguments = CommandLine.arguments
guard arguments.count > 1, let pid = pid_t(arguments[1]) else {
    FileHandle.standardError.write(Data("usage: ax-dump.swift PID [--press TITLE]\n".utf8))
    exit(2)
}
var pressTarget: String?
if let flag = arguments.firstIndex(of: "--press"), arguments.count > flag + 1 {
    pressTarget = arguments[flag + 1]
}

/// The first button under `element` whose name is `title`.
func button(_ element: AXUIElement, named title: String, depth: Int = 0) -> AXUIElement? {
    guard depth < 20 else { return nil }
    let role = text(element, kAXRoleAttribute)
    let names = [text(element, kAXTitleAttribute), text(element, kAXDescriptionAttribute),
                 text(element, "AXIdentifier")]
    if role == (kAXButtonRole as String), names.contains(title) { return element }
    var children: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success,
          let kids = children as? [AXUIElement] else { return nil }
    for child in kids {
        if let hit = button(child, named: title, depth: depth + 1) { return hit }
    }
    return nil
}
let app = AXUIElementCreateApplication(pid)
var windows: CFTypeRef?
guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windows) == .success,
      let list = windows as? [AXUIElement], !list.isEmpty else {
    print("NO-WINDOWS")
    exit(1)
}
for window in list { walk(window, 0) }
if let pressTarget {
    guard let target = button(app, named: pressTarget) else {
        print("NO-BUTTON \(pressTarget)")
        exit(1)
    }
    guard AXUIElementPerformAction(target, kAXPressAction as CFString) == .success else {
        print("PRESS-FAILED \(pressTarget)")
        exit(1)
    }
    print("PRESSED \(pressTarget)")
}
