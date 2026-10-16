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
// serial = the profile's hash), so macOS sees no new display: no extra ColourSync
// profile, no new arrangement entry. It is placed at the main display's
// bottom-right corner, where it touches none of the person's screens.
//
//   pd-vdisplay --profile NAME
//
// Prints one line once the display is configured —
//   id=123 w=1280 h=800 scale=1
// — and then holds the display until SIGTERM/SIGINT (the display goes away with
// this process). check-e2e reads that line; the app is told nothing and finds
// the display by its ids.

import CoreGraphics
import Foundation

let arguments = CommandLine.arguments
func argument(_ name: String) -> String? {
    arguments.indices.first { arguments[$0] == name && $0 + 1 < arguments.count }.map { arguments[$0 + 1] }
}

guard let profile = argument("--profile") else {
    FileHandle.standardError.write(Data("usage: pd-vdisplay --profile NAME\n".utf8))
    exit(2)
}

// VirtualDisplay.swift's ids: quiet-watch, the backdrop tool and the app all
// look for them.
let vendorID: UInt32 = 0x5044
let productID: UInt32 = 0xE2E0

/// The run's screen: 1280x800 at 1x (VirtualDisplay.swift's pointSize). Small on
/// purpose — the display's pixels are what WindowServer composites and what
/// colorsync re-profiles every time a display appears or goes away, and the
/// phone's video is scaled into the window anyway. 1x because nothing in the app
/// or the checks needs Retina pixels here.
enum Screen {
    static let width: UInt = 1280
    static let height: UInt = 800
    static let scale: UInt = 1
}

/// FNV-1a of the profile name, the app's function (VirtualDisplaySerialTests):
/// one stable identity per profile.
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

func modeClass(width: UInt, height: UInt) -> NSObject? {
    let name = "CGVirtualDisplayMode"
    let selector = NSSelectorFromString("initWithWidth:height:refreshRate:")
    guard let cls = NSClassFromString(name), class_respondsToSelector(cls, selector) else { return nil }
    let initFn = unsafeBitCast(class_getMethodImplementation(cls, selector), to: InitModeFn.self)
    return initFn(allocated(cls), selector, width, height, 60)?.takeRetainedValue() as? NSObject
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

// MARK: The display

let size = (width: Screen.width, height: Screen.height)
let scale = Screen.scale
guard let descriptor = make("CGVirtualDisplayDescriptor"),
      let settings = make("CGVirtualDisplaySettings"),
      let mode = modeClass(width: size.width, height: size.height),
      let makeDisplay = displayMaker() else {
    FileHandle.standardError.write(Data("pd-vdisplay: no CGVirtualDisplay on this macOS\n".utf8))
    exit(1)
}
descriptor.setValue("PocketDeck e2e", forKey: "name")
descriptor.setValue(size.width * scale, forKey: "maxPixelsWide")
descriptor.setValue(size.height * scale, forKey: "maxPixelsHigh")
descriptor.setValue(NSValue(size: NSSize(width: 340, height: 212)), forKey: "sizeInMillimeters")
descriptor.setValue(vendorID, forKey: "vendorID")
descriptor.setValue(productID, forKey: "productID")
descriptor.setValue(serialNumber(profile: profile), forKey: "serialNum")
// The display is created after the descriptor is filled in: init reads it.
guard let handle = makeDisplay(descriptor) else {
    FileHandle.standardError.write(Data("pd-vdisplay: CGVirtualDisplay init failed\n".utf8))
    exit(1)
}
settings.setValue([mode], forKey: "modes")
settings.setValue(scale == 2 ? 1 : 0, forKey: "hiDPI")
guard apply(settings, to: handle),
      let id = (handle.value(forKey: "displayID") as? NSNumber)?.uint32Value, id != 0 else {
    FileHandle.standardError.write(Data("pd-vdisplay: the virtual display refused its settings\n".utf8))
    exit(1)
}

// The mode and the corner origin, for this process's lifetime only (.forAppOnly):
// the person's arrangement is back when the helper exits.
func configure(_ id: CGDirectDisplayID) {
    var config: CGDisplayConfigRef?
    guard CGBeginDisplayConfiguration(&config) == .success else { return }
    let options = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
    let modes = CGDisplayCopyAllDisplayModes(id, options) as? [CGDisplayMode] ?? []
    if let wanted = modes.first(where: { $0.width == Int(size.width) && $0.height == Int(size.height)
                                        && $0.pixelWidth == Int(size.width) * Int(scale) }) {
        CGConfigureDisplayWithDisplayMode(config, id, wanted, nil)
    }
    let main = CGDisplayBounds(CGMainDisplayID())
    CGConfigureDisplayOrigin(config, id, Int32(main.maxX), Int32(main.maxY))
    CGCompleteDisplayConfiguration(config, .forAppOnly)
}
configure(id)

print("id=\(id) w=\(size.width) h=\(size.height) scale=\(scale)")
fflush(stdout)

signal(SIGTERM) { _ in exit(0) }
signal(SIGINT) { _ in exit(0) }
// The descriptor's queue is the main queue, and the display lives as long as
// this process: hold it here.
RunLoop.main.run()
