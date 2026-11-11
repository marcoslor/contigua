// The rail's vertical layout (docs/specs/deck.md DECK-7): at rest every letter
// takes an 11 pt box with an equal gap; a magnified box is 11 pt times its
// scale and the gaps stay as they are, so the ends extend and the letter under
// the pointer stays under it. The span is computed once, on enter, and then
// frozen: inside it the gaps are equal and the fisheye's centre is solved from
// the drawn y, so the ends never move while the pointer sweeps.

import Foundation

enum RailLayout {
    /// One drawn slot, in the rail's own coordinate space (its top-left is 0,0).
    struct Slot: Equatable {
        var y: CGFloat
        var height: CGFloat
    }

    /// A frozen span in the rail's own space: the drawn top of the first slot
    /// and the length the slots fill. It is computed once, on enter, so the
    /// ends (A's top, #'s bottom) never move while the pointer is inside.
    struct Span: Equatable {
        var top: CGFloat
        var length: CGFloat
        var bottom: CGFloat { top + length }
    }

    /// The widest rest pitch and the one below which the rail condenses.
    static let maximumPitch: CGFloat = 20
    static let minimumPitch: CGFloat = 18
    /// A hair of headroom: the end extension is sampled, and the fit must hold
    /// for every pointer position between the samples too.
    private static let extensionMargin: CGFloat = 0.15

    /// The 9 pt letter's drawn line box at rest (`h`): a magnified letter's box
    /// is `letterBox x scale`, and the gap `g = pitch - letterBox` between
    /// boxes never grows.
    static let letterBox: CGFloat = 11

    /// The slots to draw. `scales` is one scale per rail slot (1 at rest),
    /// `pitch` the rest pitch, and `anchor` the pointer's y on enter. The
    /// anchor slot is placed so the pointer keeps its fraction of it, which
    /// keeps the letter under the pointer under it while the boxes open; the
    /// growth above the pointer pushes the top end up, the growth below pushes
    /// the bottom end down.
    static func slots(scales: [CGFloat], pitch: CGFloat, anchor: CGFloat?) -> [Slot] {
        let count = scales.count
        guard count > 0, pitch > 0 else { return [] }
        let box = min(letterBox, pitch)
        let gap = pitch - box
        let heights = scales.map { box * max($0, 0.5) + gap }
        let restHeight = CGFloat(count) * pitch
        let pointer = min(max(anchor ?? restHeight / 2, 0), restHeight - 0.001)
        let index = min(count - 1, max(0, Int(pointer / pitch)))
        let fraction = min(max((pointer - CGFloat(index) * pitch) / pitch, 0), 0.9999)
        var origin = pointer - fraction * heights[index]
        for i in 0..<index { origin -= heights[i] }
        var y = origin
        return heights.map { height in
            defer { y += height }
            return Slot(y: y, height: height)
        }
    }

    /// The layout's worst reach past the rest top or bottom (in points at full
    /// magnification) over every pointer y: the growth above the pointer moves
    /// the top end up, the growth below moves the bottom down. The rest pitch
    /// only changes the gap, so this depends on the count alone, and the three
    /// counts the Deck draws are tabulated once: the fit runs on every point of
    /// a resize, and the sampling costs a few hundred thousand glyphs.
    static func endExtension(count: Int) -> CGFloat {
        extensions[count] ?? sampledExtension(count: count)
    }

    /// The counts the Deck draws (27, 14 and 9 slots), computed on first use.
    private static let extensions: [Int: CGFloat] = {
        let counts = [DeckRail.letters.count,
                      (DeckRail.letters.count + 1) / 2,
                      (DeckRail.letters.count + 2) / 3]
        return Dictionary(uniqueKeysWithValues: counts.map { ($0, sampledExtension(count: $0)) })
    }()

