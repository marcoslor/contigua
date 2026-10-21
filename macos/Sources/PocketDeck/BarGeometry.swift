// The framed bar's proportions, shared with the immersive pill.
//
// The 14 pt traffic lights sit 7 pt in from the left, the top and the bottom,
// so the bar is 28 pt; the Live Text button mirrors them 7 pt in from the
// right on the same centre line. The stream keeps its size and the bar grows
// upward.

import AppKit

enum BarGeometry {
    /// The traffic lights' square side.
    static let lightSide: CGFloat = 14
    /// Their distance from the window's left edge, and from the bar's top and
    /// bottom edges: equal, by definition of the bar.
    static let lightInset: CGFloat = 7
    /// The system's spacing between the lights.
    static let lightSpacing: CGFloat = 23
    /// The bar: the lights plus the inset above and below.
    static let barHeight: CGFloat = lightInset * 2 + lightSide
    /// The Live Text button's side (the round control), and its right inset:
    /// the lights' left inset, mirrored.
    static let liveTextSide: CGFloat = 28
    static let rightInset: CGFloat = lightInset
}
