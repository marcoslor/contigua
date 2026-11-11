// `deckrailclick LETTER [HOLD_MS]`, `deckraildrag FROM TO`,
// `deckrailclickat X Y [HOLD_MS]` and `deckrailhoverat X Y` (e2e,
// --debug-control): the pointer phases at a point in the rail's own
// coordinates, fed to the rail's view. A background app's SwiftUI gesture does
// not take a synthetic NSEvent, so the view runs the same press/drag/release
// handler a real pointer drives; the hit column (DECK-34) is the view's own.

import AppKit

@MainActor
enum DeckRailInput {
    /// A click at `letter`'s drawn band centre: hover, down, `hold` seconds,
    /// up, as a person's click arrives.
    static func click(letter: String, hold: TimeInterval,
                      controller: ConnectionController) -> String? {
        guard let y = DeckRailPoint.bandCentre(letter: letter) else { return "no rail letter \(letter)" }
        return click(x: 13, y: y, hold: hold, controller: controller)
    }

    /// A press at `from`'s band, dragged through the rail to `to`, released.
    static func drag(from: String, to: String, controller: ConnectionController) -> String? {
        guard let y1 = DeckRailPoint.bandCentre(letter: from) else { return "no rail letter \(from)" }
        guard let y2 = DeckRailPoint.bandCentre(letter: to) else { return "no rail letter \(to)" }
        controller.sendRailPointer(.hover, x: 13, y: y1)
        turn(0.08)
        controller.sendRailPointer(.down, x: 13, y: y1)
        turn(0.05)
        let steps = 8
        for step in 1...steps {
            let fraction = CGFloat(step) / CGFloat(steps)
            controller.sendRailPointer(.drag, x: 13, y: y1 + (y2 - y1) * fraction)
            turn(0.02)
        }
        controller.sendRailPointer(.up, x: 13, y: y2)
        turn(0.1)
        return nil
    }

    /// A click at a point in the rail's own coordinates (0,0 = its top-left).
    static func click(x: CGFloat, y: CGFloat, hold: TimeInterval,
                      controller: ConnectionController) -> String? {
        controller.sendRailPointer(.hover, x: x, y: y)
        turn(0.08)
        controller.sendRailPointer(.down, x: x, y: y)
        turn(max(hold, 0.02))
        controller.sendRailPointer(.up, x: x, y: y)
        turn(0.1)
        return nil
    }

    /// A pointer move at a point in the rail's own coordinates, as the
    /// container's hover would see it.
    static func hover(x: CGFloat, y: CGFloat, controller: ConnectionController) -> String? {
        controller.sendRailPointer(.hover, x: x, y: y)
        turn(0.1)
        return nil
    }

    /// Let the view run its handler and SwiftUI redraw before the next phase.
    private static func turn(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date(timeIntervalSinceNow: seconds))
    }
}
