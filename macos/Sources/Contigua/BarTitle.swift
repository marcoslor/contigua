// The Compact bar's centred name (WIN-67..69): the app's name, or the phone's
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

    /// The ink's contrast against the band's pixel that is worst for it:
    /// the brightest for white ink, the darkest for black.
    static func worstContrast(_ tone: BarTone, over band: BandRange) -> Double {
        contrast(tone, over: tone == .light ? band.high : band.low)
    }

    /// The ink whose worst pixel reads better; the first unresolved sample's
    /// choice (ties go to white, like `preferred`).
    static func betterWorstCase(over band: BandRange) -> BarTone {
        worstContrast(.light, over: band) >= worstContrast(.dark, over: band) ? .light : .dark
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
        case sample(BandRange)
    }

    enum Change: Equatable {
        /// The first sample decided the tone; the title appears in it.
        case baseline(BarTone)
        case changed(BarTone)
        /// A sample that keeps the tone; no fade, no log line.
        case ignored
        /// Neither ink reaches the limit over this band (the mid-grey case):
        /// the tone is kept and the caller says so once.
        case unresolved(BarTone)
    }

    private(set) var tone: BarTone = .light
    private(set) var hasSample = false
    let thresholds: BarToneThresholds

    init(thresholds: BarToneThresholds = .standard) {
        self.thresholds = thresholds
    }

    /// When neither ink passes, the other ink takes over only when its worst
    /// pixel's contrast is at least this many times the current one's: the
    /// unresolved band's own hysteresis, so a busy picture does not flicker
    /// and a band that clearly turned does not keep the first tone (#45).
    static let unresolvedSwitchRatio = 1.2

    /// Black ink passes when the band's darkest pixel is at or above
    /// `toLight`; white ink passes when its brightest pixel is at or below
    /// `toDark` (the two are the same 4.5:1 boundary from each ink's side).
    mutating func handle(_ event: Event) -> Change {
        switch event {
        case .sample(let band):
            guard band.isFinite else { return .ignored }
            let darkPasses = band.low >= thresholds.toLight
            let lightPasses = band.high <= thresholds.toDark
            if !hasSample {
                hasSample = true
                switch (darkPasses, lightPasses) {
                case (true, false):
                    tone = .dark
                    return .baseline(.dark)
                case (false, true):
                    tone = .light
                    return .baseline(.light)
                case (true, true):
                    tone = BarTone.preferred(for: band.mid)
                    return .baseline(tone)
                case (false, false):
                    tone = BarTone.betterWorstCase(over: band)
                    return .unresolved(tone)
                }
            }
            switch (darkPasses, lightPasses) {
            case (true, false):
                guard tone != .dark else { return .ignored }
                tone = .dark
                return .changed(.dark)
            case (false, true):
                guard tone != .light else { return .ignored }
                tone = .light
                return .changed(.light)
            case (true, true):
                // Hysteresis: both inks still pass, so the current one stays.
                return .ignored
            case (false, false):
                let other: BarTone = tone == .light ? .dark : .light
                if BarTone.worstContrast(other, over: band)
                    >= BarTone.worstContrast(tone, over: band) * Self.unresolvedSwitchRatio {
                    tone = other
                }
                return .unresolved(tone)
            }
        }
    }
}

/// A band's darkest and brightest pixel: the two numbers a contrast-safe
/// tone decision needs, because black ink is worst on the dark end and white
/// ink on the bright one.
struct BandRange: Equatable {
    var low: Double
    var high: Double

    var mid: Double { (low + high) / 2 }

    var isFinite: Bool { low.isFinite && high.isFinite && low <= high }
}

