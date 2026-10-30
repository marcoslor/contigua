// The Deck rail's pointer (docs/specs/deck.md DECK-7): the pointer is tracked
// on the grid's container, not on the 26 pt rail. It enters the rail's column
// and the span is computed there and then; it leaves the magnified hit area and
// the rail eases back. Nothing depends on how far the pointer is from the rail,
// so horizontal movement never changes a letter's scale. Pure pieces, so the
// machine is unit-tested without a window.

import SwiftUI

enum RailHover {
    /// A container hover point, reduced to the rail's own space: `dx` points
    /// left of the rail's leading edge (0 inside it) and `y` is measured from
    /// the rail's top, at the pitch the rail is actually drawn with.
    /// `trailing` is the rail's width plus its trailing padding.
    static func point(hover: CGPoint, container: CGSize,
                      fit: (count: Int, pitch: CGFloat),
                      trailing: CGFloat) -> (dx: CGFloat, y: CGFloat) {
        let drawn = CGFloat(fit.count)
        let top = max(0, (container.height - drawn * fit.pitch) / 2)
        let leading = container.width - trailing
        return (max(0, leading - hover.x), hover.y - top)
    }
}

/// The pointer over the Deck's trailing edge as one state: away, on the rail
/// (`hovering`), or pressing and dragging along it. The rail and the grid never
/// share a click: this only tracks.
///
/// The span is computed once, on enter, and carried by the state: hovering and
/// dragging only move the pointer inside it, so A's top and #'s bottom never
/// move while the pointer stays on the rail.
enum RailPointer: Equatable {
    case away
    case hovering(span: RailLayout.Span, y: CGFloat)
    case dragging(span: RailLayout.Span, y: CGFloat)

    /// The frozen span and the pointer inside it.
    var frozen: (span: RailLayout.Span, y: CGFloat)? {
        switch self {
        case .hovering(let span, let y), .dragging(let span, let y): (span, y)
        case .away: nil
        }
    }

    /// The help tag names the letter whenever the pointer is on the rail.
    var showsHelpTag: Bool {
        switch self {
        case .hovering, .dragging: true
        case .away: false
        }
    }

    var isDragging: Bool {
        switch self {
        case .dragging: true
        case .away, .hovering: false
        }
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
    /// Ease the magnification in over `duration` (0 under Reduce Motion).
    case animateIn(duration: TimeInterval)

    var duration: TimeInterval {
        switch self {
        case .animateRest(let duration), .animateIn(let duration): duration
        }
    }
}

extension RailPointer {
    static let easeDuration: TimeInterval = 0.12