    private static func sampledExtension(count: Int) -> CGFloat {
        guard count > 0 else { return 0 }
        var worst: CGFloat = 0
        var sample = 0
        while sample <= count * 64 {
            let y = CGFloat(sample) / 64
            let index = min(count - 1, max(0, Int(y)))
            let fraction = min(max(y - CGFloat(index), 0), 0.9999)
            var above = fraction * (RailFisheye.scale(distance: y - (CGFloat(index) + 0.5),
                                                     reduceMotion: false) - 1)
            var below = (1 - fraction) * (RailFisheye.scale(distance: y - (CGFloat(index) + 0.5),
                                                           reduceMotion: false) - 1)
            for i in 0..<index {
                above += RailFisheye.scale(distance: y - (CGFloat(i) + 0.5),
                                           reduceMotion: false) - 1
            }
            for i in (index + 1)..<count {
                below += RailFisheye.scale(distance: y - (CGFloat(i) + 0.5),
                                           reduceMotion: false) - 1
            }
            worst = max(worst, above, below)
            sample += 1
        }
        return letterBox * worst + extensionMargin
    }

    /// The rest pitch for `count` letters in `content` points: the natural
    /// layout plus its worst end extension fits, at most 20 pt.
    static func restPitch(count: Int, content: CGFloat) -> CGFloat {
        guard count > 0, content > 0 else { return 0 }
        let room = (content - 2 * endExtension(count: count)) / CGFloat(count)
        return max(0, min(maximumPitch, room))
    }

    /// The rail to draw in `content` points of height: the most letters whose
    /// rest pitch can stay at 18 pt or more with room for the magnified end
    /// extension. nil when even every third letter would not fit, which hides
    /// the rail.
    static func fit(content: CGFloat) -> (count: Int, pitch: CGFloat)? {
        guard content > 0 else { return nil }
        for stride in 1...3 {
            let count = (DeckRail.letters.count + stride - 1) / stride
            guard count >= 8 else { continue }
            let pitch = restPitch(count: count, content: content)
            guard pitch >= minimumPitch else { continue }
            return (count, pitch)
        }
        return nil
    }

    /// The fisheye's scales for a centre `u` in index units, vertical only:
    /// the scale never depends on x.
    static func scales(count: Int, centre u: CGFloat, reduceMotion: Bool) -> [CGFloat] {
        guard count > 0 else { return [] }
        return (0..<count).map {
            RailFisheye.scale(distance: u - (CGFloat($0) + 0.5), reduceMotion: reduceMotion)
        }
    }

    /// The span the layout opens to when the pointer enters at `anchor`: the
    /// drawn ends of the unfrozen layout at that y. At `anchor` this is exactly
    /// the layout drawn before the enter, so entering does not jump.
    static func span(count: Int, pitch: CGFloat, anchor: CGFloat,
                     reduceMotion: Bool = false) -> Span {
        guard count > 0, pitch > 0 else { return Span(top: 0, length: 0) }
        let scales = scales(count: count, centre: anchor / pitch, reduceMotion: reduceMotion)
        let layout = slots(scales: scales, pitch: pitch, anchor: anchor)
        guard let first = layout.first, let last = layout.last else {
            return Span(top: 0, length: 0)
        }
        return Span(top: first.y, length: last.y + last.height - first.y)
    }

    /// The equal gap between the drawn boxes inside a frozen span:
    /// `g' = (L - h x sum(s)) / count`, so the slots fill exactly `length`.
    static func frozenGap(scales: [CGFloat], span: Span) -> CGFloat {
        let count = scales.count
        guard count > 0 else { return 0 }
        return (span.length - letterBox * scales.reduce(0, +)) / CGFloat(count)
    }

    /// The slots inside a frozen span: equal gaps, the boxes `letterBox x
    /// scale`, from `span.top`. The span's ends do not depend on the centre.
    static func frozenSlots(scales: [CGFloat], span: Span) -> [Slot] {
        guard !scales.isEmpty else { return [] }
        let gap = frozenGap(scales: scales, span: span)
        var y = span.top
        return scales.map { scale in
            let height = letterBox * scale + gap
            defer { y += height }
            return Slot(y: y, height: height)
        }
    }

