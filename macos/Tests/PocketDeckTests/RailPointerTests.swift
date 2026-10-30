// The rail's pointer (DECK-7): the hover comes in from the container, the
// pointer machine enters the rail's column and freezes the span there, and it
// leaves the magnified hit area. The machine is tested here for every event it
// accepts and every event it must ignore, along with the hover's conversion
// into the rail's own space.

import XCTest
@testable import PocketDeck

final class RailPointerTests: XCTestCase {
    private var fit: (count: Int, pitch: CGFloat) {
        RailLayout.fit(content: 573) ?? (27, 19.73)
    }

    private func reduce(_ state: RailPointer, _ event: RailPointerEvent,
                        room: CGFloat = 22, reduceMotion: Bool = false)
        -> (RailPointer, [RailPointerAction]) {
        RailPointer.reduce(state, event: event, pitch: fit.pitch, count: fit.count,
                           room: room, reduceMotion: reduceMotion)
    }

    private var y0: CGFloat { 12.5 * fit.pitch }

    // MARK: The hover's conversion into the rail's drawn space

    private var drawnFit: (count: Int, pitch: CGFloat) {
        (27, RailLayout.restPitch(count: 27, content: 573))
    }

    /// A hover on M's drawn centre is M's row: the conversion uses the pitch
    /// the rail is drawn with, not the nominal 20 pt.
    func testRailPointPutsAHoverOnTheDrawnRow() {
        let container = CGSize(width: 1000, height: 573)
        XCTAssertEqual(drawnFit.pitch, 19.71, accuracy: 0.02, "the fitted pitch at 625 pt")
        let railTop = (container.height - CGFloat(drawnFit.count) * drawnFit.pitch) / 2
        let hover = CGPoint(x: 1000 - 44 + 13, y: railTop + 12.5 * drawnFit.pitch)
        let point = RailHover.point(hover: hover, container: container, fit: drawnFit, trailing: 44)
        XCTAssertEqual(point.y, 12.5 * drawnFit.pitch, accuracy: 0.01,
                       "M's drawn centre must read as M's row")
        XCTAssertEqual(point.dx, 0, accuracy: 0.01, "inside the rail")
    }

    func testRailPointMeasuresDxFromTheRailsLeadingEdge() {
        let container = CGSize(width: 1000, height: 573)
        let leading = container.width - 44
        let hover = CGPoint(x: leading - 40, y: 200)
        XCTAssertEqual(RailHover.point(hover: hover, container: container, fit: drawnFit, trailing: 44).dx,
                       40, accuracy: 0.01)
        let inside = CGPoint(x: leading + 5, y: 200)
        XCTAssertEqual(RailHover.point(hover: inside, container: container, fit: drawnFit, trailing: 44).dx,
                       0, accuracy: 0.01)
    }

    // MARK: The pointer machine

    func testEnterFreezesTheSpanOnTheRestRail() {
        let (state, actions) = reduce(.away, .track(dx: 0, y: y0))
        guard case .hovering(let span, let y) = state else {
            return XCTFail("the pointer did not enter")
        }
        XCTAssertEqual(y, y0)
        XCTAssertEqual(span, RailLayout.span(count: fit.count, pitch: fit.pitch, anchor: y0))
        XCTAssertEqual(actions, [.animateIn(duration: RailPointer.easeDuration)])

        // Only inside the rest column, at a y on the rest rail.
        let total = CGFloat(fit.count) * fit.pitch
        for (dx, y) in [(CGFloat(10), y0), (0, CGFloat(-1)), (0, total + 1)] {
            let (state, actions) = reduce(.away, .track(dx: dx, y: y))
            XCTAssertEqual(state, .away, "entered from dx \(dx), y \(y)")
            XCTAssertTrue(actions.isEmpty)
        }
    }

    func testMovingInsideKeepsTheSpanAndAHoverCannotMoveADrag() {
        let (entered, _) = reduce(.away, .track(dx: 0, y: y0))
        guard case .hovering(let span, _) = entered else { return XCTFail("no enter") }
        let (moved, actions) = reduce(entered, .track(dx: 0, y: y0 + 10))
        XCTAssertEqual(moved, .hovering(span: span, y: y0 + 10))
        XCTAssertTrue(actions.isEmpty)

        let (pressed, _) = reduce(entered, .press(y: y0 + 40))
        XCTAssertEqual(pressed, .dragging(span: span, y: y0 + 40))
        XCTAssertTrue(pressed.isDragging)
        let (dragged, _) = reduce(pressed, .drag(y: y0 + 80))
        XCTAssertEqual(dragged, .dragging(span: span, y: y0 + 80))
        let (held, heldActions) = reduce(dragged, .track(dx: 40, y: y0))
        XCTAssertEqual(held, dragged, "the container's hover must not fight the drag")
        XCTAssertTrue(heldActions.isEmpty)
        let (released, _) = reduce(dragged, .release(y: y0 + 80))
        XCTAssertEqual(released, .hovering(span: span, y: y0 + 80))
    }

