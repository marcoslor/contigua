// Compact's band (WIN-67, WIN-69, #147): the stream's top edge mirrored up into
// AppKit's transparent title bar by the system's NSBackgroundExtensionView,
// under clear glass, over an opaque backing in the band's own colour, with our
// title in the band's tone. Everything that decides the band's look lives here
// and is pure; StreamChrome.swift builds the views from it.
//
// The band is read from the picture on frames, not on a timer: the first frame
// of a picture at once, then at most once a second while frames come, never
// while the picture is still (BandSampleClock). One read is one Core Image
// area average over the picture's top rows, on a utility queue.

import AppKit
import CoreImage

/// The band's mean colour in sRGB, as one read of the picture gives it.
struct BandSample: Equatable {
    var red: Double
    var green: Double
    var blue: Double

    /// WCAG relative luminance.
    var luminance: Double {
        0.2126 * Self.linear(red) + 0.7152 * Self.linear(green) + 0.0722 * Self.linear(blue)
    }

    /// The colour, opaque: the band's backing under the mirror.
    var color: NSColor {
        NSColor(srgbRed: CGFloat(red), green: CGFloat(green), blue: CGFloat(blue), alpha: 1)
    }

    /// sRGB → linear, one channel.
    static func linear(_ value: Double) -> Double {
        value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }
}

/// The title's ink over the band (WIN-69): `.light` over a dark band, `.dark`
/// over a light one. The glass takes the opposite tint (#147), which pushes
/// the band away from the ink.
enum BarTone: String {
    case light
    case dark

    /// White and black ink have the same contrast over a band this bright.
    static let evenLuminance = 0.179
    /// How far past the even point the band must go before the ink changes,
    /// so the title does not flip on a scroll's noise. At either edge the
    /// held ink still keeps 4.5:1 over the band under its tint.
    static let toDark = 0.24
    static let toLight = 0.12

    /// The ink for a band of `luminance`, holding `current` inside the margin.
    static func next(_ current: BarTone?, luminance: Double) -> BarTone {
        switch current {
        case nil: return luminance < evenLuminance ? .light : .dark
        case .light?: return luminance > toDark ? .dark : .light
        case .dark?: return luminance < toLight ? .light : .dark
        }
    }

    /// The title's ink: solid white or black, the most contrast either side.
    var ink: NSColor { self == .light ? .white : .black }

    /// The appearance whose label colour is this ink: the title-bar controls
    /// take it, so their glyphs and Increase Contrast are the system's.
    var appearance: NSAppearance {
        NSAppearance(named: self == .light ? .darkAqua : .aqua) ?? NSAppearance.currentDrawing()
    }

    /// The glass's tint, 14 %, away from the ink (#147).
    var tint: NSColor {
        (self == .light ? NSColor.black : NSColor.white).withAlphaComponent(0.14)
    }
}

/// When to read the band: on a shown frame, at once for a new picture, then
/// at most once every `interval`, one read at a time. Frames are the clock:
/// a still picture is never read again.
struct BandSampleClock {
    static let interval: TimeInterval = 1.0
    private var last: TimeInterval?
    private var inFlight = false

    mutating func shouldSample(now: TimeInterval) -> Bool {
        guard !inFlight else { return false }
        if let last, now - last < Self.interval { return false }
        last = now
        inFlight = true
        return true
    }

    mutating func finished() { inFlight = false }

    /// A new picture (a style, size or config change): read the next frame.
    mutating func reset() { last = nil }
}

/// One read of the band: the mean colour of `rect` (pixels, origin at the
/// buffer's top-left) in a displayed frame, through one Core Image area
/// average, whatever the buffer's format.
enum BandReader {
    private static let context = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB) as Any,
                                                     .outputColorSpace: CGColorSpace(name: CGColorSpace.sRGB) as Any])

    static func sample(_ buffer: CVPixelBuffer, rect: CGRect) -> BandSample? {
        let image = CIImage(cvPixelBuffer: buffer)
        let height = image.extent.height
        // Core Image's origin is the bottom-left.
        let area = CGRect(x: rect.minX, y: height - rect.maxY, width: rect.width, height: rect.height)
            .intersection(image.extent)
        guard area.width >= 1, area.height >= 1,
              let filter = CIFilter(name: "CIAreaAverage",
                                    parameters: [kCIInputImageKey: image, kCIInputExtentKey: CIVector(cgRect: area)]),
              let output = filter.outputImage else { return nil }
        var pixel = [UInt8](repeating: 0, count: 4)
        context.render(output, toBitmap: &pixel, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                       format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        return BandSample(red: Double(pixel[0]) / 255, green: Double(pixel[1]) / 255, blue: Double(pixel[2]) / 255)
    }
}
