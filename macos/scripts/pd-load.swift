// pd-load — how heavy an e2e run was on the Mac's display plumbing.
//
// Every quiet launch of the app used to create and destroy a virtual display
// (VirtualDisplay.swift): a system-wide display reconfiguration that makes
// WindowServer, colorsync and every running app re-lay out. The e2e checks exist
// to catch that being expensive, so the run itself reports:
//
//   LOAD windowserver_cpu_avg=… colorsync_cpu_avg=… reconfigs=N vdisplay=N adds=N removes=N samples=N
//
// check-e2e.sh starts this sibling of quiet-watch for a run and prints its line
// at the end. Once a second it samples the CPU of WindowServer and of colorsync
// (ps's decaying average, the same reading `top` shows) and reads the list of
// online displays:
//
//   reconfigs — samples in which that list changed: the system reconfigured what
//               it shows, which is what a display appearing or going away is;
//   vdisplay  — those changes that were the run's own virtual display (vendor /
//               product ids) appearing or going away — 2 for a run that held one
//               display from its first launch to its last;
//   adds/removes — displays that appeared / went away.
//
// The list is read rather than taken from CGDisplayRegisterReconfigurationCallback
// (which tells a process about its own display changes): measured on 2026-10-16,
// with the callback registered in this tool across a virtual display's create and
// destroy — and in a second test across three creates and destroys — not one
// event arrived, so a count from it would have read 0 for every run.
//
//   pd-load --summary FILE [--seconds N]

import CoreGraphics
import Foundation

// The counters live in an enum, not in top-level vars: a script's top-level
// vars belong to its implicit main function, which would stop the SIGTERM
// handler below from being a bare C function pointer (it may capture nothing).
enum Load {
    static var summaryPath = ""
    static var seconds: Double?
    static var reconfigs = 0, virtualReconfigs = 0, adds = 0, removes = 0, samples = 0
    static var windowServerTotal = 0.0, colorsyncTotal = 0.0
    static var online: Set<CGDirectDisplayID>?
}

func argumentValues(_ name: String) -> [String] {
    let arguments = CommandLine.arguments
    return arguments.indices.filter { arguments[$0] == name && $0 + 1 < arguments.count }.map { arguments[$0 + 1] }
}

let virtualVendor: UInt32 = 0x5044
let virtualModel: UInt32 = 0xE2E0

func isVirtualDisplay(_ display: CGDirectDisplayID) -> Bool {
    CGDisplayVendorNumber(display) == virtualVendor && CGDisplayModelNumber(display) == virtualModel
}

/// The displays that are online right now.
func onlineDisplays() -> Set<CGDirectDisplayID> {
    var count: UInt32 = 0
    CGGetOnlineDisplayList(0, nil, &count)
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    CGGetOnlineDisplayList(count, &ids, &count)
    return Set(ids.prefix(Int(count)))
}

/// This sample compared with the previous one: a changed display list is a
/// reconfiguration the system went through.
func countDisplays() {
    let now = onlineDisplays()
    defer { Load.online = now }
    guard let before = Load.online, before != now else { return }
    Load.reconfigs += 1
    for added in now.subtracting(before) {
        Load.adds += 1
        if isVirtualDisplay(added) { Load.virtualReconfigs += 1 }
    }
    for removed in before.subtracting(now) {
        Load.removes += 1
        if isVirtualDisplay(removed) { Load.virtualReconfigs += 1 }
    }
}

/// This sample's CPU for every process whose executable is one of `names`.
func cpu(names: Set<String>) -> Double {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/bin/ps")
    task.arguments = ["-axo", "%cpu=,comm="]
    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError = FileHandle.nullDevice
    guard (try? task.run()) != nil else { return 0 }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    task.waitUntilExit()
    var total = 0.0
    for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
        let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard parts.count == 2, let value = Double(parts[0]) else { continue }
        if names.contains((String(parts[1]) as NSString).lastPathComponent) { total += value }
    }
    return total
}

let windowServerNames: Set<String> = ["WindowServer"]
// Both halves of colorsync: the daemon and the helper it spawns for a display.
let colorsyncNames: Set<String> = ["colorsyncd", "colorsync.displayservices"]

func writeSummary() {
    let ws = Load.samples > 0 ? Load.windowServerTotal / Double(Load.samples) : 0
    let cs = Load.samples > 0 ? Load.colorsyncTotal / Double(Load.samples) : 0
    let line = String(format: "LOAD windowserver_cpu_avg=%.1f colorsync_cpu_avg=%.1f reconfigs=%d "
                      + "vdisplay=%d adds=%d removes=%d samples=%d",
                      ws, cs, Load.reconfigs, Load.virtualReconfigs, Load.adds, Load.removes, Load.samples)
    try? (line + "\n").write(toFile: Load.summaryPath, atomically: true, encoding: .utf8)
}

func sample() {
    countDisplays()
    Load.windowServerTotal += cpu(names: windowServerNames)
    Load.colorsyncTotal += cpu(names: colorsyncNames)
    Load.samples += 1
    writeSummary()
}

guard let summaryPath = argumentValues("--summary").first else {
    FileHandle.standardError.write(Data("usage: pd-load --summary FILE [--seconds N]\n".utf8))
    exit(2)
}
Load.summaryPath = summaryPath
Load.seconds = argumentValues("--seconds").first.flatMap(Double.init)

signal(SIGTERM) { _ in writeSummary(); exit(0) }
signal(SIGINT) { _ in writeSummary(); exit(0) }

Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in sample() }
if let seconds = Load.seconds {
    Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { _ in writeSummary(); exit(0) }
}
sample()
RunLoop.main.run()
