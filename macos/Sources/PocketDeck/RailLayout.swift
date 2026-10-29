// The rail's spacing (docs/specs/deck.md DECK-7): the slots are proportional to
// the letters' scales and the rail's height stays fixed, so the letters beyond
// the fisheye's reach shrink to pay for the magnified ones (the person's S2).
// The rest pitch also gives way, down to 18 pt, so the anchored layout's
// overshoot at full magnification always fits inside the content inset.

import Foundation

enum RailLayout {
    /// One drawn slot, in the rail's own coordinate space (its top-left is 0,0).
    struct Slot: Equatable {
        var y: CGFloat
        var height: CGFloat
    }

    /// The widest rest pitch and the one below which the rail condenses.
    static let maximumPitch: CGFloat = 20
    static let minimumPitch: CGFloat = 18
    /// A hair of headroom: the overshoot is sampled, and the fit must hold for
    /// every pointer position between the samples too.
    private static let overshootMargin: CGFloat = 0.15

    /// The slots to draw. `scales` is one scale per rail slot (1 at rest),
    /// `available` the rail's height (the slots always sum to it), `pitch` the
    /// rest pitch they are anchored in, and `anchor` the pointer's y. The
    /// anchor slot is placed so the pointer keeps its fraction of it, which
    /// keeps the letter under the pointer under it while the slots open.
    static func slots(scales: [CGFloat], available: CGFloat, pitch: CGFloat,
                      anchor: CGFloat?) -> [Slot] {
        let count = scales.count
        guard count > 0, available > 0, pitch > 0 else { return [] }
        let total = scales.reduce(0, +)
        guard total > 0 else {
            return (0..<count).map { Slot(y: CGFloat($0) * pitch, height: pitch) }
        }
        let heights = scales.map { available * $0 / total }
        let pointer = min(max(anchor ?? available / 2, 0), available - 0.001)
        let index = min(count - 1, max(0, Int(pointer / pitch)))
        let fraction = min(max((pointer - CGFloat(index) * pitch) / pitch, 0), 0.9999)
        var prefix: [CGFloat] = []
        var sum: CGFloat = 0
        for height in heights {
            prefix.append(sum)
            sum += height
        }
        let origin = pointer - fraction * heights[index] - prefix[index]
        return heights.enumerated().map { Slot(y: origin + prefix[$0.offset], height: $0.element) }
    }

    /// The rail to draw in `content` points of height: the most letters whose
    /// rest pitch can stay at 18 pt or more with room for the magnified
    /// overshoot. nil when even every third letter would not fit, which hides
    /// the rail (today's rule).
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

    /// The rest pitch for `count` letters in `content` points: the largest
    /// value at most 20 whose rail plus its worst magnified overshoot fits.
    /// Down to 0 when nothing fits; `fit` condenses below 18.
    static func restPitch(count: Int, content: CGFloat) -> CGFloat {
        guard count > 0, content > 0 else { return 0 }
        func fits(_ pitch: CGFloat) -> Bool {
            CGFloat(count) * pitch + 2 * overshoot(count: count, pitch: pitch) <= content + 0.001
        }
        var pitch = maximumPitch
        for _ in 0..<3 {
            let need = (content - 2 * overshoot(count: count, pitch: pitch)) / CGFloat(count)
            if need >= maximumPitch { return maximumPitch }
            pitch = max(0, need)
        }
        var candidate = min(maximumPitch, pitch)
        while candidate > 0 && !fits(candidate) { candidate -= 0.05 }
        return max(0, candidate)
    }

    /// How far the drawn glyphs can reach past the rail's ends (in points) at
    /// full magnification (dx 0), over every pointer y. The layout is
    /// scale-invariant in the pitch except for the fixed 9 pt glyph, so the
    /// shape is tabulated once per letter count and evaluated per pitch.
    static func overshoot(count: Int, pitch: CGFloat) -> CGFloat {
        let total = CGFloat(count) * pitch
        guard count > 0, pitch > 0, total > 0 else { return 0 }
        return shape(for: count).overshoot(total: total) + overshootMargin
    }

    /// One count's layout shape: for every sampled pointer position (in
    /// letters), each slot's glyph top and bottom as affine functions of the
    /// rail's height. Built once per count.
    private struct Shape {
        /// Per sample and slot: the glyph top's fraction of the rail, and the
        /// slot's scale.
        var slopes: [CGFloat] = []
        var scales: [CGFloat] = []

        init(count: Int) {
            let samples = count * 32
            slopes.reserveCapacity(samples * count)
            scales.reserveCapacity(samples * count)
            for sample in 0...samples {
                let y = CGFloat(sample) / 32
                let scale = (0..<count).map {
                    RailFisheye.scale(distance: y - (CGFloat($0) + 0.5), reduceMotion: false)
                }
                let sum = scale.reduce(0, +)
                let relative = scale.map { $0 / sum }
                let index = min(count - 1, max(0, Int(y)))
                let fraction = min(max(y - CGFloat(index), 0), 0.9999)
                var prefix: CGFloat = 0
                for i in 0..<index { prefix += relative[i] }
                // The anchor keeps the pointer at `fraction` of its slot.
                let origin = y / CGFloat(count) - fraction * relative[index] - prefix
                var running: CGFloat = 0
                for i in 0..<count {
                    slopes.append(origin + running + relative[i] / 2)
                    scales.append(scale[i])
                    running += relative[i]
                }
            }
        }

        /// The worst glyph reach past [0, total], in points.
        func overshoot(total: CGFloat) -> CGFloat {
            var worst: CGFloat = 0
            for index in slopes.indices {
                let glyph = 4.5 * scales[index]
                let top = total * slopes[index] - glyph
                let bottom = total * (slopes[index] - 1) + glyph
                worst = max(worst, -top, bottom)
            }
            return max(0, worst)
        }
    }

    /// The tabulated shapes for the rails the Deck draws (27, 14 and 9 slots).
    private static let shapes: [Int: Shape] = {
        let counts = [DeckRail.letters.count,
                      (DeckRail.letters.count + 1) / 2,
                      (DeckRail.letters.count + 2) / 3]
        return Dictionary(uniqueKeysWithValues: counts.map { ($0, Shape(count: $0)) })
    }()

    private static func shape(for count: Int) -> Shape {
        shapes[count] ?? Shape(count: count)
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
