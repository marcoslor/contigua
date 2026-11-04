// pd-vdisplay — the e2e run's own virtual display, held for the whole run.
//
// check-e2e.sh starts one of these before a check's first launch (and once for
// `all`) and kills it in its exit trap. The app running with --background
// (VirtualDisplay.swift) finds an existing display with these ids and puts its
// windows there instead of creating and destroying a display on every launch:
// each create/destroy is a system-wide display reconfiguration — WindowServer,
// colorsync and every running app re-lay out — and a check launches the app
// several times, `all` about 45.
//
// The display is the same identity the app itself used (vendor/product ids,
// serial = the fixed test identity's hash: "e2e", whatever the profile), so
// macOS sees no new display: no extra ColourSync profile, no new arrangement
// entry. It is placed past the right edge of every one of the person's screens
// (a corner can land inside a second display); the 16 pt gap it asks for is
// snapped away by WindowServer, so quiet-watch ignores shared edges of ≤ 2 pt.
//
//   pd-vdisplay --profile NAME
//
// `--profile` names the run; it is not part of the identity. Every test run
// draws on the one identity (VirtualDisplay.testIdentityProfile in the app), so
// a worker profile cannot add a display of its own (ISS-28).
//
// Prints one line once the display is configured —
//   id=123 w=1280 h=800 scale=1
// — and then holds the display until SIGTERM/SIGINT (the display goes away with
// this process). check-e2e reads that line; the app is told nothing and finds
// the display by its ids.
//
// A display it cannot create, or one of the same identity left online by a run
// that did not end cleanly, is a `FAIL vdisplay: …` line and a non-zero exit:
// the checks are written against this display, so check-e2e stops the run at
// once rather than let a quiet run fall back to a display per app launch.
// (Sleeping mid-run is how such a leftover happened once; check-e2e holds a
// caffeinate for the whole run.)

import CoreGraphics
import Foundation

let arguments = CommandLine.arguments
func argument(_ name: String) -> String? {
    arguments.indices.first { arguments[$0] == name && $0 + 1 < arguments.count }.map { arguments[$0 + 1] }
}

guard argument("--profile") != nil else {
    FileHandle.standardError.write(Data("usage: pd-vdisplay --profile NAME [--size WxH] [--scale 1|2]\n".utf8))
    exit(2)
}

// VirtualDisplay.swift's ids: quiet-watch, the backdrop tool and the app all
// look for them.
let vendorID: UInt32 = 0x5044
let productID: UInt32 = 0xE2E0

/// The run's screen, 1280x800 at 1x by default. Small on purpose — the display's
/// pixels are what WindowServer composites and what colorsync re-profiles every
/// time a display appears or goes away, and the phone's video is scaled into the
/// window anyway. `--size WxH` gives the one check whose window is bigger than
/// the default screen (the Deck's 1960x1100; DECK-4/DECK-24) a display it fits
/// on. 1x because nothing in the app or the checks needs Retina pixels here.
struct Screen {
    var width: UInt = 1280
    var height: UInt = 800
    /// Pixels per point. 1 everywhere except the crispness check, whose windows
    /// must be described in Retina pixels (ISS-39).
    var scale: UInt = 1
}

func screen() -> Screen {
    var screen = Screen()
    if let raw = argument("--size") {
        let parts = raw.split(separator: "x").map(String.init)
        guard parts.count == 2, let width = UInt(parts[0]), let height = UInt(parts[1]),
              width >= 640, height >= 480 else {
            FileHandle.standardError.write(Data("pd-vdisplay: --size needs WxH, at least 640x480\n".utf8))
            exit(2)
        }
        screen.width = width
        screen.height = height
    }
    if let raw = argument("--scale"), let scale = UInt(raw), scale == 1 || scale == 2 {
        screen.scale = scale
    } else if argument("--scale") != nil {
        FileHandle.standardError.write(Data("pd-vdisplay: --scale needs 1 or 2\n".utf8))
        exit(2)
    }
    return screen
}

/// The app's VirtualDisplay.testIdentityProfile: every test run draws on this
/// one identity, whatever `--profile` / PD_E2E_PROFILE says (ISS-28).
let testIdentityProfile = "e2e"

/// FNV-1a of the profile name, the app's function (VirtualDisplaySerialTests).
/// The e2e helper always hashes `testIdentityProfile`, the app's
/// VirtualDisplay.testIdentityProfile, so a run's display has one identity.
func serialNumber(profile: String) -> UInt32 {
    var hash: UInt32 = 0x811C_9DC5
    for byte in profile.utf8 {
        hash ^= UInt32(byte)
        hash = hash &* 0x0100_0193
    }
    return hash == 0 ? 1 : hash
}

// MARK: The private CGVirtualDisplay classes, through the Objective-C runtime

