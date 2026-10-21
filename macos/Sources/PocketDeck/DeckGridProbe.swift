// The Deck grid's drawn cells, for the e2e `deck` check (`--debug-deck-grid
// FILE`): one JSON line per change, with each cell's id, its label and what its
// tile shows. The person's v105 screenshot has an empty slot in the middle of a
// row; the check pins that both entries of a repeated package are drawn, each
// with words under it. Ids, labels and icon states of the e2e fixtures only:
// the flag exists on the test launch line and nothing here runs otherwise.

import AppKit
import Foundation

enum DeckGridProbe {
    @MainActor
    static func report(_ cells: [DeckCell], icons: [String: NSImage],
                       rendered: [String: NSImage], missing: Set<String>, online: Bool) {
        guard let path = AppEnvironment.shared.options.debugDeckGrid else { return }
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
        let line: [String: Any] = ["count": cells.count, "items": items]
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