/// The band behind the title, as the title sees it: the mirror's frame under
/// the 14 % window-background tint and the white haze. The layers composite in
/// sRGB, so the estimate does too: blending WCAG-linear luminances directly
/// overestimates how much the white haze lifts a dark page. Inputs and the
/// result are WCAG relative luminances.
enum BarToneEstimate {
    /// The composited band range: the darkest frame pixel under the haze at
    /// the title's bottom line, the brightest under the haze at its top.
    static func blend(frame: BandRange, tintLuminance: Double,
                      tintAlpha: CGFloat = BarTitle.tintAlpha,
                      hazeTop: Double, hazeBottom: Double) -> BandRange {
        func composite(_ value: Double, haze: Double) -> Double {
            let srgb = encode(min(max(value, 0), 1))
            let tint = encode(min(max(tintLuminance, 0), 1))
            let tinted = srgb * (1 - Double(tintAlpha)) + tint * Double(tintAlpha)
            let alpha = min(max(haze, 0), 1)
            return decode(tinted * (1 - alpha) + alpha)
        }
        return BandRange(low: composite(frame.low, haze: hazeBottom),
                         high: composite(frame.high, haze: hazeTop))
    }

    /// sRGB transfer, the space the bar's layers composite in.
    static func encode(_ value: Double) -> Double {
        value <= 0.0031308 ? value * 12.92 : 1.055 * pow(value, 1 / 2.4) - 0.055
    }

