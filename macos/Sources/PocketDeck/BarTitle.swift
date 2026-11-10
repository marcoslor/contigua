// The Framed bar's centred name (WIN-67..69): the app's name, or the phone's
// in the Phone Mirror, on the bar's line, with a tone that follows the band
// behind it. Everything here is pure or a value type: the view (StreamChrome)
// reads the same layout and machine the tests pin.

import AppKit
import CoreImage

/// One bar title's tone. `light` is white ink (for a dark band), `dark` is
/// black ink (for a light band); the names are the ink's, never the window's
/// appearance.
enum BarTone: String, CaseIterable {
    case light
    case dark

    var ink: NSColor {
        switch self {
        case .light: return .white
        case .dark: return .black
        }
    }

    /// WCAG relative luminance of the ink: pure white or black.
    var inkLuminance: Double {
        switch self {
        case .light: return 1
        case .dark: return 0
        }
    }

    /// The tone whose ink keeps the better contrast over `luminance`; the
    /// first sample's choice, where either may pass.
    static func preferred(for luminance: Double) -> BarTone {
        contrast(.light, over: luminance) >= contrast(.dark, over: luminance) ? .light : .dark
    }

    /// WCAG contrast between the tone's ink and a band of `luminance`.
    static func contrast(_ tone: BarTone, over luminance: Double) -> Double {
        let ink = tone.inkLuminance
        let lighter = max(ink, luminance)
        let darker = min(ink, luminance)
        return (lighter + 0.05) / (darker + 0.05)
    }
}

/// Where the tone changes, both derived from one contrast limit: `toDark` is
/// the band luminance where white ink falls below it, `toLight` where black
/// ink does. Between them either ink passes, so the current tone is kept
/// (hysteresis).
struct BarToneThresholds: Equatable {
    var toDark: Double
    var toLight: Double

    static func forContrast(_ contrast: Double) -> BarToneThresholds {
        BarToneThresholds(toDark: 1.05 / contrast - 0.05,
                          toLight: contrast * 0.05 - 0.05)
    }

    static let standard = BarToneThresholds.forContrast(BarTitle.minimumContrast)
}

/// The bar title's two states and its one event: a luminance sample of the
/// band behind it. Pure; the view applies the returned change.
struct BarToneMachine: Equatable {
    enum Event: Equatable {
        case sample(Double)
    }

    enum Change: Equatable {
        /// The first sample decided the tone; the title appears in it.
        case baseline(BarTone)
        case changed(BarTone)
        /// A sample that keeps the tone; no fade, no log line.
        case ignored
    }

    private(set) var tone: BarTone = .light
    private(set) var hasSample = false
    let thresholds: BarToneThresholds

    init(thresholds: BarToneThresholds = .standard) {
        self.thresholds = thresholds
    }

    mutating func handle(_ event: Event) -> Change {
        switch event {
        case .sample(let luminance):
            guard luminance.isFinite else { return .ignored }
            if !hasSample {
                hasSample = true
                tone = BarTone.preferred(for: luminance)
                return .baseline(tone)
            }
            switch tone {
            case .light:
                guard luminance >= thresholds.toDark else { return .ignored }
                tone = .dark
                return .changed(.dark)
            case .dark:
                guard luminance <= thresholds.toLight else { return .ignored }
                tone = .light
                return .changed(.light)
            }
        }
    }
}

/// The band behind the title, as the title sees it: the mirror's frame under
/// the 14 % window-background tint and the white haze at the title's line.
/// All values are WCAG relative luminances.
enum BarToneEstimate {
    static func band(frameLuminance: Double, tintLuminance: Double,
                     tintAlpha: CGFloat = BarTitle.tintAlpha,
                     hazeAtTitle: Double) -> Double {
        let tinted = frameLuminance * (1 - Double(tintAlpha)) + tintLuminance * Double(tintAlpha)
        let haze = min(max(hazeAtTitle, 0), 1)
        return tinted * (1 - haze) + haze
    }
}

