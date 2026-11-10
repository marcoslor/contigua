// The rail's emphasis on All Apps (docs/specs/deck.md DECK-32): WHILE the
// pointer is on a rail letter, that letter's tiles lift and the rest of All
// Apps dims; the Open on this Mac and Pinned sections never take it. The
// emphasis is state, not timing: the machine below is fed the letter a jump
// would land on (an empty letter forwards to the next letter with apps), and
// the views read its one letter. The fade's duration is part of the transition,
// never a per-tile timer.

import SwiftUI

/// DECK-32's one small machine: no emphasis, or one letter's. Every event is
/// accepted or ignored here, and the transition names its own duration so the
/// 0.12 s in, 0.2 s out (and Reduce Motion's zero) cannot drift apart.
enum RailEmphasis: Equatable {
    case none
    case letter(String)

    enum Event: Equatable {
        /// The pointer rests on a rail letter; `letter` is the one a jump
        /// would land on, so the grid and the rail's accent agree.
        case point(String)
        case leave
    }

    enum Action: Equatable {
        /// Ease the emphasis in over `duration` (0 under Reduce Motion).
        case animateIn(duration: TimeInterval)
        /// Ease the emphasis out over `duration` (0 under Reduce Motion).
        case animateOut(duration: TimeInterval)

        var duration: TimeInterval {
            switch self {
            case .animateIn(let duration), .animateOut(let duration): duration
            }
        }
    }

    static let enterDuration: TimeInterval = 0.12
    static let leaveDuration: TimeInterval = 0.2

    /// The letter All Apps lights, when there is one.
    var letter: String? {
        switch self {
        case .letter(let letter): letter
        case .none: nil
        }
    }

    static func reduce(_ state: RailEmphasis, event: Event,
                       reduceMotion: Bool) -> (RailEmphasis, [Action]) {
        func enter() -> [Action] {
            [.animateIn(duration: reduceMotion ? 0 : enterDuration)]
        }
        switch event {
        case .point(let letter):
            switch state {
            case .none:
                return (.letter(letter), enter())
            case .letter(let current):
                // The pointer moving inside one letter changes nothing; moving
                // to another cross-fades in over the entry duration, never
                // through rest.
                guard letter != current else { return (state, []) }
                return (.letter(letter), enter())
            }
        case .leave:
            switch state {
            case .none:
                return (.none, [])
            case .letter:
                return (.none, [.animateOut(duration: reduceMotion ? 0 : leaveDuration)])
            }
        }
    }
}

/// What one tile draws while the rail's emphasis names a letter. `rest` is
/// today's tile; only All Apps can take `lift` or `dim` (DECK-32).
enum DeckCellEmphasis: Equatable {
    case rest
    case dim
    case lift

    /// The numbers DECK-32 and DESIGN.md name.
    static let dimOpacity: Double = 0.5
    static let liftScale: CGFloat = 1.08

    var opacity: Double { self == .dim ? Self.dimOpacity : 1 }

    /// The lift is a transform: the grid's layout and its neighbours do not
    /// move. Reduce Motion keeps every tile at its drawn size.
    func scale(reduceMotion: Bool) -> CGFloat {
        self == .lift && !reduceMotion ? Self.liftScale : 1
    }

    var labelWeight: Font.Weight { self == .lift ? .semibold : .regular }

    /// One tile's emphasis. `label` is nil for the sections (Open on this Mac,
    /// Pinned), which never dim or lift; a non-interactive page (offline,
    /// reconnecting) keeps every tile at rest because the page is already
    /// dimmed as one (DECK-31).
    static func tile(label: String?, letter: String?, interactive: Bool) -> DeckCellEmphasis {
        guard interactive, let label, let letter else { return .rest }
        return DeckRail.letter(for: label) == letter ? .lift : .dim
    }
}

/// The rail's emphasis for the whole Deck, one value the tiles read. Only a
/// pointer move to a different letter writes here; the grid's own body never
/// reads it, so the layout is not rebuilt on each letter (the cells are).
@MainActor
@Observable
final class RailEmphasisModel {
    static let shared = RailEmphasisModel()

    private(set) var state: RailEmphasis = .none
    /// The duration of the last transition, so every tile animates with the
    /// same one: 0.12 s in, 0.2 s out, zero under Reduce Motion.
    private(set) var duration: TimeInterval = 0
    /// The last event, for the e2e probe (`point(B)` shows the empty letter
    /// that forwarded to its landing letter).
    private(set) var lastEvent = ""
    /// The rail letter actually under the pointer, when it differs from the
    /// landing letter: an empty letter forwards to the next one with apps.
    private(set) var lastPointer = ""

