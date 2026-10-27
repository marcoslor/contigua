// The invisible screen of background mode: a virtual display (CoreGraphics'
// private CGVirtualDisplay API, the one screen-extender apps use) that lives as
// long as the process — unless one is already there: an e2e run holds a single
// display of these ids for the whole run (pd-vdisplay.swift) and the app
// adopts it instead of creating and destroying a display on every launch — and
// the hooks that put every window the app shows onto it. Windows there are on
// screen for macOS (not occluded, so streams keep running and `screencapture -l`
// works) but on none of the person's displays. The display is placed so it
// touches the main display only at its bottom-right corner, where the person's
// pointer rarely goes.

import AppKit
import CoreGraphics

/// Where the display and the windows go; pure maths, unit-tested.
enum BackgroundPlacement {
    /// CoreGraphics origin (top-left, y down) of a display that touches `main`
    /// only at its bottom-right corner.
    static func cornerOrigin(touching main: CGRect) -> CGPoint {
        CGPoint(x: main.maxX, y: main.maxY)
    }

    /// The display's frame in AppKit coordinates (y up from the bottom of the
    /// primary display, which is `primaryHeight` tall).
    static func cocoaFrame(ofDisplay bounds: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: bounds.minX, y: primaryHeight - bounds.maxY, width: bounds.width, height: bounds.height)
    }

    /// `frame` moved onto `target`: it keeps its offset from the screen it was
    /// laid out on (`sources`, the first holding its centre, else the first),
    /// then is pushed inside `target`, top-left winning when it is too big.
    /// A frame already touching `target` is only pushed inside.
    static func place(_ frame: CGRect, sources: [CGRect], onto target: CGRect) -> CGRect {
        let centre = CGPoint(x: frame.midX, y: frame.midY)
        let source = target.intersects(frame) ? target
            : sources.first { $0.contains(centre) } ?? sources.first ?? target
        var origin = CGPoint(x: target.minX + frame.minX - source.minX,
                             y: target.minY + frame.minY - source.minY)
        origin.x = max(min(origin.x, target.maxX - frame.width), target.minX)
        origin.y = min(max(origin.y, target.minY), target.maxY - frame.height)
        return CGRect(origin: origin, size: frame.size)
    }
}

final class VirtualDisplay {
    /// Its EDID-style ids: tools (the e2e backdrop, the quiet watcher, the run's
    /// pd-vdisplay helper) find it by them.
    static let vendorID: UInt32 = 0x5044
    static let productID: UInt32 = 0xE2E0

    /// The one display of this process, once `create()` succeeded.
    private(set) static var shared: VirtualDisplay?

    let displayID: CGDirectDisplayID
    /// Holds a display this process created: it goes away when this object
    /// (the process) does. nil for an adopted one, which belongs to the run
    /// that made it (pd-vdisplay) and is left alone here.
    private let handle: NSObject?

    private init(displayID: CGDirectDisplayID, handle: NSObject?) {
        self.displayID = displayID
        self.handle = handle
    }

    /// A display of this app's ids that is already online, if any. An e2e run
    /// holds one for the whole run (scripts/pd-vdisplay.swift): the app is not
    /// told about it and finds it here, so the checks' ~45 launches share one
    /// display instead of reconfiguring the system's displays 45 times.
    static func existingDisplay() -> CGDirectDisplayID? {
        var count: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetOnlineDisplayList(count, &ids, &count)
        return ids.prefix(Int(count)).first {
            CGDisplayVendorNumber($0) == vendorID && CGDisplayModelNumber($0) == productID
        }
    }

    /// The display's frame in AppKit coordinates.
    var frame: CGRect {
        BackgroundPlacement.cocoaFrame(ofDisplay: CGDisplayBounds(displayID),
                                       primaryHeight: CGDisplayBounds(CGMainDisplayID()).height)
    }

    /// The quiet-mode screen: 1280x800 pt at 1x (1280x800 px). A background run
    /// only ever needs a place for its windows to be on screen; the person's
    /// screen size at 2x (3360x2100 px) cost the window server, colorsync and
    /// every running app a re-layout for no benefit — the video is scaled into
    /// the window anyway.
    static let pointSize = (width: UInt(1280), height: UInt(800))
    /// 1x: the display's pixels are its points. 2x would double every byte the
    /// window server composites; nothing in the app or the checks needs it.
    static let backingScale: UInt = 1