    /// The drawn y of the fisheye centre `u` (slot floor(u), fraction frac(u)).
    /// Strictly increasing in `u`, which is what makes the bisection sound.
    static func frozenCentreY(_ u: CGFloat, span: Span, count: Int) -> CGFloat {
        guard count > 0 else { return span.top }
        let centre = min(max(u, 0), CGFloat(count))
        let index = min(count - 1, max(0, Int(centre)))
        let fraction = min(max(centre - CGFloat(index), 0), 1)
        let scales = scales(count: count, centre: centre, reduceMotion: false)
        let gap = frozenGap(scales: scales, span: span)
        var y = span.top
        for i in 0..<index {
            y += letterBox * scales[i] + gap
        }
        return y + fraction * (letterBox * scales[index] + gap)
    }

    /// The fisheye centre whose drawn y is `y`: solve `Y(u) = y` by bisection,
    /// so the drawn slot under the pointer is always the fisheye's centre.
    /// Clamped to the span's ends (the pointer may be outside the rail's rest
    /// rows while inside the frozen span).
    static func frozenCentre(atY y: CGFloat, span: Span, count: Int) -> CGFloat {
        guard count > 0, span.length > 0 else { return 0 }
        if y <= frozenCentreY(0, span: span, count: count) { return 0 }
        if y >= frozenCentreY(CGFloat(count), span: span, count: count) { return CGFloat(count) }
        var low: CGFloat = 0
        var high = CGFloat(count)
        // 20 halvings leave the drawn y within 0.001 pt of `y`.
        for _ in 0..<20 {
            let mid = (low + high) / 2
            if frozenCentreY(mid, span: span, count: count) < y {
                low = mid
            } else {
                high = mid
            }
        }
        return (low + high) / 2
    }

    /// The slot drawn at `y`: hit-testing follows the drawn layout, so a click
    /// somewhere the rail has moved still picks what is under it.
    static func slotIndex(atY y: CGFloat, in layout: [Slot]) -> Int? {
        guard !layout.isEmpty else { return nil }
        if y < layout[0].y { return 0 }
        for (index, slot) in layout.enumerated() where y < slot.y + slot.height {
            return index
        }
        return layout.count - 1
    }

    /// The letter drawn at `y`: within a condensed slot the letters split its
    /// height evenly, so even a moved slot picks the letter the person sees.
    static func letter(atY y: CGFloat, in layout: [Slot], slots: [DeckRail.Slot]) -> String? {
        guard let index = slotIndex(atY: y, in: layout), slots.indices.contains(index) else {
            return nil
        }
        let slot = slots[index]
        let height = layout[index].height
        guard height > 0 else { return DeckRail.letters[slot.first] }
        let within = min(max((y - layout[index].y) / height, 0), 0.999_999)
        let band = min(slot.count - 1, max(0, Int(within * CGFloat(slot.count))))
        return DeckRail.letters[slot.first + band]
    }
}

/// The rail's hit column (DECK-34): the letters' drawn column widened by at
/// most 4 pt each side. The rail's frame is wider than its letters, and the
/// strip right of the letters is the grid's, not the rail's.
enum RailHit {
    static let sidePadding: CGFloat = 4

    /// The letters' drawn column at rest: the 11 pt letter box centred in the
    /// rail's column.
    static func letters(railWidth: CGFloat = DeckWide.railWidth) -> ClosedRange<CGFloat> {
        let box = min(RailLayout.letterBox, railWidth)
        let left = (railWidth - box) / 2
        return left...(left + box)
    }

    /// The column the pointer may take. Today the rail's whole frame, plus the
    /// magnified arc's room on the left.
    static func column(railWidth: CGFloat = DeckWide.railWidth,
                       magnified: CGFloat = 0) -> ClosedRange<CGFloat> {
        (magnified > 0 ? -magnified : 0)...railWidth
    }

    /// The vertical span the pointer may take: today the rail's whole height.
    static func vertical(railHeight: CGFloat) -> ClosedRange<CGFloat> {
        0...railHeight
    }

    static func contains(x: CGFloat, y: CGFloat, railWidth: CGFloat,
                         railHeight: CGFloat, magnified: CGFloat) -> Bool {
        column(railWidth: railWidth, magnified: magnified).contains(x)
            && vertical(railHeight: railHeight).contains(y)
    }
}
