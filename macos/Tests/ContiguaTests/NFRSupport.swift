// Shared tools for the non-functional checks (docs/NFR.md): one off-screen
// renderer, WCAG contrast maths and a walk that says whether every control can
// be reached on the smallest supported screen. The 10-20 checks and the layout
// checks use these instead of carrying their own copies of the same code.

import AppKit
import XCTest

// MARK: - Off-screen render

@MainActor
enum NFROffscreen {
    /// A view laid out at `size` and drawn into a bitmap without a window, in
    /// the given appearance. The caller owns the view; nothing is added to the
    /// screen, so a quiet run (and a headless test) can render the real views.
    static func render(_ view: NSView, size: CGSize,
                       appearance: NSAppearance.Name = .aqua) -> NSBitmapImageRep {
        view.frame = NSRect(origin: .zero, size: size)
        view.appearance = NSAppearance(named: appearance)
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            preconditionFailure("NFR render: no bitmap for \(type(of: view))")
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }

    /// The SwiftUI view at its fitting width and the given height, rendered the
    /// same way. `height` is normally the smallest screen's content height.
    static func render(hosting view: NSView, width: CGFloat, height: CGFloat,
                       appearance: NSAppearance.Name = .aqua) -> NSBitmapImageRep {
        render(view, size: CGSize(width: width, height: height), appearance: appearance)
    }
}

// MARK: - On-screen capture

/// The window server's own picture of a view: what a person sees, glass and
/// Reduce Transparency included, which `cacheDisplay` cannot draw (on macOS 26
/// it leaves the glass out). The view goes into a borderless, click-through
/// window at the main screen's bottom-left for under a second, in the given
/// appearance, and `screencapture -l` takes that window alone. Where capture
/// is unavailable (no window server, no screen-recording permission) the
/// result says why, so the caller can fall back and report it.
@MainActor
enum NFROnScreen {
    enum Capture {
        case picture(NSBitmapImageRep)
        case unavailable(String)
    }

    static func capture(_ view: NSView, size: CGSize, appearance: NSAppearance.Name) -> Capture {
        guard let screen = NSScreen.main else { return .unavailable("no screen") }
        view.frame = NSRect(origin: .zero, size: size)
        let origin = NSPoint(x: screen.visibleFrame.minX + 40, y: screen.visibleFrame.minY + 40)
        let window = NSWindow(contentRect: NSRect(origin: origin, size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isOpaque = true
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = .floating
        window.appearance = NSAppearance(named: appearance)
        window.contentView = view
        window.orderFrontRegardless()
        defer {
            window.orderOut(nil)
            window.contentView = nil
            window.close()
        }
        view.layoutSubtreeIfNeeded()
        window.display()
        // Bounded: the window server composites the window and the glass
        // settles.
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        CATransaction.flush()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))

        let path = NSTemporaryDirectory()
            + "nfr-onscreen-\(ProcessInfo.processInfo.processIdentifier)-\(window.windowNumber).png"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-o", "-l", "\(window.windowNumber)", path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return .unavailable("screencapture did not start") }
        let deadline = Date().addingTimeInterval(15)
        while process.isRunning && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        if process.isRunning {
            process.terminate()
            return .unavailable("screencapture timed out")
        }
        guard process.terminationStatus == 0 else {
            return .unavailable("screencapture exited \(process.terminationStatus)")
        }
        guard let data = FileManager.default.contents(atPath: path),
              let rep = NSBitmapImageRep(data: data) else {
            return .unavailable("screencapture wrote no picture")
        }
        // A capture without screen-recording permission is the desktop
        // without the window, or a blank: it must at least be the window's
        // shape.
        let scale = screen.backingScaleFactor
        guard abs(CGFloat(rep.pixelsWide) - size.width * scale) <= 2,
              abs(CGFloat(rep.pixelsHigh) - size.height * scale) <= 2 else {
            return .unavailable("capture is \(rep.pixelsWide)x\(rep.pixelsHigh), not the window")
        }
        return .picture(rep)
    }
}

/// The frames text and controls must stay readable over: white, black and the
/// saturated, busy picture that made bare symbols disappear.
final class NFRBackdropView: NSView {
    enum Kind { case white, black, busy }
    let kind: Kind