    /// A display of this size at its bottom-right corner. nil (and a log line)
    /// when this macOS refuses the API.
    @discardableResult
    /// FNV-1a of the profile name: the same profile always gets the same display.
    static func serialNumber(profile: String) -> UInt32 {
        var hash: UInt32 = 0x811C_9DC5
        for byte in profile.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 0x0100_0193
        }
        return hash == 0 ? 1 : hash
    }

    @MainActor
    static func create() -> VirtualDisplay? {
        if let shared { return shared }
        if let existing = existingDisplay() {
            let adopted = VirtualDisplay(displayID: existing, handle: nil)
            shared = adopted
            Log.app.notice("background: using the virtual display \(existing, privacy: .public) an e2e run holds at \(String(describing: CGDisplayBounds(existing)), privacy: .public)")
            return adopted
        }
        let main = CGDisplayBounds(CGMainDisplayID())
        let width = pointSize.width
        let height = pointSize.height
        guard let descriptor = make("CGVirtualDisplayDescriptor"),
              let settings = make("CGVirtualDisplaySettings"),
              let mode = alloc("CGVirtualDisplayMode", initWith: width, height),
              let makeDisplay = displayMaker() else {
            Log.app.error("background: no virtual display on this macOS; windows stay on the real screens")
            return nil
        }
        descriptor.setValue("PocketDeck e2e", forKey: "name")
        descriptor.setValue(width * backingScale, forKey: "maxPixelsWide")
        descriptor.setValue(height * backingScale, forKey: "maxPixelsHigh")
        descriptor.setValue(NSValue(size: NSSize(width: 340, height: 212)), forKey: "sizeInMillimeters")
        descriptor.setValue(vendorID, forKey: "vendorID")
        descriptor.setValue(productID, forKey: "productID")
        // One stable identity per profile: macOS keeps a colour profile and an
        // arrangement entry for every display identity it has seen, so a new
        // serial per launch piled up hundreds of ghost displays and kept
        // colorsync and the window server busy.
        descriptor.setValue(serialNumber(profile: AppEnvironment.shared.options.profileName), forKey: "serialNum")
        descriptor.setValue(DispatchQueue.main, forKey: "queue")
        // The descriptor is read by init, so the display is made after it is filled in.
        guard let handle = makeDisplay(descriptor) else {
            Log.app.error("background: CGVirtualDisplay init failed")
            return nil
        }
        settings.setValue([mode], forKey: "modes")
        settings.setValue(backingScale == 2 ? 1 : 0, forKey: "hiDPI")
        guard apply(settings, to: handle), let id = (handle.value(forKey: "displayID") as? NSNumber)?.uint32Value, id != 0 else {
            Log.app.error("background: the virtual display refused its settings")
            return nil
        }
        configure(id, pointSize: pointSize, corner: BackgroundPlacement.cornerOrigin(touching: main))
        let created = VirtualDisplay(displayID: id, handle: handle)
        shared = created
        Log.app.notice("background: virtual display \(id, privacy: .public) at \(String(describing: CGDisplayBounds(id)), privacy: .public)")
        return created
    }

    /// The mode and the corner origin, for this process's lifetime only
    /// (`.forAppOnly`): the person's arrangement is back when the app exits.
    private static func configure(_ id: CGDirectDisplayID, pointSize: (UInt, UInt), corner: CGPoint) {
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success else { return }
        let options = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
        let modes = CGDisplayCopyAllDisplayModes(id, options) as? [CGDisplayMode] ?? []
        let wanted = Int(pointSize.0) * Int(backingScale)
        if let mode = modes.first(where: { $0.width == Int(pointSize.0) && $0.height == Int(pointSize.1)
                                           && $0.pixelWidth == wanted }) {
            CGConfigureDisplayWithDisplayMode(config, id, mode, nil)
        }
        CGConfigureDisplayOrigin(config, id, Int32(corner.x), Int32(corner.y))
        CGCompleteDisplayConfiguration(config, .forAppOnly)
    }

    // MARK: The private classes, reached through the Objective-C runtime

    private typealias AllocFn = @convention(c) (AnyClass, Selector) -> Unmanaged<AnyObject>
    private typealias InitObjectFn = @convention(c) (AnyObject, Selector, AnyObject) -> Unmanaged<AnyObject>?
    private typealias InitModeFn = @convention(c) (AnyObject, Selector, UInt, UInt, Double) -> Unmanaged<AnyObject>?
    private typealias ApplyFn = @convention(c) (AnyObject, Selector, AnyObject) -> Bool

    private static func make(_ name: String) -> NSObject? {
        (NSClassFromString(name) as? NSObject.Type)?.init()
    }

    /// `[[cls alloc] init…]` as one call: the alloc'd object is consumed by init.
    private static func allocated(_ cls: AnyClass) -> AnyObject {
        let selector = NSSelectorFromString("alloc")
        let alloc = unsafeBitCast(class_getMethodImplementation(object_getClass(cls), selector), to: AllocFn.self)
        return alloc(cls, selector).takeUnretainedValue()
    }

    private static func alloc(_ name: String, initWith width: UInt, _ height: UInt) -> NSObject? {
        let selector = NSSelectorFromString("initWithWidth:height:refreshRate:")
        guard let cls = NSClassFromString(name), class_respondsToSelector(cls, selector) else { return nil }
        let initFn = unsafeBitCast(class_getMethodImplementation(cls, selector), to: InitModeFn.self)
        return initFn(allocated(cls), selector, width, height, 60)?.takeRetainedValue() as? NSObject
    }

    /// A function that makes the display from the filled-in descriptor.
    private static func displayMaker() -> ((NSObject) -> NSObject?)? {
        let selector = NSSelectorFromString("initWithDescriptor:")
        guard let cls = NSClassFromString("CGVirtualDisplay"), class_respondsToSelector(cls, selector) else { return nil }
        let initFn = unsafeBitCast(class_getMethodImplementation(cls, selector), to: InitObjectFn.self)
        return { descriptor in initFn(allocated(cls), selector, descriptor)?.takeRetainedValue() as? NSObject }
    }

    private static func apply(_ settings: NSObject, to display: NSObject) -> Bool {
        let selector = NSSelectorFromString("applySettings:")
        guard display.responds(to: selector) else { return false }
        let applyFn = unsafeBitCast(class_getMethodImplementation(type(of: display), selector), to: ApplyFn.self)
        return applyFn(display, selector, settings)
    }
}

