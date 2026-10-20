// A screenshot of a stream window (docs/design/mcp.md): the last frame the
// display layer actually showed, copied out with `copyDisplayedPixelBuffer()`.
// The helpers are separate from the layer so the automation server owns no
// decoding state of its own.

import AVFoundation
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum FrameGrab {
    /// A screenshot's longest side, in pixels.
    static let maxSide = 1280

    /// The frame the layer is displaying right now (nil before the first frame
    /// or while it has none).
    static func displayedPixelBuffer(from layer: AVSampleBufferDisplayLayer) -> CVPixelBuffer? {
        layer.sampleBufferRenderer.displayedPixelBuffer()
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