/// The title's numbers and its pure layout. The title is one line, centred
/// on the bar's line, 8 pt clear of the lights and the right-hand row.
enum BarTitle {
    static let pointSize: CGFloat = 13
    static let weight: NSFont.Weight = .semibold
    /// Clearance from the traffic lights and the right-hand controls.
    static let sideGap: CGFloat = 8
    /// Narrower than this and the title hides instead of shrinking further.
    static let minimumWidth: CGFloat = 40
    /// The cross-fade between tones.
    static let fadeDuration: TimeInterval = 0.15
    /// The window-background tint over the mirror.
    static let tintAlpha: CGFloat = 0.14
    /// The haze gradient's alpha at the title's centre line: the gradient is
    /// full at the window's top edge and clear at the seam, so the line at
    /// the band's middle sees half of it.
    static let hazeAtTitle: Double = 0.5
    /// WCAG AA for body text; `bar_title_contrast_min` in nfr-limits.json
    /// carries the same number for the e2e check.
    static let minimumContrast: Double = 4.5

    static func font() -> NSFont {
        .systemFont(ofSize: pointSize, weight: weight)
    }

    /// The text's one-line width, rounded up like an AppKit field.
    static func textWidth(_ text: String) -> CGFloat {
        let attributed = NSAttributedString(string: text, attributes: [.font: font()])
        return ceil(attributed.size().width)
    }

    /// The title's frame in the chrome's coordinates (origin bottom-left),
    /// nil when it is too narrow or has no text. `lightsEnd` is the right
    /// edge of the zoom light's slot; `rightRowStart` is the first pixel of
    /// the kind's action capsules (or of the Live Text capsule when there are
    /// none), so the title yields its width to both.
    static func frame(text: String?, windowWidth: CGFloat, barHeight: CGFloat,
                      boundsHeight: CGFloat, lightsEnd: CGFloat,
                      rightRowStart: CGFloat) -> NSRect? {
        guard let text, !text.isEmpty, barHeight > 0, windowWidth > 0 else { return nil }
        let left = lightsEnd + sideGap
        let right = rightRowStart - sideGap
        guard right > left else { return nil }
        let available = right - left
        guard available >= minimumWidth else { return nil }
        let width = min(textWidth(text), available)
        let height = ceil(font().ascender - font().descender + font().leading)
        return NSRect(x: left + (available - width) / 2,
                      y: boundsHeight - barHeight + (barHeight - height) / 2,
                      width: width, height: height)
    }

    /// The right edge of the zoom light's slot: where the title's clearance
    /// from the lights begins.
    static var lightsEnd: CGFloat {
        BarGeometry.lightInset + 2 * BarGeometry.lightSpacing + BarGeometry.lightSide
    }
}

/// What each window kind puts in its bar (WIN-68, MIRROR-23). Only names,
/// never a host, URL, task label or placeholder.
enum BarTitleName {
    /// An app window: the app's own label alone, trimmed.
    static func app(_ label: String?) -> String? {
        trimmed(label)
    }

    /// The Phone Mirror: the phone's display name (the nickname first).
    static func phone(displayName: String, fallback: String?) -> String? {
        if let display = trimmed(displayName) { return display }
        return trimmed(fallback)
    }

    /// A link or a handoff window: its app's name once the phone has reported
    /// the package; nothing before that (a host or URL never rides the bar).
    static func adoptedApp(_ label: String?) -> String? {
        trimmed(label)
    }