    /// The one transition function: `(state, event) -> (state, actions)`. Every
    /// event is accepted or ignored here, never by a flag somewhere else.
    /// `pitch` and `count` are the rail this window draws; `room` is the arc's
    /// room left of the rail, the magnified hit area's left edge.
    static func reduce(_ state: RailPointer, event: RailPointerEvent,
                       pitch: CGFloat, count: Int, room: CGFloat,
                       reduceMotion: Bool) -> (RailPointer, [RailPointerAction]) {
        func rest() -> [RailPointerAction] {
            [.animateRest(duration: reduceMotion ? 0 : easeDuration)]
        }
        switch event {
        case .track(let dx, let y):
            switch state {
            // A drag owns the pointer until it ends, span included.
            case .dragging:
                return (state, [])
            case .hovering(let span, _):
                // Leave on the magnified hit area's left edge, or the span's
                // ends; horizontal movement inside it changes nothing.
                guard dx <= room, y >= span.top, y <= span.bottom else {
                    return (.away, rest())
                }
                return (.hovering(span: span, y: y), [])
            case .away:
                // Enter only inside the rail's rest column, at a y on the rest
                // rail. The scale never depends on x.
                let total = CGFloat(count) * pitch
                guard count > 0, pitch > 0, dx <= 0, y >= 0, y <= total else {
                    return (.away, [])
                }
                let span = RailLayout.span(count: count, pitch: pitch, anchor: y,
                                           reduceMotion: reduceMotion)
                return (.hovering(span: span, y: y),
                        [.animateIn(duration: reduceMotion ? 0 : easeDuration)])
            }
        case .leave:
            if case .away = state { return (.away, []) }
            return (.away, rest())
        case .press(let y):
            guard case .hovering(let span, _) = state else { return (state, []) }
            return (.dragging(span: span, y: y), [])
        case .drag(let y):
            guard case .dragging(let span, _) = state else { return (state, []) }
            return (.dragging(span: span, y: y), [])
        case .release(let y):
            guard case .dragging(let span, _) = state else { return (state, []) }
            // A drag can end outside the rail (SwiftUI keeps sending a drag past
            // its view): the frozen span's ends are where the rail ends, so a
            // release there is a leave, not a hover nobody can see.
            guard y >= span.top, y <= span.bottom else { return (.away, rest()) }
            return (.hovering(span: span, y: y), [])
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
    /// The Deck's zoom: the grid's last column moves with it, and so does the
    /// room the arc and the hit area may take left of the rail.
    private(set) var zoom: CGFloat = 1
    /// The rail this content height draws: its letter count and rest pitch.
    /// Static per window size, so the pitch cannot jitter while the pointer
    /// moves.
    private(set) var railFit: (count: Int, pitch: CGFloat)?
    /// The content height the fit was last computed for, rounded down to a
    /// whole point: a live resize asks once per point of height, not once per
    /// frame, and the fit is never for more room than the container has.
    private var fittedContent: CGFloat = -1
    /// The rail's slots as drawn, for the e2e's forced positions.
    var slots: [DeckRail.Slot] = []

    init() {}

    func noteContainerSize(_ size: CGSize) {
        guard size != containerSize else { return }
        containerSize = size
        let content = size.height.rounded(.down)
        guard content != fittedContent else { return }
        fittedContent = content
        railFit = RailLayout.fit(content: content)
    }

    func noteZoom(_ zoom: CGFloat) {
        guard zoom != self.zoom else { return }
        self.zoom = zoom
    }

    /// How far the arc may reach left of the rail at this width and zoom.
    var arcRoom: CGFloat { RailArc.room(width: containerSize.width, zoom: zoom) }

    /// The magnified hit area's left edge, which is also where the pointer
    /// leaves: the same clearance from the last column's cell as the letters.
    var room: CGFloat { RailArc.hitRoom(width: containerSize.width, zoom: zoom) }

    func track(dx: CGFloat, y: CGFloat, reduceMotion: Bool) {
        send(.track(dx: dx, y: y), reduceMotion: reduceMotion)
    }

    func leave(reduceMotion: Bool) {
        send(.leave, reduceMotion: reduceMotion)
    }

    func press(y: CGFloat, reduceMotion: Bool) {
        send(.press(y: y), reduceMotion: reduceMotion)
    }

    func drag(y: CGFloat, reduceMotion: Bool) {
        send(.drag(y: y), reduceMotion: reduceMotion)
    }

    func release(y: CGFloat, reduceMotion: Bool) {
        send(.release(y: y), reduceMotion: reduceMotion)
    }

    /// `control deckrailenter LETTER` / `deckrailmove LETTER`: the pointer as if
    /// it were inside the rail, level with LETTER's band, so a quiet run can
    /// shoot and check what a real pointer would drive. The first call enters
    /// and freezes the span; the next ones only move inside it.
    @discardableResult
    func force(letter: String, reduceMotion: Bool) -> Bool {
        guard let index = DeckRail.letters.firstIndex(of: letter),
              let slot = slots.firstIndex(where: { index >= $0.first && index < $0.first + $0.count })
        else { return false }
        let pitch = railFit?.pitch ?? DeckRail.pitch
        let band = CGFloat(index - slots[slot].first)
        let y = CGFloat(slot) * pitch
            + (band + 0.5) / CGFloat(slots[slot].count) * pitch
        send(.track(dx: 0, y: y), reduceMotion: reduceMotion)
        return true
    }

    private func send(_ event: RailPointerEvent, reduceMotion: Bool) {
        let fit = railFit ?? (count: slots.count, pitch: DeckRail.pitch)
        let (next, actions) = RailPointer.reduce(state, event: event,
                                                 pitch: fit.pitch, count: fit.count,
                                                 room: room, reduceMotion: reduceMotion)
        guard next != state else { return }
        let duration = actions.map(\.duration).first
        if let duration {
            withAnimation(duration > 0 ? .easeOut(duration: duration) : nil) { state = next }
        } else {
            state = next
        }
    }
}
