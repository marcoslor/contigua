// The Settings window's real geometry, for the host e2e (--debug-control
// `settings-dump PATH`). A grouped Form reports an ideal height the window
// used to take; on a short screen the rows below the fold were clipped and the
// tab could not scroll. The dump answers what a person sees: how tall the
// window is for the screen, whether the tab's rows live in a scroll view
// taller than its clip, whether a scroll moves it, and whether the last row is
// on screen once it is at the end.

import AppKit

enum SettingsProbe {
    /// The report, one `key=value` per line. `lastRow` is the label to look
    /// for (the last control of the open tab).
    @MainActor
    static func report(window: NSWindow, lastRow label: String) -> String {
        let frame = window.frame
        let visible = (window.screen ?? NSScreen.main)?.visibleFrame.height ?? 0
        var lines = [
            "window=\(Int(frame.width.rounded()))x\(Int(frame.height.rounded()))",
            "content=\(Int((window.contentView?.frame.height ?? 0).rounded()))",
            "cap=\(Int(SettingsLayout.maxContentHeight(for: visible).rounded()))",
            "visible=\(Int(visible.rounded()))",
            "fits=\(frame.height <= visible + 0.5 ? 1 : 0)",
        ]
        guard let content = window.contentView else { return lines.joined(separator: "\n") + "\n" }
        content.layoutSubtreeIfNeeded()
        let scrolls = descendants(of: content).compactMap { $0 as? NSScrollView }
        guard let scroll = scrolls.max(by: { ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0) }),
              let document = scroll.documentView else {
            return (lines + ["scroll=0"]).joined(separator: "\n") + "\n"
        }
        let clip = scroll.contentView
        lines.append("scroll=1")
        lines.append("doc=\(Int(document.frame.height.rounded()))")
        lines.append("clip=\(Int(clip.bounds.height.rounded()))")
        // A person's two-finger scroll first: the clip must move when the
        // content is taller than the window.
        let before = clip.bounds.origin.y
        let centre = scroll.convert(NSPoint(x: scroll.bounds.midX, y: scroll.bounds.midY), to: nil)
        let events = wheelEvents(dy: -40, at: centre)
        if let first = events.first {
            lines.append("wheel_dy=\(Int(first.scrollingDeltaY.rounded()))")
            lines.append("wheel_window=\(first.window != nil ? 1 : 0)")
        }
        for event in events {
            scroll.scrollWheel(with: event)
            content.layoutSubtreeIfNeeded()
        }
        lines.append("wheel=\(abs(clip.bounds.origin.y - before) > 0.5 ? 1 : 0)")
        // Then to the end of the tab, which is where the last row must show.
        let end = document.isFlipped ? max(document.frame.height - clip.bounds.height, 0) : 0
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: end))
        scroll.reflectScrolledClipView(clip)
        content.layoutSubtreeIfNeeded()
        let atEnd = document.isFlipped ? clip.bounds.origin.y >= end - 0.5 : clip.bounds.origin.y <= 0.5
        lines.append("at_end=\(atEnd ? 1 : 0)")
        if let row = row(labelled: label, in: content) {
            let inWindow = window.convertFromScreen(row.frame)
            let inClip = clip.convert(clip.bounds, to: nil)
            let visible = NSRect(origin: .zero, size: frame.size).intersects(inWindow)
                && inClip.intersects(inWindow)
            lines.append("last=\(label)")
            lines.append("last_visible=\(visible ? 1 : 0)")
        } else {
            // The row's own AX element may be hidden from the window (SwiftUI
            // keeps the tree in one hosting view): fall back to the end of the
            // document, which is the last row's bottom edge.
            let bottom = document.isFlipped
                ? NSPoint(x: document.bounds.midX, y: document.bounds.maxY)
                : NSPoint(x: document.bounds.midX, y: document.bounds.minY)
            let inWindow = document.convert(bottom, to: nil)
            let inClip = clip.convert(clip.bounds, to: nil)
            let visible = NSRect(origin: .zero, size: frame.size).contains(inWindow)
                && inClip.contains(inWindow)
            lines.append("last=document-end")
            lines.append("last_visible=\(visible ? 1 : 0)")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// The Settings window, if it is open (SettingsView tags it: macOS titles
    /// it after the open tab, and the stream window that shows the phone's
    /// Settings app is titled after that app).
    @MainActor
    static func settingsWindow() -> NSWindow? {
        NSApp.windows.first {
            $0.isVisible && ($0.identifier?.rawValue == "settings"
                || $0.identifier?.rawValue == "com_apple_SwiftUI_Settings_window")
        }
    }

    /// For a failed lookup: what windows the app has.
    @MainActor
    static func windowList() -> String {
        NSApp.windows.filter(\.isVisible)
            .map { "\(type(of: $0)) title=\($0.title) id=\($0.identifier?.rawValue ?? "-")" }
            .joined(separator: "; ")
    }

    /// An accessibility element with that label, anywhere in the window.
    private static func row(labelled label: String, in content: NSView) -> (frame: NSRect, element: Any)? {
        guard let found = accessibilityElement(labelled: label, in: content, depth: 0) else { return nil }
        let frame: NSRect
        if let element = found as? NSAccessibilityElement {
            frame = element.accessibilityFrame()
        } else if let view = found as? NSView {
            frame = view.accessibilityFrame()
        } else {
            return nil
        }
        return (frame, found)
    }

    private static func accessibilityElement(labelled label: String, in element: Any, depth: Int) -> Any? {
        guard depth < 40 else { return nil }
        let own: String?
        let children: [Any]
        if let view = element as? NSView {
            own = view.accessibilityLabel() ?? view.accessibilityTitle()
            children = view.accessibilityChildren() ?? []
        } else if let ax = element as? NSAccessibilityElement {
            own = ax.accessibilityLabel() ?? ax.accessibilityTitle()
            children = ax.accessibilityChildren() ?? []
        } else {
            own = nil
            children = []
        }
        if own == label { return element }
        for child in children {
            if let found = accessibilityElement(labelled: label, in: child, depth: depth + 1) { return found }
        }
        return nil
    }

    private static func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    /// A continuous trackpad scroll as the window server sends one: began,
    /// changed, ended (phases 1, 2, 4), at a window point.
    private static func wheelEvents(dy: Int32, at point: NSPoint) -> [NSEvent] {
        var events: [NSEvent] = []
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        for phase in [1, 2, 4] {
            guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                                   wheel1: dy, wheel2: 0, wheel3: 0) else { continue }
            cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
            cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase))
            cg.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: Double(dy))
            cg.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: Double(dy))
            cg.location = CGPoint(x: point.x, y: primaryHeight - point.y)
            if let event = NSEvent(cgEvent: cg) { events.append(event) }
        }
        return events
    }
}
