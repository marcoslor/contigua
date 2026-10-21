// View ▸ Bar Prototype (2026-10-21, temporary): the two bar proportions the
// person is choosing between. The item is removed once they pick.
//
// Compact (iTerm2's compact mode): the 14 pt traffic lights sit 7 pt in from
// the left, the top and the bottom, so the bar is 28 pt; the Live Text button
// mirrors them 7 pt in from the right on the same centre line.
//
// Standard (Finder's proportions, measured on macOS 26 this Mac: the traffic
// lights are 16 pt, 18 pt in from the left and the top, 23 pt apart, in a
// 52 pt titlebar). The Live Text button is 28 pt, 18 pt in from the right and
// centred on the lights' line.
//
// The framed bar and the immersive pill both follow the current one; the
// window's stream keeps its size and the bar grows upward.

import AppKit

enum BarPrototype: String, CaseIterable, Identifiable {
    case compact
    case standard

    static let key = "bar.prototype"

    /// The prototype every layout reads. Set from the profile at launch and by
    /// View ▸ Bar Prototype; tests set it and restore it.
    static var current: BarPrototype = .compact

    var id: String { rawValue }

    var label: String {
        switch self {
        case .compact: return "Compact"
        case .standard: return "Standard"
        }
    }

    /// The traffic lights' square side.
    var lightSide: CGFloat {
        switch self {
        case .compact: return 14
        case .standard: return 16
        }
    }

    /// Their distance from the window's left edge, and from the bar's top and
    /// bottom edges: equal, by definition of both prototypes.
    var lightInset: CGFloat {
        switch self {
        case .compact: return 7
        case .standard: return 18
        }
    }

    /// Finder's measured spacing (the same in both).
    var lightSpacing: CGFloat { 23 }

    /// The bar: the lights plus the inset above and below.
    var barHeight: CGFloat { lightInset * 2 + lightSide }

    /// The Live Text button's side (the round control), and its right inset:
    /// the lights' left inset, mirrored.
    var liveTextSide: CGFloat { 28 }
    var rightInset: CGFloat { lightInset }

    static func stored(in defaults: UserDefaults) -> BarPrototype {
        guard let raw = defaults.string(forKey: key), let value = BarPrototype(rawValue: raw) else {
            return .compact
        }
        return value
    }
}
