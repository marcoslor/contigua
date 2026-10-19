// "Show Touches" starts on for Macs with a trackpad: the overlay exists for
// trackpad gestures, so the first gesture shows it without a trip to the menu.
// Once the person toggles the item, their stored choice always wins.

import Foundation
import IOKit
import IOKit.hid

enum ShowTouchesDefault {
    /// The value before the person has ever toggled View → Show Touches.
    static func resolve(hasTrackpad: Bool, stored: Bool?) -> Bool {
        stored ?? hasTrackpad
    }
}

enum TrackpadPresence {
    /// A trackpad is among the system's HID devices — the built-in one or a
    /// connected one — found by its digitizer/touchpad usage in the I/O
    /// Registry. Only a lookup: no device is opened, so no Input Monitoring
    /// prompt.
    static func anyTrackpad() -> Bool {
        guard let matching = IOServiceMatching(kIOHIDDeviceKey) as NSMutableDictionary? else { return false }
        matching[kIOHIDDeviceUsagePageKey] = kHIDPage_Digitizer
        matching[kIOHIDDeviceUsageKey] = kHIDUsage_Dig_TouchPad
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else { return false }
        defer { IOObjectRelease(iterator) }
        let first = IOIteratorNext(iterator)
        guard first != 0 else { return false }
        IOObjectRelease(first)
        return true
    }
}
