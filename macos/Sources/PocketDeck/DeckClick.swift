// `deckclick LABEL` (e2e, --debug-control): a click at a Deck cell's own drawn
// place, through the Deck window's event handling. The grid draws its cells as
// SwiftUI controls, so there is no NSView to hand an event to: the cell's frame
// comes from the accessibility tree (what a screen reader reads), and the
// mouse events go to the window, the same route a pointer's click takes.
// A route that called `openOrRaise` would prove the action, not the cell.

import AppKit
import ApplicationServices

enum DeckCellClick {
    /// Clicks the cell whose accessibility label is `label`. Returns why it
    /// could not, or nil when the click was delivered.
    @MainActor
    static func click(label: String, in window: NSWindow) -> String? {
        guard let cell = findCell(label: label), let frame = screenFrame(of: cell) else {
            return "no Deck cell labelled \(label)"
        }
        // Accessibility reports the main screen's top-left origin; AppKit's
        // screen space starts at its bottom-left.
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        let screenPoint = NSPoint(x: frame.midX, y: top - frame.midY)
        let point = window.convertPoint(fromScreen: screenPoint)
        guard let down = mouse(.leftMouseDown, at: point, in: window),
              let up = mouse(.leftMouseUp, at: point, in: window) else {
            return "could not build the click"
        }
        window.sendEvent(down)
        window.sendEvent(up)
        // Let SwiftUI run the button's action before the caller reads state.
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.25))
        return nil
    }

    /// The cell's centre in Quartz global coordinates (the top-left origin the
    /// window server uses), for a check that posts a real right click there: a
    /// SwiftUI context menu only tracks for a pointer's own click.
    @MainActor
    static func centre(label: String) -> CGPoint? {
        guard let cell = findCell(label: label), let frame = screenFrame(of: cell) else { return nil }
        return CGPoint(x: frame.midX, y: frame.midY)
    }

    /// Opens the cell's own context menu with a secondary click at the cell's
    /// drawn place, through the window's event handling (a quiet shot cannot
    /// use the pointer). The menu tracks the run loop, so the click is queued
    /// and the caller returns at once; the caller closes the app afterwards.
    @MainActor
    static func menu(label: String, in window: NSWindow) -> String? {
        guard let cell = findCell(label: label), let frame = screenFrame(of: cell) else {
            return "no Deck cell labelled \(label)"
        }
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        let screenPoint = NSPoint(x: frame.midX, y: top - frame.midY)
        let point = window.convertPoint(fromScreen: screenPoint)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { // gcd: a context menu tracks the run loop, so the click is one turn later
            for type in [NSEvent.EventType.rightMouseDown, .rightMouseUp] {
                guard let event = mouse(type, at: point, in: window) else { return }
                window.sendEvent(event)
            }
        }
        return nil
    }

    private static func mouse(_ type: NSEvent.EventType, at point: NSPoint,
                              in window: NSWindow) -> NSEvent? {
        NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                           timestamp: ProcessInfo.processInfo.systemUptime,
                           windowNumber: window.windowNumber, context: nil,
                           eventNumber: 0, clickCount: 1, pressure: 1)
    }

    /// The accessible button for an app's cell, looked up in this process.
    private static func findCell(label: String) -> AXUIElement? {
        find(AXUIElementCreateApplication(getpid()), label: label, depth: 0)
    }

    private static func find(_ element: AXUIElement, label: String, depth: Int) -> AXUIElement? {
        guard depth < 20 else { return nil }
        let role = text(element, kAXRoleAttribute)
        let names = [text(element, kAXTitleAttribute),
                     text(element, kAXDescriptionAttribute),
                     text(element, "AXIdentifier")]
        if role == (kAXButtonRole as String), names.contains(label) { return element }
        var children: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success,
              let kids = children as? [AXUIElement] else { return nil }
        for child in kids {
            if let hit = find(child, label: label, depth: depth + 1) { return hit }
        }
        return nil
    }

    private static func text(_ element: AXUIElement, _ name: String) -> String {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return "" }
        return value as? String ?? ""
    }

    private static func screenFrame(of element: AXUIElement) -> CGRect? {
        var position: CFTypeRef?
        var size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &position) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &size) == .success,
              let position, let size,
              CFGetTypeID(position) == AXValueGetTypeID(),
              CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        // The type ID above is the cast's own check: AXValue is the only CF
        // type behind these two attributes.
        let value: AXValue = unsafeBitCast(position, to: AXValue.self)
        let extent: AXValue = unsafeBitCast(size, to: AXValue.self)
        var origin = CGPoint.zero
        var measure = CGSize.zero
        guard AXValueGetValue(value, .cgPoint, &origin),
              AXValueGetValue(extent, .cgSize, &measure),
              measure.width > 0, measure.height > 0 else { return nil }
        return CGRect(origin: origin, size: measure)
    }
}
