// The Deck on a wide window (DECK-4, DECK-24): over 1000 pt the whole grid
// grows with the window — the person's zoom times clamp(width/1000, 1, 1.5) —
// and the block reserves the rail's 44 pt, so the letter column always sits
// beside the grid and never over its last cell. The numbers are pure and
// computed from the width the layout pass is drawing; a stored width lags a
// live resize by a frame and clips the edge columns (the 10-21 Deck zoom
// regression), so nothing here is state.

import AppKit

enum DeckWide {
    /// The rail's column and its gap to the scroller: the room the grid
    /// reserves on its trailing side, and the distance the rail's hover and its
    /// arc measure from.
    static let railWidth: CGFloat = 26
    static let railGap: CGFloat = 18
    static let railSpace: CGFloat = railWidth + railGap

    /// The width at which the design's 880 pt block keeps its 60 pt margins:
    /// narrower windows draw the grid at the person's zoom alone.
    static let referenceWidth: CGFloat = 1000
    /// The block's cap at 100 %.
    static let cap: CGFloat = 880
    /// The margin today's 1000 pt window leaves beside the 880 pt block; the
    /// standard zoom keeps it at the person's zoom.
    static let sideMargin: CGFloat = 60

    /// The grid's extra scale at a window this wide.
    static func tileScale(width: CGFloat) -> CGFloat {
        min(max(width / referenceWidth, 1), 1.5)
    }

    /// Where the grid and its rail sit in a container `width` wide.
    struct Block: Equatable {
        var columns: Int
        /// The drawn width of one full row.
        var span: CGFloat
        /// The grid's left edge.
        var originX: CGFloat
        /// The rail's column's leading edge.
        var railLeading: CGFloat
        /// From the container's trailing edge to the rail's trailing edge.
        var railPadding: CGFloat

        /// From the container's trailing edge to the rail's leading edge.
        var railTrailingSpace: CGFloat { railPadding + railWidth }
    }

    /// The block: columns are what fits the reserved room, never fewer than
    /// one, and grid plus rail are centred together so both margins match.
    static func block(width: CGFloat, metrics: DeckGridSize) -> Block {
        let available = max(min(width - railSpace, metrics.maxContentWidth), 0)
        let pitch = metrics.cellWidth + metrics.columnGap
        let columns = max(Int((available + metrics.columnGap) / pitch), 1)
        let span = CGFloat(columns) * metrics.cellWidth
            + CGFloat(max(columns - 1, 0)) * metrics.columnGap
        let originX = max((width - (span + railSpace)) / 2, 0)
        let railLeading = originX + span + railGap
        return Block(columns: columns, span: span, originX: originX,
                     railLeading: railLeading,
                     railPadding: width - railLeading - railWidth)
    }

    /// Where cell `index` is drawn in a block.
    static func cellFrame(_ index: Int, in block: Block, metrics: DeckGridSize,
                          origin: CGPoint = .zero) -> CGRect {
        let column = index % block.columns
        let row = index / block.columns
        return CGRect(x: origin.x + block.originX + CGFloat(column) * (metrics.cellWidth + metrics.columnGap),
                      y: origin.y + metrics.verticalInset + CGFloat(row) * (metrics.cellHeight + metrics.rowSpacing),
                      width: metrics.cellWidth, height: metrics.cellHeight)
    }

    /// The block's height for `count` cells: the inset above and below and the
    /// rows in between.
    static func height(count: Int, block: Block, metrics: DeckGridSize) -> CGFloat {
        let rows = (count + block.columns - 1) / block.columns
        return 2 * metrics.verticalInset + CGFloat(rows) * metrics.cellHeight
            + CGFloat(max(rows - 1, 0)) * metrics.rowSpacing
    }

    /// The Deck's intrinsic width at a zoom (DECK-24): the 880 pt grid, the
    /// 60 pt a side today's 1000 pt window leaves, and the rail, all at the
    /// person's zoom.
    static func preferredWidth(zoom: CGFloat) -> CGFloat {
        (cap + 2 * sideMargin) * DeckZoom.clamped(zoom) + railSpace
    }

    /// The standard zoom's frame: the intrinsic width, centred on the screen,
    /// at the screen's visible height — never wider than the screen.
    static func standardFrame(visible: CGRect, preferredWidth: CGFloat) -> CGRect {
        let width = min(preferredWidth, visible.width)
        return CGRect(x: (visible.midX - width / 2).rounded(), y: visible.minY,
                      width: width, height: visible.height)
    }
}