    func testLeaveOnTheRoomsEdgeOrPastTheSpanEnds() {
        let (entered, _) = reduce(.away, .track(dx: 0, y: y0))
        guard case .hovering(let span, _) = entered else { return XCTFail("no enter") }
        for event in [RailPointerEvent.track(dx: 23, y: y0),
                      .track(dx: 0, y: span.top - 1),
                      .track(dx: 0, y: span.bottom + 1),
                      .leave] {
            let (left, actions) = reduce(entered, event)
            XCTAssertEqual(left, .away, "\(event) did not leave")
            XCTAssertEqual(actions, [.animateRest(duration: RailPointer.easeDuration)])
        }
        let (away, awayActions) = reduce(.away, .leave)
        XCTAssertEqual(away, .away)
        XCTAssertTrue(awayActions.isEmpty, "already away leaves nothing to ease")
    }

    /// K2: a release past the span's ends is outside the rail: the rail eases
    /// back rather than holding a frozen span the pointer is not on. A release
    /// inside the span stays on the rail.
    func testAReleaseOutsideTheSpanEndsTheHover() {
        let (entered, _) = reduce(.away, .track(dx: 0, y: y0))
        guard case .hovering(let span, _) = entered else { return XCTFail("no enter") }
        let (pressed, _) = reduce(entered, .press(y: y0))
        let (outside, actions) = reduce(pressed, .release(y: span.bottom + 30))
        XCTAssertEqual(outside, .away, "a release below the span left the rail hovering")
        XCTAssertEqual(actions, [.animateRest(duration: RailPointer.easeDuration)])
        let (above, _) = reduce(pressed, .release(y: span.top - 30))
        XCTAssertEqual(above, .away)
        let (inside, _) = reduce(pressed, .release(y: y0 + 20))
        XCTAssertEqual(inside, .hovering(span: span, y: y0 + 20))
    }

    /// K2: the container's hover ending during a drag (the pointer left the
    /// window with the button down) ends the hover, not a stale span.
    func testTheHoverEndingDuringADragEndsTheHover() {
        let (entered, _) = reduce(.away, .track(dx: 0, y: y0))
        guard case .hovering = entered else { return XCTFail("no enter") }
        let (pressed, _) = reduce(entered, .press(y: y0 + 5))
        guard case .dragging = pressed else { return XCTFail("no drag") }
        let (left, actions) = reduce(pressed, .leave)
        XCTAssertEqual(left, .away, "the hover ending during a drag left the rail on its span")
        XCTAssertEqual(actions, [.animateRest(duration: RailPointer.easeDuration)])
    }

    func testAPressCannotStartOutsideTheRail() {
        for state in [RailPointer.away] {
            XCTAssertEqual(reduce(state, .press(y: 50)).0, state)
        }
        XCTAssertEqual(reduce(.away, .drag(y: 50)).0, .away)
        XCTAssertEqual(reduce(.away, .release(y: 50)).0, .away)
    }

    func testReduceMotionEntersAndLeavesWithoutAnEase() {
        let (state, actions) = reduce(.away, .track(dx: 0, y: y0), reduceMotion: true)
        guard case .hovering(let span, _) = state else { return XCTFail("no enter") }
        XCTAssertEqual(actions, [.animateIn(duration: 0)], "Reduce Motion drops the ease")
        XCTAssertEqual(span.length, CGFloat(fit.count) * fit.pitch, accuracy: 0.001,
                       "Reduce Motion reserves no magnification")
        let (left, leftActions) = reduce(state, .leave, reduceMotion: true)
        XCTAssertEqual(left, .away)
        XCTAssertEqual(leftActions, [.animateRest(duration: 0)])
    }

    func testReduceMotionDrawsThePlainHighlight() {
        let (state, _) = reduce(.away, .track(dx: 0, y: y0), reduceMotion: true)
        guard case .hovering(let span, let y) = state else { return XCTFail("no enter") }
        XCTAssertTrue(state.showsHelpTag)
        let centre = RailLayout.frozenCentre(atY: y, span: span, count: fit.count)
        let scales = RailLayout.scales(count: fit.count, centre: centre, reduceMotion: true)
        XCTAssertEqual(scales.max() ?? 0, 1, "Reduce Motion magnifies nothing")
        XCTAssertEqual(scales.min() ?? 0, 1)
        XCTAssertEqual(RailArc.offset(scale: 2.2, reduceMotion: true, room: 30), 0,
                       "and the arc is off")
    }

