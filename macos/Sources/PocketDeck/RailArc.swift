// The rail's arc (docs/specs/deck.md DECK-7): a magnified letter reaches left
// out of the rail's column, toward the grid, while the letters far from the
// pointer keep exactly the horizontal position they have at rest. The reach is
// capped by the room the window leaves before the last icon column's cell.

import Foundation

enum RailArc {
    /// The centred letter's leading edge at rest, inside the rail's leading
    /// edge: 13 - 7/2 for the 9 pt letter.
    static let centredLead: CGFloat = 9.5
    /// The centred letter's half width growth at 2.2x (4.5 pt), linear.
    static let centredGrowth: CGFloat = 3.75
    /// The clear space the arc must leave to the last icon column's cell.
    static let minimumClearance: CGFloat = 4
    /// How fast the arc moves a letter left per unit of scale; the room at the
    /// window's width caps it.
    static let reachK: CGFloat = 14

    /// How far left a magnified letter may reach at `width` before it comes
    /// within `minimumClearance` of the last icon column's cell. The letters
    /// are centred, so the rest position is `centredLead` inside the rail, and
    /// the rail always stands one gap right of the grid's right edge.
    static func room(width: CGFloat, zoom: CGFloat = 1) -> CGFloat {
        let block = DeckWide.block(width: width, metrics: DeckGridSize(zoom: zoom, width: width))
        let cellRight = block.originX + block.span
        return max(0, block.railLeading - cellRight + centredLead - minimumClearance)
    }

    /// How far left the rail's hit area may grow while it is magnified: the
    /// room less the letter's own leading inset, so its left edge keeps the
    /// same `minimumClearance` from the last icon column's cell as the letters
    /// do. A click on the cell's trailing edge must still reach the cell.
    static func hitRoom(width: CGFloat, zoom: CGFloat = 1) -> CGFloat {
        max(0, room(width: width, zoom: zoom) - centredLead)
    }

    /// The half-width growth of the centred letter at `scale`.
    static func growth(scale: CGFloat) -> CGFloat {
        max(0, scale - 1) * centredGrowth
    }

    /// The extra leftward offset of a magnified letter (0 for a rest letter),
    /// capped by the room the window leaves at `width`.
    static func offset(scale: CGFloat, reduceMotion: Bool, room: CGFloat) -> CGFloat {
        guard !reduceMotion, scale > 1 else { return 0 }
        let wanted = reachK * (scale - 1)
        let allowed = max(0, room - growth(scale: scale))
        return -min(wanted, allowed)
    }

    /// The arc's whole leftward reach at `scale`: the centred growth plus the
    /// offset.
    static func reach(scale: CGFloat, reduceMotion: Bool, room: CGFloat) -> CGFloat {
        guard !reduceMotion, scale > 1 else { return 0 }
        return growth(scale: scale)
            - offset(scale: scale, reduceMotion: reduceMotion, room: room)
    }

    /// The clear space between the last icon column's cell and the widest drawn
    /// letter at `width` and `zoom`.
    static func clearance(width: CGFloat, zoom: CGFloat = 1, reduceMotion: Bool) -> CGFloat {
        let block = DeckWide.block(width: width, metrics: DeckGridSize(zoom: zoom, width: width))
        let cellRight = block.originX + block.span
        let widestLead = block.railLeading + centredLead
            - reach(scale: RailFisheye.maxScale, reduceMotion: reduceMotion,
                    room: room(width: width, zoom: zoom))
        return widestLead - cellRight
    }
}
