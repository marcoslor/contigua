// "Show Touches" starts on for Macs with a trackpad: the overlay exists for
// trackpad gestures, so the first gesture shows it without a trip to the menu.
// Once the person toggles the item, their stored choice always wins.

import Foundation
import IOKit.hid

enum ShowTouchesDefault {
    /// The value before the person has ever toggled View → Show Touches.
    static func resolve(hasTrackpad: Bool, stored: Bool?) -> Bool {
        stored ?? hasTrackpad
    }
}

enum TrackpadPresence {
    /// A trackpad is among the system's HID devices — the built-in one or a
    /// connected one — detected by its digitizer/touchpad usage (public IOKit).
    static func anyTrackpad() -> Bool {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matching: [String: Any] = [
            kIOHIDDeviceUsagePageKey: kHIDPage_Digitizer,
            kIOHIDDeviceUsageKey: kHIDUsage_Dig_TouchPad,
        ]
        IOHIDManagerSetDeviceMatching(manager, (matching as NSDictionary) as CFDictionary)
        IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        defer { IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone)) }
        guard let devices = IOHIDManagerCopyDevices(manager) else { return false }
        return CFSetGetCount(devices) > 0
    }
}
