// The rail's approach zone (DECK-7): the letter near the pointer grows from rest
// at the zone's outer edge to its full magnification at the rail. The pointer
// itself is a four-state machine, tested here for every event it accepts and
// every event it must ignore.

import XCTest
@testable import PocketDeck

final class RailApproachTests: XCTestCase {
    private let eps: CGFloat = 0.0001
    private var zone: CGFloat { RailApproach.zone }

    func testTheApproachZoneIsOneIconColumn() {
        XCTAssertEqual(RailApproach.zone, 64, "A2: about one 96 pt icon column")
        XCTAssertGreaterThan(RailApproach.zone, 0)
    }

    func testScaleTapersToRestAcrossTheZone() {
        let peak = RailFisheye.scale(distance: 0, dx: 0, zone: zone, reduceMotion: false)
        XCTAssertEqual(peak, RailFisheye.scale(distance: 0, reduceMotion: false),
                       "inside the rail the letter keeps its full magnification")
        XCTAssertEqual(RailFisheye.scale(distance: 0, dx: zone, zone: zone, reduceMotion: false), 1,
                       accuracy: eps, "at the zone's outer edge the letter is at rest")
        let mid = RailFisheye.scale(distance: 0, dx: zone / 2, zone: zone, reduceMotion: false)
        XCTAssertGreaterThan(mid, 1, "halfway in the letter has begun to grow")
        XCTAssertLessThan(mid, peak, "halfway in it is not yet at full size")
        XCTAssertEqual(mid, 1 + (peak - 1) / 2, accuracy: eps,
                       "the ramp is smoothstep(1 - dx/zone), 0.5 at half a zone")
    }

    func testScaleIsMonotonicAsThePointerApproaches() {
        var previous: CGFloat = 0
        for dx in stride(from: zone, through: 0, by: -4) {
            let scale = RailFisheye.scale(distance: 0, dx: dx, zone: zone, reduceMotion: false)
            XCTAssertGreaterThanOrEqual(scale, previous, "closer to the rail never shrinks the letter (dx \(dx))")
            previous = scale
        }
        XCTAssertEqual(previous, RailFisheye.scale(distance: 0, reduceMotion: false))
    }

    func testScaleOutsideTheZoneAndInsideTheRailClamp() {
        let peak = RailFisheye.scale(distance: 0, reduceMotion: false)
        XCTAssertEqual(RailFisheye.scale(distance: 0, dx: 120, zone: zone, reduceMotion: false), 1,
                       accuracy: eps, "past the zone's edge nothing grows")
        XCTAssertEqual(RailFisheye.scale(distance: 0, dx: -10, zone: zone, reduceMotion: false), peak,
                       accuracy: eps, "negative dx means the pointer is inside the rail")
        XCTAssertEqual(RailFisheye.scale(distance: 0, dx: 0, zone: 0, reduceMotion: false), peak,
                       accuracy: eps, "a zero zone falls back to on/off magnification")
        XCTAssertEqual(RailFisheye.scale(distance: 0, dx: 1, zone: 0, reduceMotion: false), 1,
                       accuracy: eps, "one point off a zero zone is rest")
    }

    func testNeighbourTaperFollowsTheRamp() {
        let peak = RailFisheye.scale(distance: 1, dx: 0, zone: zone, reduceMotion: false)
        let mid = RailFisheye.scale(distance: 1, dx: zone / 2, zone: zone, reduceMotion: false)
        XCTAssertLessThan(mid, peak)
        XCTAssertGreaterThan(mid, 1)
        XCTAssertEqual(RailFisheye.scale(distance: 1, dx: zone, zone: zone, reduceMotion: false), 1,
                       accuracy: eps)
    }