    init() {}

    func point(pointer: String, landed: String, reduceMotion: Bool) {
        lastPointer = pointer
        send(.point(landed), reduceMotion: reduceMotion)
    }

    func leave(reduceMotion: Bool) {
        send(.leave, reduceMotion: reduceMotion)
    }

    /// What one All Apps tile draws. The view asks only for All Apps; the
    /// sections never read this (DECK-32).
    func emphasis(for label: String, interactive: Bool) -> DeckCellEmphasis {
        DeckCellEmphasis.tile(label: label, letter: state.letter, interactive: interactive)
    }

    private func send(_ event: RailEmphasis.Event, reduceMotion: Bool) {
        let before = state
        lastEvent = event.name
        let (next, actions) = RailEmphasis.reduce(before, event: event,
                                                  reduceMotion: reduceMotion)
        // An ignored event (the same letter, or leaving while at rest) is not
        // a transition: no animation and no log line.
        guard next != before else { return }
        duration = actions.map(\.duration).first ?? 0
        state = next
        Log.app.debug("rail emphasis: \(before.name, privacy: .public) --\(event.name, privacy: .public)--> \(next.name, privacy: .public)") // log-ok: the machine's closed state names, never a value
    }
}

extension RailEmphasis {
    var name: String {
        switch self {
        case .none: "none"
        case .letter(let letter): "letter(\(letter))"
        }
    }
}

extension RailEmphasis.Event {
    var name: String {
        switch self {
        case .point(let letter): "point(\(letter))"
        case .leave: "leave"
        }
    }
}

extension DeckCellEmphasis {
    var name: String {
        switch self {
        case .rest: "rest"
        case .dim: "dim"
        case .lift: "lift"
        }
    }

    var weightName: String { self == .lift ? "semibold" : "regular" }
}

/// The tiles as the views drew them, for e2e `deckrail` `[DECK-32]`
/// (`control deckrailemph FILE`). Each page cell notes the emphasis it applied;
/// the dump pairs those with the machine's state, so a green check means the
/// views read the machine, not merely that the machine changed. Recording runs
/// only on a test launch that already passes `--debug-deck-grid`.
@MainActor
enum RailEmphasisProbe {
    struct Tile: Equatable {
        let section: String
        let label: String
        let letter: String
        let emphasis: String
        let opacity: Double
        let scale: CGFloat
        let weight: String
    }

    private static var tiles: [String: Tile] = [:]

    static func note(_ cell: DeckPageCell, emphasis: DeckCellEmphasis,
                     reduceMotion: Bool) {
        guard AppEnvironment.shared.options.debugDeckEmphasis else { return }
        tiles[cell.id] = Tile(
            section: cell.section.rawValue,
            label: cell.app.displayLabel,
            letter: DeckRail.letter(for: cell.app.displayLabel),
            emphasis: emphasis.name,
            opacity: emphasis.opacity,
            scale: emphasis.scale(reduceMotion: reduceMotion),
            weight: emphasis.weightName)
    }

    /// The machine's state and every tile's drawn emphasis, one JSON object.
    /// Sorted so a check can diff two runs; the state's letter is a rail letter
    /// (a closed set), never a person's text.
    static func dump(to path: String) -> Bool {
        let model = RailEmphasisModel.shared
        let ordered = tiles.keys.sorted().compactMap { id -> [String: Any]? in
            guard let tile = tiles[id] else { return nil }
            return [
                "id": id,
                "section": tile.section,
                "label": tile.label,
                "letter": tile.letter,
                "emphasis": tile.emphasis,
                "opacity": tile.opacity,
                "scale": Double(tile.scale),
                "weight": tile.weight,
            ]
        }
        let state: String
        switch model.state {
        case .none: state = "none"
        case .letter: state = "letter"
        }
        let line: [String: Any] = [
            "state": state,
            "letter": model.state.letter ?? "",
            "pointer": model.lastPointer,
            "event": model.lastEvent,
            "duration": model.duration,
            "tiles": ordered,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: line, options: [.sortedKeys]),
              var text = String(data: data, encoding: .utf8) else { return false }
        text += "\n"
        return (try? text.write(toFile: path, atomically: true, encoding: .utf8)) != nil
    }
}
