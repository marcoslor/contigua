// pd-screens — the e2e VM's screen: report it, or make it tall enough for C6.
//
// The VM boots headless (`tart run --no-graphics`), so the guest keeps the
// resolution it had: tart's `--display` hint sizes the host window, which a
// headless run never opens. C6 resizes a stream to 600x900 pt, and AppKit
// clamps a window to its screen's visible frame, so a 1280x720 guest screen
// turned the tall config into 1200x1296 px. vm-e2e.sh runs this helper in the
// guest's console session before the checks to pick a mode tall enough for it.
//
//   pd-screens                              print the screens (frame, visible, scale)
//   pd-screens --list-modes                 print the main display's modes
//   pd-screens --min-visible-height 960 [--scale 2]
//                                           set the smallest mode whose visible
//                                           frame is at least that tall and
//                                           whose backing scale is 2 (the scale
//                                           the visible checks are written
//                                           against), print what it did;
//                                           restores the old mode and exits 1
//                                           when none qualifies
//
// Only the e2e VM calls the setter; on the host it would resize the person's
// own screen, which is why nothing in the suite calls it.

import AppKit
import CoreGraphics
import Foundation

let arguments = CommandLine.arguments

func argument(_ name: String) -> String? {
    arguments.indices.first { arguments[$0] == name && $0 + 1 < arguments.count }.map { arguments[$0 + 1] }
}

func describe(_ screen: NSScreen) -> String {
    let f = screen.frame, v = screen.visibleFrame
    return String(format: "screen frame=%.0fx%.0f visible=%.0fx%.0f scale=%.0f",
                  f.width, f.height, v.width, v.height, screen.backingScaleFactor)
}

func report() {
    for screen in NSScreen.screens { print(describe(screen)) }
}

func modes(_ display: CGDirectDisplayID) -> [CGDisplayMode] {
    (CGDisplayCopyAllDisplayModes(display, nil) as? [CGDisplayMode]) ?? []
}

if arguments.contains("--list-modes") {
    let display = CGMainDisplayID()
    let current = CGDisplayCopyDisplayMode(display)
    // Points first, pixels in brackets: a HiDPI mode's width/height are its
    // points, its pixelWidth/Height the backing store behind them.
    for mode in modes(display).sorted(by: { $0.pixelWidth * $0.pixelHeight < $1.pixelWidth * $1.pixelHeight }) {
        let mark = mode.ioDisplayModeID == current?.ioDisplayModeID ? " *" : ""
        print("mode \(mode.width)x\(mode.height) pt (\(mode.pixelWidth)x\(mode.pixelHeight) px)\(mark)")
    }
    exit(0)
}

guard let wanted = argument("--min-visible-height").flatMap(Double.init) else {
    report()
    exit(0)
}

let display = CGMainDisplayID()
let original = CGDisplayCopyDisplayMode(display)
// The visible checks are written against a 2x screen (check-e2e.sh's
// RUN_SCALE): a 1x mode would halve every video config they expect.
let wantedScale = Int(argument("--scale") ?? "2") ?? 2
func scale(of mode: CGDisplayMode) -> Int {
    Int((Double(mode.pixelWidth) / Double(max(1, mode.width))).rounded())
}
// Smallest first: the least pixels the window server has to composite. The
// extra 80 pt leaves room for the menu bar and Dock, which the visible frame
// has already taken off.
let all = modes(display).filter { scale(of: $0) == wantedScale }
for mode in all {
    print("pd-screens: \(wantedScale)x mode \(mode.width)x\(mode.height) pt (\(mode.pixelWidth)x\(mode.pixelHeight) px)")
}
let candidates = all
    .filter { $0.width >= 1200 && Double($0.height) >= wanted + 80 }
    .sorted { $0.pixelWidth * $0.pixelHeight < $1.pixelWidth * $1.pixelHeight }

for mode in candidates {
    guard CGDisplaySetDisplayMode(display, mode, nil) == .success else { continue }
    // The window server needs a moment to re-lay out the menu bar and Dock.
    usleep(400_000)
    report()
    let screen = NSScreen.main
    if let visible = screen?.visibleFrame.height, visible >= wanted,
       Int((screen?.backingScaleFactor ?? 0).rounded()) == wantedScale {
        print("pd-screens: set \(mode.width)x\(mode.height) pt (\(mode.pixelWidth)x\(mode.pixelHeight) px); visible height \(Int(visible)) pt")
        exit(0)
    }
}

// No mode is tall enough (a small VM display): leave the tallest one on, so a
// run is as close as the machine gets, and say so.
if let tallest = all.max(by: { $0.height < $1.height }) {
    _ = CGDisplaySetDisplayMode(display, tallest, nil)
    usleep(400_000)
    report()
    print("pd-screens: no \(wantedScale)x mode gives \(Int(wanted)) pt of visible height; left the tallest (\(tallest.width)x\(tallest.height) pt)")
} else if let original {
    _ = CGDisplaySetDisplayMode(display, original, nil)
    print("pd-screens: no \(wantedScale)x mode at all")
}
exit(1)
