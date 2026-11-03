// The Deck grid's drawn cells and geometry, for the e2e `deck` check
// (`--debug-deck-grid FILE`): one JSON line per change, with each cell's id,
// its label, what its tile shows, and the block the layout drew (columns,
// cell size, gap, content width and left edge, viewport, zoom). The person's
// v105 screenshot has an empty slot in the middle of a row; the check pins that
// both entries of a repeated package are drawn, each with words under it, and
// that the D block is centred and capped. Ids, labels and icon states of the
// e2e fixtures only: the flag exists on the test launch line and nothing here
// runs otherwise.

import AppKit
import Foundation

enum DeckGridProbe {
    private nonisolated(unsafe) static var lastGeometry: String?

    @MainActor
    static func report(_ cells: [DeckCell], icons: [String: NSImage],
                       rendered: [String: NSImage], missing: Set<String>, online: Bool) {
        // The flat-icon check reads one pixel of each drawn tile, so the dump
        // must be rewritten when an icon lands, not only when the cells do
        // (`DeckViews`' task id includes the drawn count for that).
        let wantsInk = AppEnvironment.shared.options.debugDeckGrid != nil
        let items: [[String: String]] = cells.map { cell in
            let pkg = cell.app.pkg
            let icon: String
            if rendered[pkg] != nil {
                icon = "rendered"
            } else if icons[pkg] != nil {
                icon = "flat"
            } else if missing.contains(pkg) || !online {
                icon = "missing"
            } else {
                icon = "waiting"
            }
            var item = ["id": cell.id, "label": cell.label, "icon": icon]
            if wantsInk, let image = rendered[pkg], let ink = edgeInk(image) { item["ink"] = ink }
            return item
        }
        append(["count": cells.count, "items": items])
    }

    /// The colour the tile drew just inside the body's leading edge, at half
    /// height: a plated flat icon shows its plate there, a covered one its own
    /// pixels (docs/design/dock.md §Icons). The body starts at 10 % of the
    /// canvas and a plated icon reaches 18.6 %, so 12.5 % tells them apart.
    static func edgeInk(_ image: NSImage) -> String? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let column = Int(Double(cg.width) * 0.125), row = cg.height / 2
        var pixel = [UInt8](repeating: 0, count: 4)
        pixel.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
                                          bytesPerRow: 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return }
            // No colour management and no interpolation: the bytes the render
            // wrote. CG's y is up, the dump's rows are top down.
            context.interpolationQuality = .none
            context.draw(cg, in: CGRect(x: -Double(column), y: -Double(cg.height - 1 - row),
                                        width: Double(cg.width), height: Double(cg.height)))
        }
        return "\(pixel[0]),\(pixel[1]),\(pixel[2])"
    }

    /// The block the layout drew, at the zoom step and the width the run uses.
    /// Written on every real geometry change, so a check can resize the window
    /// and read the settled numbers: the tiles, the cap, the block and the
    /// rail's column all follow the width (DECK-4).
    @MainActor
    static func reportGeometry(zoom: CGFloat, viewport: CGFloat) {
        let metrics = DeckGridSize(zoom: zoom, width: viewport)
        let block = DeckWide.block(width: viewport, metrics: metrics)
        let key = "\(Int(viewport.rounded()))|\(metrics.zoom)|\(metrics.tileScale)|\(block.columns)"
        guard key != lastGeometry else { return }
        lastGeometry = key
        append([
            "viewport": Double(viewport),
            "zoom": Double(metrics.zoom),
            "factor": Double(metrics.tileScale),
            "columns": block.columns,
            "cell": Double(metrics.cellWidth),
            "cellHeight": Double(metrics.cellHeight),
            "gap": Double(metrics.columnGap),
            "contentWidth": Double(block.span),
            "contentLeft": Double(block.originX),
            "cap": Double(metrics.maxContentWidth),
            "railLeft": Double(block.railLeading),
            "railSpace": Double(DeckWide.railSpace),
        ])
    }

    /// The rail click's target: the letter and the index it scrolled to. The
    /// e2e check compares the index with the first app of that letter in the
    /// cell dump.
    @MainActor
    static func reportRailPick(letter: String, index: Int) {
        append(["rail": ["letter": letter, "index": index]])
    }

    /// The row at the viewport's top after a scroll, so the check can prove the
    /// rail's target is on screen, not merely that the click ran.
    @MainActor
    static func reportRailTop(letter: String, index: Int) {
        append(["railTop": ["letter": letter, "index": index]])
    }

    /// The rail's accent letter, the letter of the row it sits on, and the
    /// machine's state: the e2e proves a pick keeps the clicked letter — the
    /// row's letter differs — that the jump settled, and that a scroll by
    /// other means hands the accent back to the row's letter.
    @MainActor
    static func reportRailAccent(letter: String?, topRow: String?, top: Int, columns: Int,
                                 state: String, offset: CGFloat, maxOffset: CGFloat) {
        append(["railAccent": ["letter": letter ?? "", "row": topRow ?? "",
                               "top": top, "columns": columns, "state": state,
                               "offset": Double(offset), "max": Double(maxOffset)]])
    }

    #if PD_TEST_HOOKS
    /// How many times the grid's body has been evaluated. The rail's pointer is
    /// tracked in a store only the rail reads; the e2e proves that pointer moves
    /// in the approach zone leave this number alone (`control deckbodycount`).
    @MainActor private(set) static var bodyCount = 0

    @MainActor
    static func noteBody() { bodyCount += 1 }

    @MainActor
    static func resetBodyCount() { bodyCount = 0 }
    #endif

    private static func append(_ line: [String: Any]) {
        guard let path = AppEnvironment.shared.options.debugDeckGrid else { return }
        guard let data = try? JSONSerialization.data(withJSONObject: line, options: [.sortedKeys]),
              var text = String(data: data, encoding: .utf8) else { return }
        text += "\n"
        if !FileManager.default.fileExists(atPath: path) {
            try? text.write(toFile: path, atomically: true, encoding: .utf8)
            return
        }
        guard let handle = FileHandle(forWritingAtPath: path) else { return }
        defer { try? handle.close() }
        try? handle.seekToEnd()
        try? handle.write(contentsOf: Data(text.utf8))
    }
}