    func testTheStateReportsItsOwnTagAndDrag() {
        XCTAssertFalse(RailPointer.away.showsHelpTag)
        XCTAssertNil(RailPointer.away.frozen)
        let span = RailLayout.Span(top: 0, length: 500)
        XCTAssertTrue(RailPointer.hovering(span: span, y: 1).showsHelpTag)
        XCTAssertTrue(RailPointer.dragging(span: span, y: 1).showsHelpTag)
        XCTAssertFalse(RailPointer.hovering(span: span, y: 1).isDragging)
        XCTAssertTrue(RailPointer.dragging(span: span, y: 1).isDragging)
        XCTAssertEqual(RailPointer.hovering(span: span, y: 34).frozen?.y, 34)
    }

    // MARK: Effective Reduce Motion

    func testTheDebugMotionHookMakesEffectiveReduceMotionFalse() {
        Motion.overrideFull = false
        XCTAssertTrue(Motion.reduce(system: true), "the system setting stands without the hook")
        Motion.overrideFull = true
        defer { Motion.overrideFull = false }
        XCTAssertFalse(Motion.reduce(system: true), "the test hook wins over the system")
        XCTAssertFalse(Motion.reduce(system: false))
    }

    func testTheDebugMotionFlagIsParsed() {
        let options = LaunchOptions.parse(["PocketDeck", "--profile", "e2e", "--debug-motion", "full"])
        XCTAssertEqual(options.debugMotion, "full")
        XCTAssertNil(LaunchOptions.parse(["PocketDeck", "--profile", "e2e"]).debugMotion)
    }

    /// The fit is never for more room than the container has: a live resize
    /// that shrinks it by less than a point must not keep a pitch whose
    /// magnified end extension no longer fits (DECK-7, nothing clipped).
    @MainActor
    func testTheFitNeverOutgrowsTheContainer() {
        let pointer = RailPointerModel()
        for height in [573.0, 572.4, 571.9, 571.2] as [CGFloat] {
            pointer.noteContainerSize(CGSize(width: 1000, height: height))
            let fit = try? XCTUnwrap(pointer.railFit)
            let count = fit?.count ?? 0
            let pitch = fit?.pitch ?? 0
            let needed = CGFloat(count) * pitch + 2 * RailLayout.endExtension(count: count)
            XCTAssertLessThanOrEqual(needed, height + 0.001,
                                     "the fit at \(height) pt needs \(needed) pt")
        }
    }

    // MARK: The e2e's forced position

    @MainActor
    func testForcedPositionResolvesALetterToItsBand() {
        let pointer = RailPointerModel()
        pointer.noteContainerSize(CGSize(width: 1000, height: 573))
        pointer.slots = DeckRail.slots(forHeight: DeckRail.minimumHeight) ?? []
        let pitch = try? XCTUnwrap(pointer.railFit?.pitch)
        let m = 12.5 * (pitch ?? 20)
        XCTAssertTrue(pointer.force(letter: "M", reduceMotion: false))
        guard case .hovering(_, let y) = pointer.state else { return XCTFail("M should be on the rail") }
        XCTAssertEqual(y, m, accuracy: 0.001, "M is the 13th of 27 slots at the drawn pitch")
        XCTAssertFalse(pointer.force(letter: "?", reduceMotion: false), "only a real letter is a position")
        XCTAssertTrue(pointer.force(letter: "N", reduceMotion: false))
        guard case .hovering(_, let n) = pointer.state else { return XCTFail("N should be on the rail") }
        XCTAssertEqual(n, 13.5 * (pitch ?? 20), accuracy: 0.001, "the span stays frozen across moves")
        XCTAssertTrue(pointer.state.showsHelpTag)
    }

    @MainActor
    func testForcedPositionInACondensedRailUsesItsBand() {
        let pointer = RailPointerModel()
        pointer.noteContainerSize(CGSize(width: 1000, height: 368))
        pointer.slots = DeckRail.slots(forHeight: DeckRail.compactTwoHeight) ?? []
        XCTAssertEqual(pointer.slots.count, 14)
        XCTAssertEqual(pointer.railFit?.count, 14)
        XCTAssertTrue(pointer.force(letter: "M", reduceMotion: false))
        // A to Z every other letter: M is the 7th slot, mid-band. Slot 6 holds
        // Y and Z at a 20 pt pitch; the band's middle is a quarter in.
        let pitch = pointer.railFit?.pitch ?? 20
        guard case .hovering(_, let y) = pointer.state else { return XCTFail("M should hover") }
        XCTAssertEqual(y, 6 * pitch + pitch / 4, accuracy: 0.001)
    }
}