typealias AllocFn = @convention(c) (AnyClass, Selector) -> Unmanaged<AnyObject>
typealias InitObjectFn = @convention(c) (AnyObject, Selector, AnyObject) -> Unmanaged<AnyObject>?
typealias InitModeFn = @convention(c) (AnyObject, Selector, UInt, UInt, Double) -> Unmanaged<AnyObject>?
typealias ApplyFn = @convention(c) (AnyObject, Selector, AnyObject) -> Bool

func make(_ name: String) -> NSObject? {
    (NSClassFromString(name) as? NSObject.Type)?.init()
}

func allocated(_ cls: AnyClass) -> AnyObject {
    let selector = NSSelectorFromString("alloc")
    let alloc = unsafeBitCast(class_getMethodImplementation(object_getClass(cls), selector), to: AllocFn.self)
    return alloc(cls, selector).takeUnretainedValue()
}

func modeClass(width: UInt, height: UInt, refreshRate: Double = 60) -> NSObject? {
    let name = "CGVirtualDisplayMode"
    let selector = NSSelectorFromString("initWithWidth:height:refreshRate:")
    guard let cls = NSClassFromString(name), class_respondsToSelector(cls, selector) else { return nil }
    let initFn = unsafeBitCast(class_getMethodImplementation(cls, selector), to: InitModeFn.self)
    return initFn(allocated(cls), selector, width, height, refreshRate)?.takeRetainedValue() as? NSObject
}

func displayMaker() -> ((NSObject) -> NSObject?)? {
    let selector = NSSelectorFromString("initWithDescriptor:")
    guard let cls = NSClassFromString("CGVirtualDisplay"), class_respondsToSelector(cls, selector) else { return nil }
    let initFn = unsafeBitCast(class_getMethodImplementation(cls, selector), to: InitObjectFn.self)
    return { descriptor in initFn(allocated(cls), selector, descriptor)?.takeRetainedValue() as? NSObject }
}

func apply(_ settings: NSObject, to display: NSObject) -> Bool {
    let selector = NSSelectorFromString("applySettings:")
    guard display.responds(to: selector) else { return false }
    let applyFn = unsafeBitCast(class_getMethodImplementation(type(of: display), selector), to: ApplyFn.self)
    return applyFn(display, selector, settings)
}

// MARK: The display's own geometry, as the checks read it

/// A display of this identity that is already online. A run that ends cleanly
/// never leaves one: the display goes away with the helper process that holds
/// it. One online before this helper makes its own means the run would be
/// drawing on a screen this process does not hold, and a second create of the
/// same identity fails on top of that — the run is stopped instead (see below).
/// A Mac that sleeps mid-run is how such a leftover happens; check-e2e.sh keeps
/// it awake with caffeinate.
func existingDisplay() -> CGDirectDisplayID? {
    var count: UInt32 = 0
    CGGetOnlineDisplayList(0, nil, &count)
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    CGGetOnlineDisplayList(count, &ids, &count)
    return ids.prefix(Int(count)).first {
        CGDisplayVendorNumber($0) == vendorID && CGDisplayModelNumber($0) == productID
    }
}

/// The one line check-e2e reads: the display's id, its point size and its scale
/// (its pixels per point). Read from the display, not from the constants the
/// create used: the checks then assert against the display the run really has.
func describe(_ id: CGDirectDisplayID) -> String {
    let bounds = CGDisplayBounds(id)
    // CGDisplayPixelsWide is in points on a Retina display; the mode carries
    // the backing pixels the window server really composites.
    let pixels = CGDisplayCopyDisplayMode(id)?.pixelWidth ?? Int(CGDisplayPixelsWide(id))
    let scale = bounds.width > 0 ? (Double(pixels) / Double(bounds.width)).rounded() : 1
    return "id=\(id) w=\(Int(bounds.width)) h=\(Int(bounds.height)) scale=\(Int(max(scale, 1)))"
}

// MARK: The display

/// Stop the run, with the one line check-e2e shows: every check in it is
/// written against the display this helper holds, so a run that cannot have one
/// must not go on (a quiet run would otherwise fall back to a display per app
/// launch, many reconfigurations — the thing this whole path exists to avoid).
func fail(_ reason: String) -> Never {
    print("FAIL vdisplay: \(reason)")
    fflush(stdout)
    exit(1)
}

func hold(_ id: CGDirectDisplayID) -> Never {
    print(describe(id))
    fflush(stdout)
    signal(SIGTERM) { _ in exit(0) }
    signal(SIGINT) { _ in exit(0) }
    // The descriptor's queue is the main queue, and the display lives as long as
    // this process: hold it here.
    RunLoop.main.run()
    exit(0)
}