    private static func trimmed(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

extension NSColor {
    /// WCAG relative luminance of this colour in sRGB; nil when it cannot be
    /// converted. Alpha is the colour's own, not blended with anything.
    var relativeLuminance: Double? {
        guard let srgb = usingColorSpace(.sRGB) else { return nil }
        return 0.2126 * BandLuminance.linear(Double(srgb.redComponent))
            + 0.7152 * BandLuminance.linear(Double(srgb.greenComponent))
            + 0.0722 * BandLuminance.linear(Double(srgb.blueComponent))
    }
}

/// What the chrome needs from the video to tone the bar's title (WIN-69).
protocol BarToneSource: AnyObject {
    /// Changes when a new frame reaches the display layer.
    var frameStamp: UInt64 { get }
    /// The mean relative luminance of the displayed picture's top band over
    /// the horizontal fractions `xFrom...xTo` of its width; the band is
    /// `bandFraction` of its height, measured from its top. The completion
    /// runs on the main queue; nil when there is no readable frame.
    func topBandLuminance(xFrom: CGFloat, xTo: CGFloat, bandFraction: CGFloat,
                          completion: @escaping (Double?) -> Void)
}

/// One frame's top-band luminance for the tone machine (WIN-69). A decoder
/// gives back 32BGRA, a bi-planar 4:2:0 buffer or a losslessly compressed
/// buffer; the first two are read in place, the last through Core Image and
/// only for the requested rectangle.
enum BandLuminance {    /// Mean WCAG relative luminance of `buffer` inside `rect`, which is in
    /// pixels with the origin at the buffer's top-left. A grid of at most
    /// 32×8 samples: a mean, not a full readback. Nil for a format it cannot
    /// read, an empty rect or a missing base address.
    static func mean(of buffer: CVPixelBuffer, rect: CGRect) -> Double? {
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        guard width > 0, height > 0 else { return nil }
        let clipped = rect.intersection(CGRect(x: 0, y: 0, width: width, height: height))
        guard clipped.width >= 1, clipped.height >= 1 else { return nil }
        let format = CVPixelBufferGetPixelFormatType(buffer)
        if format == kCVPixelFormatType_32BGRA {
            return meanDirect(buffer, rect: clipped) { base, stride, x, y in
                let offset = y * stride + x * 4
                let b = Double(base.load(fromByteOffset: offset + 0, as: UInt8.self)) / 255
                let g = Double(base.load(fromByteOffset: offset + 1, as: UInt8.self)) / 255
                let r = Double(base.load(fromByteOffset: offset + 2, as: UInt8.self)) / 255
                return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
            }
        }
        if format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            || format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange {
            let videoRange = format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            guard CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess,
                  let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else { return nil }
            defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
            let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
            return grid(rect: clipped) { x, y in
                let raw = Double(base.load(fromByteOffset: y * stride + x, as: UInt8.self))
                let level = videoRange ? min(255, max(0, (raw - 16) * 255 / 219)) : raw
                return linear(level / 255)
            }
        }
        if format == losslessVideoRange || format == losslessFullRange {
            return meanThroughCoreImage(of: buffer, rect: clipped)
        }
        return nil
    }

    /// The same mean for any buffer Core Image can read, over one small
    /// render of the requested rectangle. The buffer's rows run top-down and
    /// Core Image's coordinates bottom-up.
    static func meanThroughCoreImage(of buffer: CVPixelBuffer, rect: CGRect) -> Double? {
        let width = Int(rect.width.rounded())
        let height = Int(rect.height.rounded())
        guard width > 0, height > 0 else { return nil }
        var output: CVPixelBuffer?
        let attributes: [String: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
        ]
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                  kCVPixelFormatType_32BGRA,
                                  attributes as CFDictionary, &output) == kCVReturnSuccess,
              let output else { return nil }
        let image = CIImage(cvPixelBuffer: buffer)
        let source = CGRect(x: rect.minX, y: image.extent.height - rect.maxY,
                            width: rect.width, height: rect.height)
        let cropped = image.cropped(to: source)
            .transformed(by: CGAffineTransform(translationX: -source.minX, y: -source.minY))
        context.render(cropped, to: output,
                       bounds: CGRect(x: 0, y: 0, width: width, height: height),
                       colorSpace: CGColorSpaceCreateDeviceRGB())
        return mean(of: output, rect: CGRect(x: 0, y: 0, width: width, height: height))
    }

    /// The lossless-compressed forms of 420v/420f a display layer hands back.
    static let losslessVideoRange: UInt32 = 0x26387630  // '&8v0'
    static let losslessFullRange: UInt32 = 0x26386630  // '&8f0'

    private static let context = CIContext(options: [.cacheIntermediates: false])

    private static func meanDirect(_ buffer: CVPixelBuffer, rect: CGRect,
                                   luma: (UnsafeRawPointer, Int, Int, Int) -> Double) -> Double? {
        guard CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess,
              let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        return grid(rect: rect) { x, y in luma(base, stride, x, y) }
    }

    /// At most 32×8 even samples across the rect, row-major from its top.
    private static func grid(rect: CGRect, value: (Int, Int) -> Double) -> Double {
        let columns = min(32, max(1, Int(rect.width)))
        let rows = min(8, max(1, Int(rect.height)))
        var total = 0.0
        var count = 0
        for row in 0..<rows {
            let y = Int(rect.minY) + (row * Int(rect.height)) / rows
            for column in 0..<columns {
                let x = Int(rect.minX) + (column * Int(rect.width)) / columns
                total += value(x, y)
                count += 1
            }
        }
        return count > 0 ? total / Double(count) : 0
    }

    /// sRGB → WCAG relative luminance's linear form (one channel).
    static func linear(_ value: Double) -> Double {
        value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }
}

