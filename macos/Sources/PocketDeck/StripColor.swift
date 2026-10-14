// The colour of the title strip: the average colour of the top rows of the
// frame on screen, sampled a few times a second, never per frame.
//
// A mirrored copy of the video's edge would run in step with the video; one
// colour does not need to. `AVSampleBufferVideoRenderer` hands out the pixel
// buffer it is showing, Core Image averages its top rows on the GPU into one
// pixel, and the strip eases to that colour. The luminance of the colour picks
// the titlebar's appearance so the title stays legible.

import AVFoundation
import CoreImage
import SwiftUI

struct StripColor: Equatable {
    /// sRGB, 0...1.
    var red: Double
    var green: Double
    var blue: Double

    /// What the strip shows before the first frame: the video view's own black.
    static let black = StripColor(red: 0, green: 0, blue: 0)

    /// Relative luminance (Rec. 709 weights on linearised sRGB), 0 black ... 1 white.
    var luminance: Double {
        0.2126 * Self.linear(red) + 0.7152 * Self.linear(green) + 0.0722 * Self.linear(blue)
    }

    var color: Color { Color(.sRGB, red: red, green: green, blue: blue) }

    /// The strip eases to a new colour over this long.
    static let easeDuration = 0.25

    /// A change smaller than this (per channel, 0...1) is not worth an animation.
    static let noticeableChange = 2.0 / 255

    func isNoticeablyDifferent(from other: StripColor) -> Bool {
        max(abs(red - other.red), abs(green - other.green), abs(blue - other.blue)) > Self.noticeableChange
    }

    /// White and black text have the same contrast on a colour of luminance
    /// ~0.179; lighter colours take dark text, darker ones light text.
    static let crossover = 0.179
    /// Where the answer flips back, so a colour on the line does not flicker.
    static let hysteresis = 0.03

    /// True when the titlebar should use the light appearance (dark title text).
    /// `wasLight` is the previous answer, nil the first time.
    func prefersLightAppearance(wasLight: Bool?) -> Bool {
        switch wasLight {
        case true?: return luminance > Self.crossover - Self.hysteresis
        case false?: return luminance > Self.crossover + Self.hysteresis
        case nil: return luminance > Self.crossover
        }
    }

    private static func linear(_ value: Double) -> Double {
        value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }
}

enum TopEdge {
    /// How many rows of the frame (from its top) are averaged.
    static let rows = 8

    /// The average colour of the top rows of `buffer`, or nil when Core Image
    /// cannot read it.
    static func averageColor(of buffer: CVPixelBuffer, using context: CIContext) -> StripColor? {
        let image = CIImage(cvPixelBuffer: buffer)
        let extent = image.extent
        guard extent.width >= 1, extent.height >= 1 else { return nil }
        // Core Image's origin is bottom-left: the frame's top is its highest rows.
        let height = min(CGFloat(rows), extent.height)
        let band = CGRect(x: extent.minX, y: extent.maxY - height, width: extent.width, height: height)
        guard let filter = CIFilter(name: "CIAreaAverage", parameters: [
            kCIInputImageKey: image,
            kCIInputExtentKey: CIVector(cgRect: band),
        ]), let output = filter.outputImage else { return nil }
        var pixel = [UInt8](repeating: 0, count: 4)
        context.render(output, toBitmap: &pixel, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                       format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        return StripColor(red: Double(pixel[0]) / 255, green: Double(pixel[1]) / 255, blue: Double(pixel[2]) / 255)
    }
}

/// Samples a video's top edge on a timer. Four times a second is as often as
/// anyone can follow a colour change; the work is one GPU average of 8 rows.
/// The buffer is taken on the main thread (the display layer lives there) and
/// averaged on a queue of its own: Core Image's first render compiles its
/// kernels, long enough to stall input if it ran on the main thread.
final class StripColorSampler {
    static let interval: TimeInterval = 0.25

    private let source: () -> CVPixelBuffer?
    private let onColor: (StripColor) -> Void
    private let context = CIContext()
    private let queue = DispatchQueue(label: "dev.pocketdeck.strip-color", qos: .utility)
    private var timer: Timer?
    /// A sample is in flight; the next tick is skipped rather than queued.
    private var busy = false

    init(source: @escaping () -> CVPixelBuffer?, onColor: @escaping (StripColor) -> Void) {
        self.source = source
        self.onColor = onColor
    }

    deinit { timer?.invalidate() }

    var isRunning: Bool { timer != nil }

    func start() {
        guard timer == nil else { return }
        sampleNow()
        let timer = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in self?.sampleNow() }
        timer.tolerance = Self.interval / 2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func sampleNow() {
        guard !busy, let buffer = source() else { return }
        busy = true
        let context = context
        queue.async { [weak self] in
            let color = TopEdge.averageColor(of: buffer, using: context)
            DispatchQueue.main.async {
                guard let self else { return }
                self.busy = false
                if let color { self.onColor(color) }
            }
        }
    }
}