    static func decode(_ value: Double) -> Double {
        value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
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
    /// A name that does not fit whole needs at least this much room to be
    /// worth truncating: below it the middle ellipsis leaves two or three
    /// letters, which reads worse than no title.
    static let minimumTruncatedWidth: CGFloat = 96
    /// The cross-fade between tones.
    static let fadeDuration: TimeInterval = 0.15
    /// The window-background tint over the mirror.
    static let tintAlpha: CGFloat = 0.14
    /// The haze gradient's alpha at the title's centre line: the gradient is
    /// full at the window's top edge and clear at the seam, so the line at
    /// the band's middle sees half of it.
    static let hazeAtTitle: Double = 0.5
    /// How far the bar's blur spreads a picture pixel sideways under the
    /// title, as a share of the blur's radius: a Gaussian of radius r is
    /// taken as an even average over ±r/2, and the progressive mask is about
    /// half strength at the title's line, so a quarter. Deliberately short:
    /// a narrower average keeps more of a mark's extreme in the range, which
    /// errs towards "unresolved", never towards a wrong pass.
    static let blurReachPerRadius: CGFloat = 0.25
    /// WCAG AA for body text; `bar_title_contrast_min` in nfr-limits.json
    /// carries the same number for the e2e check.
    static let minimumContrast: Double = 4.5

    static func font() -> NSFont {
        .systemFont(ofSize: pointSize, weight: weight)
    }

    /// The one title field's construction, whatever the style: 13 pt semibold,
    /// one centred line, never editable, and the accessibility value comes from
    /// the window, not a label. The style owns only the colour and its frame.
    static func configure(_ field: NSTextField) {
        field.font = font()
        field.alignment = .center
        field.lineBreakMode = .byTruncatingMiddle
        field.usesSingleLineMode = true
        field.maximumNumberOfLines = 1
        field.isEditable = false
        field.isSelectable = false
        field.drawsBackground = false
        field.isBezeled = false
        field.setAccessibilityElement(false)
    }

    /// Puts `text` in a title field at `frame`: whole when it fits (clipping),
    /// middle-truncated only below the text's width, hidden with no frame.
    static func layOut(_ text: String?, in field: NSTextField, frame: NSRect?) {
        field.stringValue = text ?? ""
        guard let frame else {
            field.isHidden = true
            field.frame = .zero
            return
        }
        field.isHidden = false
        field.frame = frame
        field.lineBreakMode = lineBreakMode(text: text, width: frame.width)
    }

    /// The width a title field needs to draw `text` whole on one line: the
    /// cell's own measure, its edge padding included, rounded up. The glyphs'
    /// width plus a guess at the padding fell short by about 2 pt and clipped
    /// the last glyph of a name that "fit" ("Settings (FakePhone" — #45).
    static func textWidth(_ text: String) -> CGFloat {
        MainActor.assumeIsolated {
            let field = measuringField
            field.stringValue = text
            return ceil(field.cell?.cellSize.width ?? 0)
        }
    }

    /// A title field built like the drawn ones (`configure`, clipping), kept
    /// for measuring: its cell is the one whose edges decide the fit.
    @MainActor private static let measuringField: NSTextField = {
        let field = NSTextField(labelWithString: "")
        configure(field)
        field.lineBreakMode = .byClipping
        return field
    }()

    /// The field's line-break mode for a name in `width`. An `NSTextField`
    /// reserves the middle ellipsis's width even when the whole line fits, so
    /// a field exactly as wide as its name would always truncate: only ask
    /// for middle truncation when the frame is narrower than the line, and
    /// clip (which draws the whole line) otherwise.
    static func lineBreakMode(text: String?, width: CGFloat) -> NSLineBreakMode {
        guard let text else { return .byTruncatingMiddle }
        return width < textWidth(text) ? .byTruncatingMiddle : .byClipping
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
        guard let available = availableWidth(windowWidth: windowWidth, barHeight: barHeight,
                                             lightsEnd: lightsEnd, rightRowStart: rightRowStart),
              available >= minimumWidth else { return nil }
        if textWidth(text) > available, available < minimumTruncatedWidth { return nil }
        let width = min(textWidth(text), available)
        let height = ceil(font().ascender - font().descender + font().leading)
        // Centred on the bar's own line (the window's centre) while the room
        // allows it; clamped into the space the controls leave otherwise.
        let x = min(max(windowWidth / 2 - width / 2, lightsEnd + sideGap),
                    rightRowStart - sideGap - width)
        return NSRect(x: x, y: boundsHeight - barHeight + (barHeight - height) / 2,
                      width: width, height: height)
    }

    /// The text to draw and its frame, with the phone suffix dropped before the
    /// app's name is truncated: "<App> (<phone>)" whole when it fits, else
    /// "<App>" under the existing whole-name thresholds (96 pt to truncate,
    /// 40 pt to show at all). `base` is the name without the suffix.
    static func fitting(text: String?, base: String?, windowWidth: CGFloat, barHeight: CGFloat,
                        boundsHeight: CGFloat, lightsEnd: CGFloat,
                        rightRowStart: CGFloat) -> (text: String, frame: NSRect)? {
        guard let text, !text.isEmpty else { return nil }
        guard let available = availableWidth(windowWidth: windowWidth, barHeight: barHeight,
                                             lightsEnd: lightsEnd, rightRowStart: rightRowStart),
              available >= minimumWidth else { return nil }
        let chosen: String
        if textWidth(text) <= available {
            chosen = text
        } else if let base, !base.isEmpty, base != text {
            // The suffix goes first, never the app's own name.
            chosen = base
        } else {
            chosen = text
        }
        guard let frame = frame(text: chosen, windowWidth: windowWidth, barHeight: barHeight,
                                boundsHeight: boundsHeight, lightsEnd: lightsEnd,
                                rightRowStart: rightRowStart) else { return nil }
        return (chosen, frame)
    }

    /// The width the title may use between the lights and the right-hand row,
    /// nil when the bar has no room.
    static func availableWidth(windowWidth: CGFloat, barHeight: CGFloat,
                               lightsEnd: CGFloat, rightRowStart: CGFloat) -> CGFloat? {
        guard barHeight > 0, windowWidth > 0 else { return nil }
        let left = lightsEnd + sideGap
        let right = rightRowStart - sideGap
        guard right > left else { return nil }
        return right - left
    }

    /// The right edge of the zoom light's slot: where the title's clearance
    /// from the lights begins.
    static var lightsEnd: CGFloat {
        BarGeometry.lightInset + 2 * BarGeometry.lightSpacing + BarGeometry.lightSide
    }
}

/// What each window kind puts in its bar (WIN-68, MIRROR-26). Only names,
/// never a host, URL, task label or placeholder.
enum BarTitleName {
    /// An app window: the app's own label alone, trimmed.
    static func app(_ label: String?) -> String? {
        trimmed(label)
    }