    init(kind: Kind, frame: NSRect) {
        self.kind = kind
        super.init(frame: frame)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        switch kind {
        case .white:
            NSColor.white.setFill()
            bounds.fill()
        case .black:
            NSColor.black.setFill()
            bounds.fill()
        case .busy:
            let colors: [NSColor] = [.white, .black, .systemRed, .systemCyan, .systemYellow, .systemBlue]
            let w = bounds.width / CGFloat(colors.count)
            for (index, color) in colors.enumerated() {
                color.setFill()
                NSRect(x: CGFloat(index) * w, y: 0, width: w, height: bounds.height).fill()
            }
            NSColor.white.setFill()
            for x in stride(from: 0, to: bounds.width, by: 12) {
                NSRect(x: x, y: 0, width: 3, height: bounds.height).fill()
            }
        }
    }
}

// MARK: - Contrast (WCAG 2.x relative luminance)

enum NFRContrast {
    /// WCAG relative luminance of an sRGB colour, 0…1.
    static func relativeLuminance(_ color: NSColor) -> Double {
        guard let srgb = color.usingColorSpace(.sRGB) ?? color.usingColorSpace(.deviceRGB) else { return 0 }
        func channel(_ value: CGFloat) -> Double {
            let v = Double(value)
            return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(srgb.redComponent)
            + 0.7152 * channel(srgb.greenComponent)
            + 0.0722 * channel(srgb.blueComponent)
    }

    /// The WCAG contrast ratio between two luminances, 1…21.
    static func ratio(_ a: Double, _ b: Double) -> Double {
        let high = max(a, b), low = min(a, b)
        return (high + 0.05) / (low + 0.05)
    }

    /// The contrast between two colours (`fg` over `bg`).
    static func contrast(fg: NSColor, bg: NSColor) -> Double {
        ratio(relativeLuminance(fg), relativeLuminance(bg))
    }

    /// `contrast(fg:bg:)` for two 8-bit sRGB triples, the form a reference
    /// image comparison has.
    static func contrast(fg: (r: Int, g: Int, b: Int), bg: (r: Int, g: Int, b: Int)) -> Double {
        func colour(_ c: (r: Int, g: Int, b: Int)) -> NSColor {
            NSColor(srgbRed: CGFloat(c.r) / 255, green: CGFloat(c.g) / 255,
                    blue: CGFloat(c.b) / 255, alpha: 1)
        }
        return contrast(fg: colour(fg), bg: colour(bg))
    }
}

// MARK: - Reachability

/// A control the person is supposed to be able to reach: a button, a text
/// field, a toggle, a pop-up, a slider, or anything that answers a press.
@MainActor
enum NFRReachability {
    static func isControl(_ view: NSView) -> Bool {
        if view is NSControl { return true }
        if view is NSTableView || view is NSOutlineView { return true }
        if let cell = view as? NSCollectionView { return !cell.isHidden }
        return view.accessibilityRole() == .button
    }

    /// Every control that is neither inside the root's bounds nor inside a
    /// scroll view (where the person can scroll to it). Hidden views and
    /// zero-sized placeholders are not controls yet.
    static func unreachableControls(in root: NSView) -> [NSView] {
        var unreachable: [NSView] = []
        visit(root, root: root, insideScroll: false, into: &unreachable)
        return unreachable
    }

    private static func visit(_ view: NSView, root: NSView, insideScroll: Bool,
                              into unreachable: inout [NSView]) {
        guard !view.isHidden, view.bounds.width > 0, view.bounds.height > 0 else { return }
        let scroll = insideScroll || view is NSScrollView
        if isControl(view), !scroll {
            let frame = view.convert(view.bounds, to: root)
            if !root.bounds.contains(frame) {
                unreachable.append(view)
            }
        }
        for child in view.subviews {
            visit(child, root: root, insideScroll: scroll, into: &unreachable)
        }
    }

    /// A readable failure list for a check: type, frame and accessibility
    /// label, never a file name.
    static func describe(_ views: [NSView], in root: NSView) -> String {
        views.map { view in
            let frame = view.convert(view.bounds, to: root)
            let label = view.accessibilityLabel() ?? ""
            return "\(type(of: view)) \(Int(frame.minX)),\(Int(frame.minY)) \(Int(frame.width))x\(Int(frame.height)) \(label)"
        }.joined(separator: "; ")
    }
}
