// The rail's spacing while the pointer is near it (prototype, person's 10-29
// note: the Dock keeps the same proportional gap between items; our fixed 20 pt
// rows crowd magnified letters). Three strategies, behind the `--debug-proto
// railspace` test hook. Pure: the drawn slots are one function of the scales,
// the rail's height and the pointer's anchor, so the view and the tests share
// them.

import Foundation

enum RailSpacing: String, CaseIterable {
    /// Today: every letter in a fixed 20 pt row, whatever its size.
    case reference = "R"
    /// S1, Dock: each slot grows with its letter; the rail grows around the
    /// pointer.
    case dock = "S1"
    /// S2, Lens: proportional slots with the rail's height fixed; the letters
    /// beyond the fisheye's reach shrink to pay for the magnified ones.
    case lens = "S2"
    /// S3, Dock arc: S1's proportional slots, but each letter's trailing edge
    /// stays on the rail's trailing baseline and the letter grows leftward, so
    /// the leading edges trace an arc into the gap before the grid.
    case arc = "S3"

    /// Whether the letters hang off the rail's trailing baseline instead of
    /// being centred in it (S3).
    var isEdgeAnchored: Bool { self == .arc }

    /// `railspace=S2` from `--debug-proto`; nil for anything else.
    static func parse(_ value: String) -> RailSpacing? {
        let parts = value.split(separator: "=", maxSplits: 1).map(String.init)
        guard parts.count == 2, parts[0] == "railspace" else { return nil }
        return RailSpacing(rawValue: parts[1])
    }
}

enum RailLayout {
    /// One drawn slot, in the rail's own coordinate space (its top-left is 0,0).
    struct Slot: Equatable {
        var y: CGFloat
        var height: CGFloat
    }

    /// The slots to draw. `scales` is one scale per rail slot (1 at rest),
    /// `available` the rail's rest height (the fixed total of S2), `anchor`
    /// the pointer's y in the rest layout. S1 and S3 grow past `available`;
    /// S2 keeps its total at `available`. All three place the anchor slot so
    /// the pointer sits at the same fraction of it: the letter under the
    /// pointer stays under the pointer while the slots open.
    static func slots(scales: [CGFloat], available: CGFloat,
                      strategy: RailSpacing, anchor: CGFloat?) -> [Slot] {
        let count = scales.count
        guard count > 0, available > 0 else { return [] }
        let pitch = DeckRail.pitch
        func rest() -> [Slot] {
            (0..<count).map { Slot(y: CGFloat($0) * pitch, height: pitch) }
        }
        guard strategy != .reference else { return rest() }
        let total = scales.reduce(0, +)
        guard total > 0 else { return rest() }
        let heights: [CGFloat]
        switch strategy {
        case .reference:
            return rest()
        case .dock, .arc:
            heights = scales.map { pitch * max($0, 0.5) }
        case .lens:
            heights = scales.map { available * $0 / total }
        }
        // The pointer's slot in the rest grid, and how far into it it sits.
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
