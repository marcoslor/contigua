// A screenshot of a stream window (docs/design/mcp.md): the last frame the
// display layer actually showed, copied out with `copyDisplayedPixelBuffer()`.
// The helpers are separate from the layer so the automation server owns no
// decoding state of its own.

import AVFoundation
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers
import VideoToolbox

enum FrameGrab {
    /// A screenshot's longest side, in pixels.
    static let maxSide = 1280

    /// The frame the layer is displaying right now (nil before the first frame
    /// or while it has none). The renderer only copies while its timebase is
    /// stopped; the rate is parked for the copy and put back at once.
    static func displayedPixelBuffer(from layer: AVSampleBufferDisplayLayer) -> CVPixelBuffer? {
        let renderer = layer.sampleBufferRenderer
        let timebase = renderer.timebase
        let rate = CMTimebaseGetRate(timebase)
        if rate != 0 { CMTimebaseSetRate(timebase, rate: 0) }
        defer { if rate != 0 { CMTimebaseSetRate(timebase, rate: rate) } }
        return renderer.displayedPixelBuffer()
    }

    /// PNG bytes from one compressed access unit (the fallback for a window
    /// whose layer reports no displayed buffer, e.g. a quiet e2e run). A
    /// keyframe decodes on its own; callers ask the phone for one.
    static func png(fromSample sample: CMSampleBuffer, maxSide: Int = FrameGrab.maxSide) -> Data? {
        guard let pixels = decode(sample) else { return nil }
        return png(from: pixels, maxSide: maxSide)
    }

    /// One keyframe -> one BGRA pixel buffer.
    static func decode(_ sample: CMSampleBuffer) -> CVPixelBuffer? {
        guard let format = CMSampleBufferGetFormatDescription(sample) else { return nil }
        var session: VTDecompressionSession?
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any],
        ]
        let created = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault, formatDescription: format,
            decoderSpecification: nil, imageBufferAttributes: attributes as CFDictionary,
            outputCallback: nil, decompressionSessionOut: &session)
        guard created == noErr, let session else { return nil }
        defer { VTDecompressionSessionInvalidate(session) }

        final class Output: @unchecked Sendable {
            var buffer: CVImageBuffer?
            var status: OSStatus = -1
        }
        let output = Output()
        var flags = VTDecodeFrameFlags._EnableAsynchronousDecompression
        var info = VTDecodeInfoFlags()
        let decoded = VTDecompressionSessionDecodeFrame(
            session, sampleBuffer: sample, flags: flags, infoFlagsOut: &info
        ) { status, _, imageBuffer, _, _ in
            output.status = status
            output.buffer = imageBuffer
        }
        guard decoded == noErr else { return nil }
        VTDecompressionSessionWaitForAsynchronousFrames(session)
        guard output.status == noErr, let imageBuffer = output.buffer else { return nil }
        return imageBuffer as CVPixelBuffer
    }

    /// PNG bytes, scaled down so the longest side is at most `maxSide`.
    static func png(from pixelBuffer: CVPixelBuffer, maxSide: Int = FrameGrab.maxSide) -> Data? {
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        let width = image.extent.width
        let height = image.extent.height
        guard width >= 1, height >= 1 else { return nil }
        let scale = min(1, CGFloat(maxSide) / max(width, height))
        let targetWidth = max(1, (width * scale).rounded(.down))
        let targetHeight = max(1, (height * scale).rounded(.down))
        let scaled = scale < 1
            ? image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            : image
        let rect = CGRect(x: scaled.extent.minX, y: scaled.extent.minY,
                          width: targetWidth, height: targetHeight)
        guard let cgImage = FrameGrab.context.createCGImage(scaled, from: rect) else { return nil }
        guard let data = CFDataCreateMutable(nil, 0),
              let destination = CGImageDestinationCreateWithData(
                  data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, cgImage, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    /// One shared context: CIContext is expensive and thread-safe.
    private static let context = CIContext(options: [.cacheIntermediates: false])
}
