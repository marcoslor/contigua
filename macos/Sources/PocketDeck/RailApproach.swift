// The Deck rail's approach zone (docs/specs/deck.md DECK-7): the pointer is
// tracked on the grid's container, not on the 26 pt rail, so a letter begins to
// grow while the pointer is still over the last icon column and reaches full
// size only at the rail. Pure pieces so the ramp and the pointer machine are
// unit-tested without a window.

import SwiftUI

enum RailApproach {
    /// The approach zone: 64 pt, about one icon column, the width the person
    /// picked from the prototype's A1/A2/A3 (proto/rail2, 10-29).
    static let zone: CGFloat = 64
}

/// The pointer over the Deck's trailing edge as one state. Approaching is the
/// zone between the grid and the rail; hovering is over the rail itself;
/// dragging is a press that started there. The zone and the rail never overlap
/// a click: this only tracks.
enum RailPointer: Equatable {
    case away
    case approaching(dx: CGFloat, y: CGFloat)
    case hovering(y: CGFloat)
    case dragging(y: CGFloat)

    /// Where the fisheye is centred, and how far left of the rail it is (0
    /// inside the rail).
    var position: (dx: CGFloat, y: CGFloat)? {
        switch self {
        case .away: nil
        case .approaching(let dx, let y): (dx, y)
        case .hovering(let y), .dragging(let y): (0, y)
        }
    }

    /// The help tag names the letter only while the pointer is on the rail;
    /// gliding past in the approach zone shows the magnification alone.
    var showsHelpTag: Bool {
        switch self {
        case .hovering, .dragging: true
        case .away, .approaching: false
        }
    }

    var isDragging: Bool {
        if case .dragging = self { return true }
        return false
    }
}

enum RailPointerEvent: Equatable {
    /// A container hover point, already reduced to `dx` (points left of the
    /// rail's leading edge, 0 inside the rail) and its y in the rail.
    case track(dx: CGFloat, y: CGFloat)
    case leave
    case press(y: CGFloat)
    case drag(y: CGFloat)
    case release(y: CGFloat)
}

enum RailPointerAction: Equatable {
    /// Ease the letters back to rest over `duration` (0 under Reduce Motion).
    case animateRest(duration: TimeInterval)
}

extension RailPointer {
    static let restDuration: TimeInterval = 0.12

    /// The one transition function: `(state, event) -> (state, actions)`. Every
    /// event is accepted or ignored here, never by a flag somewhere else.
    static func reduce(_ state: RailPointer, event: RailPointerEvent,
                       zone: CGFloat, reduceMotion: Bool) -> (RailPointer, [RailPointerAction]) {
        func rest() -> [RailPointerAction] {
            [.animateRest(duration: reduceMotion ? 0 : restDuration)]
        }
        switch event {
        case .track(let dx, let y):
            // A drag owns the pointer until it ends: the container still sends
            // hover points, and they must not pull the letter off the drag.
            guard !state.isDragging else { return (state, []) }
            guard dx <= zone else { return (.away, rest()) }
            return (dx <= 0 ? .hovering(y: y) : .approaching(dx: dx, y: y), [])
        case .leave:
            if case .away = state { return (.away, []) }
            return (.away, rest())
        case .press(let y):
            guard case .hovering = state else { return (state, []) }
            return (.dragging(y: y), [])
        case .drag(let y):
            guard case .dragging = state else { return (state, []) }
            return (.dragging(y: y), [])
        case .release(let y):
            guard case .dragging = state else { return (state, []) }
            return (.hovering(y: y), [])
        }
    }
}

/// Where the pointer is, for the rail alone. A pointer moving over the grid
/// writes here and invalidates the rail; the grid's body never reads it, which
/// is what keeps the drag p95 measured on the grid out of the picture.
@MainActor
@Observable
final class RailPointerModel {
    static let shared = RailPointerModel()

    private(set) var state: RailPointer = .away
    /// The grid container's size in points, so a hover point can be turned
    /// into a distance left of the rail's leading edge and a y in the rail.
    private(set) var containerSize = CGSize.zero
    /// The rail this content height draws: its letter count and rest pitch.
    /// Static per window size, so the pitch cannot jitter while the pointer
    /// moves.
    private(set) var railFit: (count: Int, pitch: CGFloat)?
    /// The rail's slots as drawn, for the e2e's forced position.
    var slots: [DeckRail.Slot] = []

    init() {}

    func noteContainerSize(_ size: CGSize) {
        guard size != containerSize else { return }
        containerSize = size
        railFit = RailLayout.fit(content: size.height)
    }

    func track(dx: CGFloat, y: CGFloat, zone: CGFloat, reduceMotion: Bool) {
        send(.track(dx: dx, y: y), zone: zone, reduceMotion: reduceMotion)
    }

    func leave(reduceMotion: Bool) {
        send(.leave, zone: 0, reduceMotion: reduceMotion)
    }

    func press(y: CGFloat, reduceMotion: Bool) {
        send(.press(y: y), zone: 0, reduceMotion: reduceMotion)
    }

    func drag(y: CGFloat, reduceMotion: Bool) {
        send(.drag(y: y), zone: 0, reduceMotion: reduceMotion)
    }

    func release(y: CGFloat, reduceMotion: Bool) {
        send(.release(y: y), zone: 0, reduceMotion: reduceMotion)
    }

    /// `control deckrailapproach LETTER DX`: the pointer as if it were DX points
    /// left of the rail, level with LETTER's band. A quiet run cannot move the
    /// pointer, so a shot names the position it needs; the rest of the path
    /// (state machine, ramp, ease) is the live one.
    @discardableResult
    func force(letter: String, dx: CGFloat, reduceMotion: Bool) -> Bool {
        guard let index = DeckRail.letters.firstIndex(of: letter),
              let slot = slots.firstIndex(where: { index >= $0.first && index < $0.first + $0.count })
        else { return false }
        let pitch = railFit?.pitch ?? DeckRail.pitch
        let band = CGFloat(index - slots[slot].first)
        let y = CGFloat(slot) * pitch
            + (band + 0.5) / CGFloat(slots[slot].count) * pitch
        send(.track(dx: max(dx, 0), y: y), zone: RailApproach.zone, reduceMotion: reduceMotion)
        return true
    }

    private func send(_ event: RailPointerEvent, zone: CGFloat, reduceMotion: Bool) {
        let (next, actions) = RailPointer.reduce(state, event: event,
                                                 zone: zone, reduceMotion: reduceMotion)
        guard next != state else { return }
        let rest = actions.compactMap { action -> TimeInterval? in
            guard case .animateRest(let duration) = action else { return nil }
            return duration
        }.first
        if let rest {
            withAnimation(rest > 0 ? .easeOut(duration: rest) : nil) { state = next }
        } else {
            state = next
        }
    }
}
