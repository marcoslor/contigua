// M2's panel-pixel cap (ISS-40): a display's real pixel width, and the factor
// that takes a window's backing pixels down to it on a scaled display.
//
// The panel's native width comes from Core Graphics' mode list: the mode with
// the native flag is the panel's own resolution. A scaled mode's pixelWidth
// can be larger than the panel (3008 pt "looks like" is 6016 backing pixels on
// a 3840 panel), so pixelWidth alone is not the panel. A display that does not
// set the flag falls back to the largest point-size mode's pixelWidth: a panel
// cannot show a mode larger than itself, and that mode is the closest thing to
// its native shape.

import AppKit
import CoreGraphics
import IOKit

/// One entry of `CGDisplayCopyAllDisplayModes`, pure so K2 can drive it.
struct DisplayModeSize: Equatable {
    var pointWidth: Int
    var pointHeight: Int
    var pixelWidth: Int
    var pixelHeight: Int
    var isNative: Bool
}

enum PanelCap {
    static func nativePixelWidth(modes: [DisplayModeSize]) -> Int? {
        if let native = modes.first(where: { $0.isNative && $0.pixelWidth > 0 }) {
            return native.pixelWidth
        }
        let largest = modes.max {
            $0.pointWidth * $0.pointHeight < $1.pointWidth * $1.pointHeight
        }
        return largest.flatMap { $0.pixelWidth > 0 ? $0.pixelWidth : nil }
    }

    /// panel width ÷ the display's backing width, never above 1.
    static func factor(panelWidth: Int, backingWidth: Int) -> Double {
        guard panelWidth > 0, backingWidth > 0 else { return 1 }
        return min(1, Double(panelWidth) / Double(backingWidth))
    }

    /// The cap for a window on `screen`; 1 when the screen is not scaled or the
    /// modes cannot be read.
    static func factor(for screen: NSScreen?) -> Double {
        guard let values = values(for: screen) else { return 1 }
        return factor(panelWidth: values.panelWidth, backingWidth: values.backingWidth)
    }

    /// The display's id, the panel's native width and the display's backing
    /// width. nil when the screen has no display mode.
    static func values(for screen: NSScreen?) -> (displayID: CGDirectDisplayID, panelWidth: Int, backingWidth: Int)? {
        guard let screen else { return nil }
        let backing = Int((screen.frame.width * screen.backingScaleFactor).rounded())
        guard backing > 0 else { return nil }
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        guard let number = screen.deviceDescription[key] as? NSNumber else { return nil }
        let id = number.uint32Value
        guard let panel = nativePixelWidth(displayID: id) else { return nil }
        return (id, panel, backing)
    }

    static func nativePixelWidth(displayID: CGDirectDisplayID) -> Int? {
        let modes = CGDisplayCopyAllDisplayModes(displayID, nil) as? [CGDisplayMode] ?? []
        let sizes = modes.map { mode in
            DisplayModeSize(pointWidth: mode.width,
                            pointHeight: mode.height,
                            pixelWidth: mode.pixelWidth,
                            pixelHeight: mode.pixelHeight,
                            isNative: mode.ioFlags & UInt32(kDisplayModeNativeFlag) != 0)
        }
        return nativePixelWidth(modes: sizes)
    }
}
