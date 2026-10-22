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
            return ["id": cell.id, "label": cell.label, "icon": icon]
        }
        append(["count": cells.count, "items": items])
    }

    /// The block the layout drew, at the zoom step the run uses. Written on
    /// every real geometry change, so a check can resize the window and read
    /// the settled numbers.
    @MainActor
    static func reportGeometry(_ metrics: DeckGridSize, viewport: CGFloat) {
        let key = "\(Int(viewport.rounded()))|\(metrics.zoom)|\(metrics.columns(forWidth: viewport))"
        guard key != lastGeometry else { return }
        lastGeometry = key
        append([
            "viewport": Double(viewport),
            "zoom": Double(metrics.zoom),
            "columns": metrics.columns(forWidth: viewport),
            "cell": Double(metrics.cellWidth),
            "cellHeight": Double(metrics.cellHeight),
            "gap": Double(metrics.gap(forWidth: viewport)),
            "contentWidth": Double(metrics.span(forWidth: viewport)),
            "contentLeft": Double(metrics.originX(forWidth: viewport)),
            "cap": Double(metrics.maxContentWidth),
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
