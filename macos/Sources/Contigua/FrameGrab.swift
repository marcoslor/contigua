// A screenshot of a stream window as PNG (docs/design/mcp.md). The frame
// itself comes from VideoLayerView, by the same route Live Text freezes on;
// this only crops, scales and encodes it.

import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum FrameGrab {
    /// A screenshot's longest side, in pixels.
    static let maxSide = 1280

    /// The PNG's pixel size for a frame of `sourceWidth`×`sourceHeight`, cropped
    /// to `crop` (top-left `[l, t, r, b]` in source pixels) before scaling.
    static func scaledSize(sourceWidth: Int, sourceHeight: Int, crop: [Int]? = nil,
                           maxSide: Int = FrameGrab.maxSide) -> (Int, Int) {
        let l = crop?[0] ?? 0
        let t = crop?[1] ?? 0
        let r = crop?[2] ?? sourceWidth
        let b = crop?[3] ?? sourceHeight
        let width = max(1, r - l)
        let height = max(1, b - t)
        let scale = min(1, CGFloat(maxSide) / CGFloat(max(width, height)))
        return (max(1, Int((CGFloat(width) * scale).rounded(.down))),
                max(1, Int((CGFloat(height) * scale).rounded(.down))))
    }

    /// PNG bytes, cropped to `crop` (top-left `[l, t, r, b]` in source pixels)
    /// and scaled down so the longest side is at most `maxSide`.
    static func png(from pixelBuffer: CVPixelBuffer, crop: [Int]? = nil,
                    maxSide: Int = FrameGrab.maxSide) -> Data? {
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        let width = Int(image.extent.width)
        let height = Int(image.extent.height)
        guard width >= 1, height >= 1 else { return nil }
        var cropped = image
        if let crop, crop.count == 4 {
            // CIImage's origin is bottom-left; the box is top-left screen pixels.
            let l = CGFloat(crop[0]), t = CGFloat(crop[1]), r = CGFloat(crop[2]), b = CGFloat(crop[3])
            let rect = CGRect(x: l, y: CGFloat(height) - b, width: r - l, height: b - t)
                .intersection(CGRect(x: 0, y: 0, width: width, height: height))
            guard !rect.isEmpty else { return nil }
            cropped = image.cropped(to: rect)
        }
        let cw = cropped.extent.width
        let ch = cropped.extent.height
        let scale = min(1, CGFloat(maxSide) / max(cw, ch))
        let targetWidth = max(1, (cw * scale).rounded(.down))
        let targetHeight = max(1, (ch * scale).rounded(.down))
        let scaled = scale < 1
            ? cropped.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            : cropped
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
