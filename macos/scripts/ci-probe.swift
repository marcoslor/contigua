// ci-probe.swift — the window-server capabilities an e2e runner has (#227).
// ci-probe.sh builds and runs it. It opens one small green window of its own,
// then prints one line per capability, `CAP_<NAME>=yes|no <detail>`:
//   CAP_SCREENSHOT  `screencapture -l` of that window comes back green
//   CAP_INPUT       a posted CGEvent click lands in that window
//   CAP_TALL_SCREEN the main screen's visible height fits C6's tall window
// and the facts behind them (`INFO …`). It touches nothing but its own window
// and a temp file, and exits within a few seconds whatever happens.
import AppKit

let tallNeed: CGFloat = 952  // C6: 900 pt of stream plus the 52 pt header band

final class ClickView: NSView {
    var clicks = 0
    override func draw(_ dirtyRect: NSRect) {
        NSColor(srgbRed: 0, green: 1, blue: 0, alpha: 1).setFill()
        bounds.fill()
    }
    override func mouseDown(with event: NSEvent) { clicks += 1 }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

func line(_ name: String, _ yes: Bool, _ detail: String) {
    print("CAP_\(name)=\(yes ? "yes" : "no") \(detail)")
    fflush(stdout)
}

func run(_ path: String, _ args: [String]) -> Int32 {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return -1 }
    let deadline = Date().addingTimeInterval(10)
    while p.isRunning && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
    if p.isRunning { p.terminate(); return -2 }
    return p.terminationStatus
}

func pump(_ seconds: TimeInterval) {
    RunLoop.current.run(until: Date().addingTimeInterval(seconds))
}

/// Fraction of sampled pixels that are green in the PNG at `path`.
func greenFraction(_ path: String) -> Double? {
    guard let data = FileManager.default.contents(atPath: path),
          let rep = NSBitmapImageRep(data: data), rep.pixelsWide > 0 else { return nil }
    var green = 0, total = 0
    let step = max(1, rep.pixelsWide / 20)
    for y in stride(from: 0, to: rep.pixelsHigh, by: step) {
        for x in stride(from: 0, to: rep.pixelsWide, by: step) {
            guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
            total += 1
            if c.greenComponent > 0.6 && c.redComponent < 0.4 && c.blueComponent < 0.4 { green += 1 }
        }
    }
    return total == 0 ? nil : Double(green) / Double(total)
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)

guard let screen = NSScreen.main else {
    print("INFO no main screen")
    line("SCREENSHOT", false, "no screen")
    line("INPUT", false, "no screen")
    line("TALL_SCREEN", false, "no screen")
    exit(0)
}
let vf = screen.visibleFrame
print("INFO screens=\(NSScreen.screens.count) main=\(Int(screen.frame.width))x\(Int(screen.frame.height)) visible_height=\(Int(vf.height)) scale=\(screen.backingScaleFactor)")
print("INFO preflight_screen_capture=\(CGPreflightScreenCaptureAccess()) ax_trusted=\(AXIsProcessTrusted())")

let view = ClickView(frame: NSRect(x: 0, y: 0, width: 240, height: 240))
let window = NSWindow(contentRect: NSRect(x: vf.midX - 120, y: vf.midY - 120, width: 240, height: 240),
                      styleMask: [.titled], backing: .buffered, defer: false)
window.contentView = view
window.level = .floating
window.makeKeyAndOrderFront(nil)
app.activate(ignoringOtherApps: true)
pump(1.5)

// Screenshot: the window server's picture of our window, as the checks take it.
let shot = NSTemporaryDirectory() + "ci-probe-\(getpid()).png"
let code = run("/usr/sbin/screencapture", ["-x", "-o", "-l", "\(window.windowNumber)", shot])
let frac = greenFraction(shot)
try? FileManager.default.removeItem(atPath: shot)
line("SCREENSHOT", code == 0 && (frac ?? 0) > 0.8,
     "exit=\(code) green=\(frac.map { String(format: "%.2f", $0) } ?? "none")")

// Input: a real click at the window's centre, through the window server.
let mainHeight = NSScreen.screens.first?.frame.height ?? screen.frame.height
let centre = CGPoint(x: window.frame.midX, y: mainHeight - window.frame.midY)  // CG is top-left
let src = CGEventSource(stateID: .hidSystemState)
for type in [CGEventType.leftMouseDown, .leftMouseUp] {
    CGEvent(mouseEventSource: src, mouseType: type, mouseCursorPosition: centre, mouseButton: .left)?
        .post(tap: .cghidEventTap)
    pump(0.1)
}
pump(1.0)
line("INPUT", view.clicks > 0, "clicks=\(view.clicks)")

line("TALL_SCREEN", vf.height >= tallNeed, "visible_height=\(Int(vf.height)) need=\(Int(tallNeed))")
exit(0)