    func testReduceMotionKeepsEveryLetterAtRest() {
        for dx in [CGFloat(0), 8, 32, 64, 96] {
            for distance in [CGFloat(0), 0.5, 1, 2] {
                XCTAssertEqual(RailFisheye.scale(distance: distance, dx: dx, zone: zone, reduceMotion: true),
                               1, "Reduce Motion has no fisheye (dx \(dx), distance \(distance))")
            }
        }
    }

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
        let point = RailApproach.railPoint(hover: hover, container: container, fit: drawnFit, trailing: 44)
        XCTAssertEqual(point.y, 12.5 * drawnFit.pitch, accuracy: 0.01,
                       "M's drawn centre must read as M's row")
        XCTAssertEqual(point.dx, 0, accuracy: 0.01, "inside the rail")
    }

    func testRailPointMeasuresDxFromTheRailsLeadingEdge() {
        let container = CGSize(width: 1000, height: 573)
        let leading = container.width - 44
        let hover = CGPoint(x: leading - 40, y: 200)
        XCTAssertEqual(RailApproach.railPoint(hover: hover, container: container, fit: drawnFit, trailing: 44).dx,
                       40, accuracy: 0.01)
        let inside = CGPoint(x: leading + 5, y: 200)
        XCTAssertEqual(RailApproach.railPoint(hover: inside, container: container, fit: drawnFit, trailing: 44).dx,
                       0, accuracy: 0.01)
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

    // MARK: The pointer state machine

    private func reduce(_ state: RailPointer, _ event: RailPointerEvent,
                        zone: CGFloat? = nil, reduceMotion: Bool = false)
        -> (RailPointer, [RailPointerAction]) {
        RailPointer.reduce(state, event: event, zone: zone ?? RailApproach.zone,
                           reduceMotion: reduceMotion)
    }

    func testTrackEntersApproachingThenHovering() {
        let (approach, actions) = reduce(.away, .track(dx: 40, y: 100))
        XCTAssertEqual(approach, .approaching(dx: 40, y: 100))
        XCTAssertTrue(actions.isEmpty, "approaching does not animate")
        let (hover, hoverActions) = reduce(approach, .track(dx: 0, y: 120))
        XCTAssertEqual(hover, .hovering(y: 120))
        XCTAssertTrue(hoverActions.isEmpty)
        let (back, _) = reduce(hover, .track(dx: 20, y: 110))
        XCTAssertEqual(back, .approaching(dx: 20, y: 110), "moving back out of the rail approaches again")
    }

    func testTrackPastTheZoneLeavesAndEasesBack() {
        let (state, actions) = reduce(.hovering(y: 100), .track(dx: RailApproach.zone + 1, y: 100))
        XCTAssertEqual(state, .away)
        XCTAssertEqual(actions, [.animateRest(duration: 0.12)])
    }

    func testLeaveEasesBackOnce() {
        let (hovering, actions) = reduce(.hovering(y: 100), .leave)
        XCTAssertEqual(hovering, .away)
        XCTAssertEqual(actions, [.animateRest(duration: 0.12)])
        let (approaching, approachingActions) = reduce(.approaching(dx: 10, y: 100), .leave)
        XCTAssertEqual(approaching, .away)
        XCTAssertEqual(approachingActions, [.animateRest(duration: 0.12)])
        let (away, awayActions) = reduce(.away, .leave)
        XCTAssertEqual(away, .away)
        XCTAssertTrue(awayActions.isEmpty, "already away leaves nothing to ease")
    }

    func testReduceMotionLeavesWithoutEasing() {
        let (state, actions) = reduce(.hovering(y: 100), .leave, reduceMotion: true)
        XCTAssertEqual(state, .away)
        XCTAssertEqual(actions, [.animateRest(duration: 0)], "Reduce Motion drops the 0.12 s ease")
    }

    func testPressOnlyStartsADragFromHovering() {
        let (dragging, actions) = reduce(.hovering(y: 50), .press(y: 52))
        XCTAssertEqual(dragging, .dragging(y: 52))
        XCTAssertTrue(actions.isEmpty)
        for state in [RailPointer.away, .approaching(dx: 20, y: 50)] {
            XCTAssertEqual(reduce(state, .press(y: 50)).0, state,
                           "a press cannot start outside the rail (\(state))")
        }
        XCTAssertEqual(reduce(.dragging(y: 10), .press(y: 20)).0, .dragging(y: 10),
                       "a second press does not restart the drag")
    }

    func testDragOnlyMovesWhileDragging() {
        XCTAssertEqual(reduce(.dragging(y: 10), .drag(y: 80)).0, .dragging(y: 80))
        XCTAssertEqual(reduce(.hovering(y: 10), .drag(y: 80)).0, .hovering(y: 10))
        XCTAssertEqual(reduce(.away, .drag(y: 80)).0, .away)
    }

    func testTrackIsIgnoredWhileDragging() {
        XCTAssertEqual(reduce(.dragging(y: 10), .track(dx: 0, y: 300)).0, .dragging(y: 10),
                       "the container's hover must not fight the drag")
        XCTAssertEqual(reduce(.dragging(y: 10), .track(dx: 200, y: 300)).0, .dragging(y: 10))
    }

    func testReleaseReturnsToHoveringOnlyAfterADrag() {
        XCTAssertEqual(reduce(.dragging(y: 10), .release(y: 60)).0, .hovering(y: 60))
        XCTAssertEqual(reduce(.hovering(y: 10), .release(y: 60)).0, .hovering(y: 10))
        XCTAssertEqual(reduce(.approaching(dx: 5, y: 10), .release(y: 60)).0,
                       .approaching(dx: 5, y: 10))
        XCTAssertEqual(reduce(.away, .release(y: 60)).0, .away)
    }

    func testThePointerPositionEachStateReports() {
        XCTAssertNil(RailPointer.away.position)
        XCTAssertEqual(RailPointer.approaching(dx: 12, y: 34).position?.y, 34)
        XCTAssertEqual(RailPointer.approaching(dx: 12, y: 34).position?.dx, 12)
        XCTAssertEqual(RailPointer.hovering(y: 34).position?.dx, 0,
                       "over the rail the distance left of its edge is zero")
        XCTAssertEqual(RailPointer.dragging(y: 34).position?.y, 34)
        XCTAssertFalse(RailPointer.approaching(dx: 12, y: 34).showsHelpTag,
                       "the tag belongs to hovering and dragging only")
        XCTAssertTrue(RailPointer.hovering(y: 1).showsHelpTag)
        XCTAssertTrue(RailPointer.dragging(y: 1).showsHelpTag)
    }

    /// The fit is never for more room than the container has: a live resize
    /// that shrinks it by less than a point must not keep a pitch whose
    /// magnified overshoot no longer fits (DECK-7, nothing clipped).
    @MainActor
    func testTheFitNeverOutgrowsTheContainer() {
        let pointer = RailPointerModel()
        for height in [573.0, 572.4, 571.9, 571.2] as [CGFloat] {
            pointer.noteContainerSize(CGSize(width: 1000, height: height))
            let fit = try? XCTUnwrap(pointer.railFit)
            let count = fit?.count ?? 0
            let pitch = fit?.pitch ?? 0
            let needed = CGFloat(count) * pitch + 2 * RailLayout.overshoot(count: count, pitch: pitch)
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
        XCTAssertTrue(pointer.force(letter: "M", dx: 40, reduceMotion: false))
        guard case .approaching(let dx, let y) = pointer.state else {
            return XCTFail("M should approach")
        }
        XCTAssertEqual(dx, 40)
        XCTAssertEqual(y, m, accuracy: 0.001, "M is the 13th of 27 slots at the drawn pitch")
        XCTAssertFalse(pointer.force(letter: "?", dx: 0, reduceMotion: false), "only a real letter is a position")
        XCTAssertTrue(pointer.force(letter: "M", dx: 0, reduceMotion: false))
        guard case .hovering(let hoverY) = pointer.state else {
            return XCTFail("dx zero is inside the rail")
        }
        XCTAssertEqual(hoverY, m, accuracy: 0.001)
    }

    @MainActor
    func testForcedPositionInACondensedRailUsesItsBand() {
        let pointer = RailPointerModel()
        pointer.noteContainerSize(CGSize(width: 1000, height: 368))
        pointer.slots = DeckRail.slots(forHeight: DeckRail.compactTwoHeight) ?? []
        XCTAssertEqual(pointer.slots.count, 14)
        XCTAssertEqual(pointer.railFit?.count, 14)
        XCTAssertTrue(pointer.force(letter: "M", dx: 0, reduceMotion: false))
        // A to Z every other letter: M is the 7th slot, mid-band at its pitch.
        // Slot 6 holds Y and Z at a 20 pt pitch; the band's middle is a quarter in.
        let pitch = pointer.railFit?.pitch ?? 20
        guard case .hovering(let y) = pointer.state else { return XCTFail("M should hover") }
        XCTAssertEqual(y, 6 * pitch + pitch / 4, accuracy: 0.001)
    }
}
