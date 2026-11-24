// MCP-100/MCP-101: an agent's new window takes the phone's shape.
//
// Pure: the phone's screen (`welcome.device.screen`), the encoder's alignment
// and limits, the visible frame and the style's chrome → the stream's pixels,
// its dpi and the window's stream area in points. The hand-back is one flag,
// `AgentShapeHold`, that only the person's resize or density change clears.

import CoreGraphics
import Foundation

/// MCP-100: `shape` on `open_app` and `send_link`.
enum MCPWindowShape: String, CaseIterable, Equatable {
    /// The phone's portrait shape at its own dp width (the default).
    case phone
    /// A person's window: WIN-5 and WIN-13, today's 900×600 pt.
    case window
}

/// The size a phone-shape window asks for and shows.
struct AgentWindowShape: Equatable {
    /// The stream's pixels (`window.open`'s `w`, `h`).
    var pixels: CGSize
    /// `round(160 × streamWidth ÷ phoneDpWidth)`: the app lays out at the
    /// phone's own dp width.
    var dpi: Int
    /// The window's stream area: the phone's dp size in points, shrunk with
    /// the aspect kept to fit the visible frame with the style's chrome.
    var points: CGSize

    /// The long side's cap (MCP-100, CONV-PD-06).
    static let maxLongSide = 1280.0

    /// nil when the phone reported no screen (no shape to take).
    static func make(screenWidth: Int, screenHeight: Int, screenDpi: Int, encoder: EncoderSpec?,
                     visible: CGSize, chrome: CGSize) -> AgentWindowShape? {
        guard screenWidth > 0, screenHeight > 0, screenDpi > 0 else { return nil }
        // A landscape report is turned portrait: the short side is the width.
        let short = Double(min(screenWidth, screenHeight))
        let long = Double(max(screenWidth, screenHeight))
        let dpWidth = short * 160 / Double(screenDpi)
        let dpHeight = long * 160 / Double(screenDpi)

        // Pixels: the phone's aspect, its long side at most 1280 (never above
        // the phone's own), then the encoder's alignment and limits as WIN-5.
        let scale = min(1, maxLongSide / long)
        var width = short * scale
        var height = long * scale
        let wAlign = Double(max(1, encoder?.widthAlign ?? VideoSize.granularity))
        let hAlign = Double(max(1, encoder?.heightAlign ?? VideoSize.granularity))
        if let encoder {
            var factor = min(1, Double(encoder.maxWidth) / width, Double(encoder.maxHeight) / height)
            if encoder.maxPixelsAt60 > 0 {
                factor = min(factor, (Double(encoder.maxPixelsAt60) / (width * height)).squareRoot())
            }
            width *= factor
            height *= factor
        }
        width = max((width / wAlign).rounded(.down) * wAlign, Double(VideoSize.minDimension))
        height = max((height / hAlign).rounded(.down) * hAlign, Double(VideoSize.minDimension))
        let dpi = Int((160 * width / dpWidth).rounded())

        // Points: 1 pt per dp, shrunk to fit the visible frame with chrome.
        var points = CGSize(width: dpWidth, height: dpHeight)
        let roomW = Double(visible.width - chrome.width)
        let roomH = Double(visible.height - chrome.height)
        if roomW > 0, roomH > 0 {
            let fit = min(1, roomW / dpWidth, roomH / dpHeight)
            points = CGSize(width: (dpWidth * fit).rounded(), height: (dpHeight * fit).rounded())
        }
        return AgentWindowShape(pixels: CGSize(width: width, height: height), dpi: dpi, points: points)
    }
}

/// MCP-101: the hand-back flag as a machine. A phone-shape window is `.phone`
/// until the person resizes it (a drag, Zoom, tiling, full screen) or changes
/// its density; from then on it is `.ordinary` and never returns.
enum AgentShapeHold: Equatable {
    case phone
    case ordinary

    enum Event: CaseIterable {
        case personResize, zoom, tile, fullScreen, densityChange
        case move, raise
    }

    enum Action: Equatable {
        /// Become a person's window: WIN-5/6/13 apply, a resize at WIN-5's size.
        case handBack
    }

    static func step(_ state: AgentShapeHold, _ event: Event) -> (AgentShapeHold, [Action]) {
        switch (state, event) {
        case (.phone, .personResize), (.phone, .zoom), (.phone, .tile), (.phone, .fullScreen),
             (.phone, .densityChange):
            return (.ordinary, [.handBack])
        case (.phone, .move), (.phone, .raise):
            return (.phone, [])
        case (.ordinary, _):
            return (.ordinary, [])
        }
    }
}
