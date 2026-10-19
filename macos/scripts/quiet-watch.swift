// Proves an e2e run left the person's Mac alone. check-e2e.sh starts it for the
// whole run and stops it at the end; every 0.25 s it samples:
//   - the frontmost app: a change *to* a process of this run (the e2e app, a
//     Dock shim, a helper tool) is a focus change;
//   - the pointer: a move is counted when it lands on the run's virtual display
//     or on a window of this run, or while check-e2e.sh marks a real-input step
//     (the `--input-marker` file exists). The person's own moves elsewhere are
//     not the run's and are not counted;
//   - the windows of this run's processes that are on a real display (any
//     display but the e2e virtual one), below the menu-bar level; a window that
//     only shares ≤ 2 pt of an edge with one is not on it;
//   - this run's processes that have a Dock icon (regular activation policy).
// `--summary FILE` is rewritten after every sample with
// `focus_changes=N pointer_moves=N visible_windows=N dock_icons=N`;
// `--details FILE` gets one line per counted event.
//
//   quiet-watch --summary F --details F [--input-marker F] --prefix PATH [--prefix PATH ...]

import AppKit
import CoreGraphics
import Darwin

let arguments = CommandLine.arguments
func values(_ name: String) -> [String] {
    arguments.indices.filter { arguments[$0] == name && $0 + 1 < arguments.count }.map { arguments[$0 + 1] }
}
guard let summaryPath = values("--summary").first, let detailsPath = values("--details").first else {
    FileHandle.standardError.write(Data("usage: quiet-watch --summary F --details F [--input-marker F] --prefix PATH...\n".utf8))
    exit(2)
}
let prefixes = values("--prefix")
let inputMarker = values("--input-marker").first

/// The PocketDeck e2e virtual display's ids (VirtualDisplay.swift).
let virtualVendor: UInt32 = 0x5044
let virtualModel: UInt32 = 0xE2E0

/// A real overlap, not an edge touch: display arrangements round to whole
/// points, so a run display placed next to a person's screen can share a point
/// or two of an edge with it. A window there is not on the person's screen.
func overlaps(_ a: CGRect, _ b: CGRect) -> Bool {
    let shared = a.intersection(b)
    return !shared.isNull && shared.width > 2 && shared.height > 2
}

var pathCache: [pid_t: String] = [:]
func path(of pid: pid_t) -> String {
    if let cached = pathCache[pid] { return cached }
    var buffer = [CChar](repeating: 0, count: 4096)
    let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
    let path = length > 0 ? String(cString: buffer) : ""
    pathCache[pid] = path
    return path
}
func isRun(_ pid: pid_t) -> Bool {
    let path = path(of: pid)
    return !path.isEmpty && prefixes.contains { path.hasPrefix($0) }
}

func displays() -> (real: [CGRect], virtual: [CGRect]) {
    var count: UInt32 = 0
    CGGetActiveDisplayList(0, nil, &count)
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    CGGetActiveDisplayList(count, &ids, &count)
    var real: [CGRect] = [], virtual: [CGRect] = []
    for id in ids.prefix(Int(count)) {
        if CGDisplayVendorNumber(id) == virtualVendor && CGDisplayModelNumber(id) == virtualModel {
            virtual.append(CGDisplayBounds(id))
        } else {
            real.append(CGDisplayBounds(id))
        }
    }
    return (real, virtual)
}

var focusChanges = 0, pointerMoves = 0
var visibleWindows = Set<Int>(), dockIcons = Set<pid_t>()
/// The previous sample's frame per window. macOS's minimize/deminimize genie
/// animates the window's own frame across the person's screen for a few frames;
/// a window that has been on the run's virtual display counts only once its
/// frame is the same in two samples. Any other window counts at once.
var lastBounds: [Int: CGRect] = [:]
/// Windows seen on the run's virtual display: only these can be mid-genie.
var seenOnVirtual = Set<Int>()
var lastFrontmost: pid_t = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
var lastPointer = CGEvent(source: nil)?.location ?? .zero

func note(_ line: String) {
    let stamp = String(format: "%.2f", Date().timeIntervalSince1970)
    guard let data = "\(stamp) \(line)\n".data(using: .utf8) else { return }
    if let handle = FileHandle(forWritingAtPath: detailsPath) {
        handle.seekToEndOfFile(); handle.write(data); handle.closeFile()
    } else {
        FileManager.default.createFile(atPath: detailsPath, contents: data)
    }
}

func sample() {
    let (real, virtual) = displays()
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
        as? [[String: Any]] ?? []
    var runWindows: [CGRect] = []
    for entry in list {
        guard let pid = entry[kCGWindowOwnerPID as String] as? pid_t, isRun(pid),
              let boundsDict = entry[kCGWindowBounds as String] as? [String: Any],
              let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary) else { continue }
        runWindows.append(bounds)
        // The menu-bar item and menus (layer >= 25) live in the menu bar by design.
        let layer = entry[kCGWindowLayer as String] as? Int ?? 0
        let alpha = entry[kCGWindowAlpha as String] as? Double ?? 1
        let number = entry[kCGWindowNumber as String] as? Int ?? 0
        let settled = lastBounds[number] == bounds
        lastBounds[number] = bounds
        if virtual.contains(where: { overlaps($0, bounds) }) { seenOnVirtual.insert(number) }
        guard layer < 25, alpha > 0, bounds.width > 1, bounds.height > 1,
              real.contains(where: { overlaps($0, bounds) }), !visibleWindows.contains(number) else { continue }
        // A run window leaving or returning to the virtual display through the
        // Dock (the minimize animation) is not sitting on the person's screen;
        // count it once it settles. A window that shows up on a real display
        // without having been on the virtual one counts at once.
        guard settled || !seenOnVirtual.contains(number) else { continue }
        visibleWindows.insert(number)
        note("window \(number) of pid \(pid) \(path(of: pid)) at \(bounds) on a real display")
    }

    if let front = NSWorkspace.shared.frontmostApplication?.processIdentifier, front != lastFrontmost {
        lastFrontmost = front
        if isRun(front) {
            focusChanges += 1
            note("frontmost -> pid \(front) \(path(of: front))")
        }
    }

    let pointer = CGEvent(source: nil)?.location ?? lastPointer
    if pointer != lastPointer {
        lastPointer = pointer
        let marked = inputMarker.map { FileManager.default.fileExists(atPath: $0) } ?? false
        if marked || virtual.contains(where: { $0.contains(pointer) }) || runWindows.contains(where: { $0.contains(pointer) }) {
            pointerMoves += 1
            note("pointer -> \(pointer)\(marked ? " during a real-input step" : "")")
        }
    }

    for app in NSWorkspace.shared.runningApplications {
        let pid = app.processIdentifier
        // A fresh instance: a kept one may still report the policy it launched with.
        guard isRun(pid), !dockIcons.contains(pid),
              NSRunningApplication(processIdentifier: pid)?.activationPolicy == .regular else { continue }
        dockIcons.insert(pid)
        note("dock icon: \(path(of: pid))")
    }

    let summary = "focus_changes=\(focusChanges) pointer_moves=\(pointerMoves) visible_windows=\(visibleWindows.count) dock_icons=\(dockIcons.count)\n"
    try? summary.write(toFile: summaryPath, atomically: true, encoding: .utf8)
}

signal(SIGTERM) { _ in exit(0) }
sample()
// NSWorkspace's frontmost app and running-app list are updated on the main run loop.
Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in sample() }
RunLoop.main.run()
