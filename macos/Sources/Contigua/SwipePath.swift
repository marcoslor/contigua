// `swipe {direction, ref?}` as two points (docs/design/mcp.md "Input",
// MCP-90): through the centre of the ref's box, else the window's, over 60 %
// of its extent along the direction, the finger moving the named way. Pure.

import Foundation

enum SwipePath {
    /// The share of the box's extent the finger travels.
    static let extent = 0.6

    struct Line: Equatable {
        /// 0..1 of the window, the space TOUCH frames carry.
        let from: [Double]
        let to: [Double]
    }

    /// `box` is `[left, top, right, bottom]` in the display's pixels and
    /// `size` that display's `[w, h]` (ui_tree's `box` and `size`); nil `box`
    /// (or no `size` to place it in) is the whole window.
    static func line(direction: MCPSwipeDirection, box: [Int]?, size: [Int]?) -> Line {
        var rect = (left: 0.0, top: 0.0, right: 1.0, bottom: 1.0)
        if let box, box.count == 4, let size, size.count == 2, size[0] > 0, size[1] > 0 {
            let w = Double(size[0]), h = Double(size[1])
            rect = (Double(box[0]) / w, Double(box[1]) / h, Double(box[2]) / w, Double(box[3]) / h)
        }
        let cx = (rect.left + rect.right) / 2
        let cy = (rect.top + rect.bottom) / 2
        let dx = (rect.right - rect.left) * extent / 2
        let dy = (rect.bottom - rect.top) * extent / 2
        func clamp(_ v: Double) -> Double { min(1, max(0, v)) }
        let (from, to): ((Double, Double), (Double, Double))
        switch direction {
        case .up: (from, to) = ((cx, cy + dy), (cx, cy - dy))
        case .down: (from, to) = ((cx, cy - dy), (cx, cy + dy))
        case .left: (from, to) = ((cx + dx, cy), (cx - dx, cy))
        case .right: (from, to) = ((cx - dx, cy), (cx + dx, cy))
        }
        return Line(from: [clamp(from.0), clamp(from.1)], to: [clamp(to.0), clamp(to.1)])
    }
}