// A leftover display of this identity is not adopted: it is not this process's
// to hold, and it is a run that did not end cleanly. One whose helper exited a
// moment ago can still be online while WindowServer lets go of it (the check
// swaps the run's display for the deck check's wide one), so this waits a few
// seconds before calling it a leftover.
var leftoverWait = 0
while let leftover = existingDisplay() {
    if leftoverWait >= 20 { fail("a display of this identity (id=\(leftover)) is already online") }
    Thread.sleep(forTimeInterval: 0.25)
    leftoverWait += 1
}

let wanted = screen()
let size = (width: wanted.width, height: wanted.height)
let scale = wanted.scale
// A 2x display: the first mode is the physical (backing) resolution, which is
// what makes macOS treat it as Retina; the logical mode follows. One mode
// alone is appended raw at 1x.
let modes: [NSObject]
if scale == 2 {
    guard let anchor = modeClass(width: size.width * 2, height: size.height * 2),
          let logical = modeClass(width: size.width, height: size.height) else {
        fail("no CGVirtualDisplayMode on this macOS")
    }
    modes = [anchor, logical]
} else {
    guard let logical = modeClass(width: size.width, height: size.height) else {
        fail("no CGVirtualDisplayMode on this macOS")
    }
    modes = [logical]
}
guard let descriptor = make("CGVirtualDisplayDescriptor"),
      let settings = make("CGVirtualDisplaySettings"),
      let makeDisplay = displayMaker() else {
    fail("no CGVirtualDisplay on this macOS")
}
descriptor.setValue("PocketDeck e2e", forKey: "name")
descriptor.setValue(size.width * scale, forKey: "maxPixelsWide")
descriptor.setValue(size.height * scale, forKey: "maxPixelsHigh")
// HiDPI is only recognised at 200 PPI or more, so the physical size shrinks
// with the backing pixels (220 PPI keeps it safely above the threshold).
let millimetres = scale == 2
    ? NSSize(width: Double(size.width * 2) * 25.4 / 220.0,
             height: Double(size.height * 2) * 25.4 / 220.0)
    : NSSize(width: 340, height: 212)
descriptor.setValue(NSValue(size: millimetres), forKey: "sizeInMillimeters")
descriptor.setValue(vendorID, forKey: "vendorID")
descriptor.setValue(productID, forKey: "productID")
descriptor.setValue(serialNumber(profile: testIdentityProfile), forKey: "serialNum")
// The display is created after the descriptor is filled in: init reads it.
guard let handle = makeDisplay(descriptor) else {
    fail("CGVirtualDisplay init failed")
}
settings.setValue(modes, forKey: "modes")
settings.setValue(scale == 2 ? 1 : 0, forKey: "hiDPI")
guard apply(settings, to: handle),
      let id = (handle.value(forKey: "displayID") as? NSNumber)?.uint32Value, id != 0 else {
    fail("the virtual display refused its settings")
}

// The mode and the origin, for this process's lifetime only (.forAppOnly): the
// person's arrangement is back when the helper exits.
func configure(_ id: CGDirectDisplayID) {
    var config: CGDisplayConfigRef?
    guard CGBeginDisplayConfiguration(&config) == .success else { return }
    let options = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
    let modes = CGDisplayCopyAllDisplayModes(id, options) as? [CGDisplayMode] ?? []
    if let wanted = modes.first(where: { $0.width == Int(size.width) && $0.height == Int(size.height)
                                        && $0.pixelWidth == Int(size.width) * Int(scale) }) {
        CGConfigureDisplayWithDisplayMode(config, id, wanted, nil)
    }
    let origin = runOrigin(besides: id)
    CGConfigureDisplayOrigin(config, id, origin.x, origin.y)
    CGCompleteDisplayConfiguration(config, .forAppOnly)
}

/// Where the run display goes: past the right edge of every real display, so it
/// can never land on top of a second screen the way the main display's corner
/// can. The request asks for a 16 pt gap; WindowServer snaps display arrangements
/// to touch, so quiet-watch's ≤ 2 pt rule is the backstop for the shared edge.
func runOrigin(besides id: CGDirectDisplayID) -> (x: Int32, y: Int32) {
    var count: UInt32 = 0
    CGGetActiveDisplayList(0, nil, &count)
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    CGGetActiveDisplayList(count, &ids, &count)
    let main = CGDisplayBounds(CGMainDisplayID())
    var right = main.maxX
    for display in ids.prefix(Int(count)) where display != id {
        guard CGDisplayVendorNumber(display) != vendorID || CGDisplayModelNumber(display) != productID else { continue }
        right = max(right, CGDisplayBounds(display).maxX)
    }
    return (Int32((right + 16).rounded(.up)), Int32(main.minY.rounded()))
}
configure(id)
hold(id)
