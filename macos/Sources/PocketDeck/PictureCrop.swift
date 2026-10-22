// Where a mirror's picture sits in its encoded frame, and the layer that shows only that picture.
// The phone's frame can carry a black band beyond the picture (its encoder size and the screen's
// aspect differ); window.content says where the picture is, and the Mac crops to it.

import CoreGraphics

/// window.content: the picture's rect in the frame, in frame pixels with a top-left origin.
struct PictureRect: Equatable {
    var x: Int
    var y: Int
    var w: Int
    var h: Int

    /// The whole frame: an app window's stream, and a mirror with no band.
    static func full(width: Int, height: Int) -> PictureRect {
        PictureRect(x: 0, y: 0, w: width, h: height)
    }

    var size: CGSize { CGSize(width: w, height: h) }
}

enum PictureCrop {
    /// The display layer's frame inside a clip that is exactly the drawn picture: the whole frame,
    /// scaled so the picture's rect fills the clip. The layer draws the frame into this rect, so
    /// whatever lies outside the picture is clipped away.
    static func layerFrame(frame: CGSize, content: PictureRect, picture: CGSize) -> CGRect {
        guard content.w > 0, content.h > 0 else { return CGRect(origin: .zero, size: picture) }
        let kx = picture.width / CGFloat(content.w)
        let ky = picture.height / CGFloat(content.h)
        // Frame rows count down from the top; the layer's origin is its bottom edge.
        return CGRect(x: -CGFloat(content.x) * kx,
                      y: -(frame.height - CGFloat(content.y + content.h)) * ky,
                      width: frame.width * kx,
                      height: frame.height * ky)
    }
}