    /// The bar's whole name for an app: "<App> (<phone>)" while the phone's
    /// display name is known and is not already the base; a phone name alone
    /// stays alone (the Mirror).
    static func withPhone(_ base: String?, phone: String?) -> String? {
        guard let base = trimmed(base) else { return nil }
        guard let phone = trimmed(phone), phone != base else { return base }
        return "\(base) (\(phone))"
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
    /// The displayed picture's top band over the horizontal fractions
    /// `xFrom...xTo` of its width, `bandFraction` of its height from its top,
    /// averaged sideways over ±`blurReach` (a fraction of the picture's
    /// width) the way the bar's blur spreads it (`BandLuminance.blurredRange`).
    /// The completion runs on the main queue; nil when there is no readable
    /// frame.
    func topBandRange(xFrom: CGFloat, xTo: CGFloat, bandFraction: CGFloat, blurReach: CGFloat,
                      completion: @escaping (BandRange?) -> Void)
}

/// One frame's top-band luminance range for the tone machine (WIN-69). A
/// decoder gives back 32BGRA, a bi-planar 4:2:0 buffer or a losslessly
/// compressed buffer; the first two are read in place, the last through Core
/// Image and only for the requested rectangle.
enum BandLuminance {
    /// The darkest and brightest WCAG relative luminance of `buffer` inside
    /// `rect`, which is in pixels with the origin at the buffer's top-left.
    /// A grid of at most 32×8 samples, not a full readback. Nil for a format
    /// it cannot read, an empty rect or a missing base address.
    static func range(of buffer: CVPixelBuffer, rect: CGRect) -> BandRange? {
        guard let values = values(of: buffer, rect: rect), !values.isEmpty,
              let low = values.min(), let high = values.max() else { return nil }
        return BandRange(low: low, high: high)
    }

    /// The range the title sees on the bar's blurred mirror (#45): the band
    /// is read over `rect` widened by `reach` pixels on each side, each
    /// sampled column averaged down the band, the columns averaged over
    /// ±`reach` (in sRGB, the space the blur works in), and the darkest and
    /// brightest of those averages inside `rect` returned. A status bar's
    /// thin glyphs then lift a dark page a little instead of reading as
    /// white, while a dark or light area wider than the reach stays itself.
    /// A reach under one pixel is the raw `range`.
    static func blurredRange(of buffer: CVPixelBuffer, rect: CGRect, reach: CGFloat) -> BandRange? {
        guard reach >= 1 else { return range(of: buffer, rect: rect) }
        let bounds = CGRect(x: 0, y: 0, width: CVPixelBufferGetWidth(buffer),
                            height: CVPixelBufferGetHeight(buffer))
        let inner = rect.intersection(bounds)
        let outer = rect.insetBy(dx: -reach, dy: 0).intersection(bounds)
        guard inner.width >= 1, inner.height >= 1, outer.width >= 1 else { return nil }
        let columns = min(blurColumns, max(1, Int(outer.width)))
        guard let values = values(of: buffer, rect: outer, columns: columns),
              !values.isEmpty, values.count % columns == 0 else { return nil }
        let rows = values.count / columns
        let xs = (0..<columns).map { Int(outer.minX) + ($0 * Int(outer.width)) / columns }
        let means = (0..<columns).map { column -> Double in
            var sum = 0.0
            for row in 0..<rows { sum += BarToneEstimate.encode(values[row * columns + column]) }
            return sum / Double(rows)
        }
        var low = Double.infinity
        var high = -Double.infinity
        for column in 0..<columns where CGFloat(xs[column]) >= inner.minX && CGFloat(xs[column]) < inner.maxX {
            var sum = 0.0
            var count = 0
            for other in 0..<columns where abs(CGFloat(xs[other] - xs[column])) <= reach {
                sum += means[other]
                count += 1
            }
            let value = BarToneEstimate.decode(sum / Double(count))
            low = min(low, value)
            high = max(high, value)
        }
        guard low.isFinite, high.isFinite else { return nil }
        return BandRange(low: low, high: high)
    }