// MARK: - Windows onto the display

extension NSWindow {
    /// Swaps the ordering methods once, so a window is moved onto the virtual
    /// display before it first appears, wherever its own code placed it.
    @MainActor
    static func keepWindowsOnVirtualDisplay() {
        let pairs: [(Selector, Selector)] = [
            (#selector(NSWindow.order(_:relativeTo:)), #selector(NSWindow.pd_order(_:relativeTo:))),
            (#selector(NSWindow.orderFrontRegardless), #selector(NSWindow.pd_orderFrontRegardless)),
            (#selector(NSWindow.constrainFrameRect(_:to:)), #selector(NSWindow.pd_constrainFrameRect(_:to:))),
        ]
        for (original, replacement) in pairs {
            guard let a = class_getInstanceMethod(NSWindow.self, original),
                  let b = class_getInstanceMethod(NSWindow.self, replacement) else { continue }
            method_exchangeImplementations(a, b)
        }
        // A window moved later (a cascade step, a saved frame) is put back.
        NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: nil, queue: .main) { note in
            MainActor.assumeIsolated { (note.object as? NSWindow)?.moveOntoVirtualDisplay() }
        }
    }

    @objc private func pd_order(_ place: NSWindow.OrderingMode, relativeTo other: Int) {
        if place != .out { moveOntoVirtualDisplay() }
        pd_order(place, relativeTo: other)
    }

    @objc private func pd_orderFrontRegardless() {
        moveOntoVirtualDisplay()
        pd_orderFrontRegardless()
    }

    /// A window on the run's display keeps the size it was given. The display is
    /// small on purpose (VirtualDisplay.pointSize) and windows may be bigger than
    /// it: the checks resize a stream to a 1600x1200 pt window (C6) and the phone
    /// has to be told about all of it, while AppKit's own constraint would cut the
    /// frame down to the display's visible frame (800 pt) — and the app, which
    /// sets these frames rather than dragging them, would then stream less than it
    /// asked for. The app places the windows here itself (place(), above), so a
    /// frame that does not fit is not a frame the person is locked out of; every
    /// other screen keeps AppKit's constraint.
    @objc private func pd_constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        // AppKit constrains a frame to the window's screen (nil) or to a named
        // one: on the run's display, the asked-for frame wins for the windows
        // the app sizes from the phone's picture (a stream, the mirror). Every
        // other window — the Deck, Settings — is still fitted to that display:
        // an Accessibility resize there was left larger than the display, and
        // an AX resize re-applies its own frame, so the delegate never saw it.
        if let display = VirtualDisplay.shared, screen == nil || screen?.frame == display.frame {
            let target = screen ?? NSScreen.screens.first { $0.frame == display.frame }
            guard WindowFrameLimit.applies(to: self), target?.visibleFrame != nil else { return frameRect }
            return WindowFrameLimit.fitted(frameRect, for: self, screen: target)
        }
        return pd_constrainFrameRect(frameRect, to: screen)
    }

    /// Sheets and child windows follow their parent; the menu bar item and
    /// menus belong where macOS puts them.
    fileprivate func moveOntoVirtualDisplay() {
        guard let display = VirtualDisplay.shared, sheetParent == nil, parent == nil,
              level < .statusBar else { return }
        let target = display.frame
        guard !target.contains(frame) else { return }
        let real = NSScreen.screens.map(\.frame).filter { !$0.equalTo(target) }
        let primary = BackgroundPlacement.cocoaFrame(ofDisplay: CGDisplayBounds(CGMainDisplayID()),
                                                     primaryHeight: CGDisplayBounds(CGMainDisplayID()).height)
        setFrame(BackgroundPlacement.place(frame, sources: real.isEmpty ? [primary] : real, onto: target), display: false)
    }
}