    /// Columns across the widened band for `blurredRange`: fine enough that
    /// a 1 pt glyph stroke at 2× is sampled, still a few hundred reads.
    static let blurColumns = 128

    /// The same range's mean, for callers that want one number.
    static func mean(of buffer: CVPixelBuffer, rect: CGRect) -> Double? {
        guard let values = values(of: buffer, rect: rect), !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    private static func values(of buffer: CVPixelBuffer, rect: CGRect, columns: Int = 32) -> [Double]? {
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        guard width > 0, height > 0 else { return nil }
        let clipped = rect.intersection(CGRect(x: 0, y: 0, width: width, height: height))
        guard clipped.width >= 1, clipped.height >= 1 else { return nil }
        let format = CVPixelBufferGetPixelFormatType(buffer)
        if format == kCVPixelFormatType_32BGRA {
            return directValues(buffer, rect: clipped, columns: columns) { base, stride, x, y in
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
            return grid(rect: clipped, columns: columns) { x, y in
                let raw = Double(base.load(fromByteOffset: y * stride + x, as: UInt8.self))
                let level = videoRange ? min(255, max(0, (raw - 16) * 255 / 219)) : raw
                return linear(level / 255)
            }
        }
        if format == losslessVideoRange || format == losslessFullRange {
            guard let output = renderThroughCoreImage(of: buffer, rect: clipped) else { return nil }
            return values(of: output, rect: CGRect(x: 0, y: 0, width: clipped.width, height: clipped.height),
                          columns: columns)
        }
        return nil
    }

    /// A small BGRA render of any buffer Core Image can read, for the
    /// lossless formats a display layer hands back. The buffer's rows run
    /// top-down and Core Image's coordinates bottom-up.
    static func renderThroughCoreImage(of buffer: CVPixelBuffer, rect: CGRect) -> CVPixelBuffer? {
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
        return output
    }

    /// The mean of a Core Image render, for the tests.
    static func meanThroughCoreImage(of buffer: CVPixelBuffer, rect: CGRect) -> Double? {
        guard let output = renderThroughCoreImage(of: buffer, rect: rect) else { return nil }
        return mean(of: output, rect: CGRect(x: 0, y: 0, width: rect.width, height: rect.height))
    }

    /// The lossless-compressed forms of 420v/420f a display layer hands back.
    static let losslessVideoRange: UInt32 = 0x26387630  // '&8v0'
    static let losslessFullRange: UInt32 = 0x26386630  // '&8f0'

    private static let context = CIContext(options: [.cacheIntermediates: false])

    private static func directValues(_ buffer: CVPixelBuffer, rect: CGRect, columns: Int,
                                     luma: (UnsafeRawPointer, Int, Int, Int) -> Double) -> [Double]? {
        guard CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess,
              let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        return grid(rect: rect, columns: columns) { x, y in luma(base, stride, x, y) }
    }

    /// At most `columns`×8 even samples across the rect, row-major from its
    /// top (32 columns for the raw range).
    private static func grid(rect: CGRect, columns maximum: Int, value: (Int, Int) -> Double) -> [Double] {
        let columns = min(maximum, max(1, Int(rect.width)))
        let rows = min(8, max(1, Int(rect.height)))
        var values: [Double] = []
        values.reserveCapacity(columns * rows)
        for row in 0..<rows {
            let y = Int(rect.minY) + (row * Int(rect.height)) / rows
            for column in 0..<columns {
                let x = Int(rect.minX) + (column * Int(rect.width)) / columns
                values.append(value(x, y))
            }
        }
        return values
    }

    /// sRGB → WCAG relative luminance's linear form (one channel).
    static func linear(_ value: Double) -> Double {
        value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }
}
