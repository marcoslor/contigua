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

    // MARK: The e2e's forced position

    @MainActor
    func testForcedPositionResolvesALetterToItsBand() {
        let pointer = RailPointerModel()
        pointer.slots = DeckRail.slots(forHeight: DeckRail.minimumHeight) ?? []
        XCTAssertTrue(pointer.force(letter: "M", dx: 40, reduceMotion: false))
        XCTAssertEqual(pointer.state, .approaching(dx: 40, y: 250),
                       "M is the 13th of 27 slots at a 20 pt pitch")
        XCTAssertFalse(pointer.force(letter: "?", dx: 0, reduceMotion: false), "only a real letter is a position")
        XCTAssertTrue(pointer.force(letter: "M", dx: 0, reduceMotion: false))
        XCTAssertEqual(pointer.state, .hovering(y: 250), "dx zero is inside the rail")
    }

    @MainActor
    func testForcedPositionInACondensedRailUsesItsBand() {
        let pointer = RailPointerModel()
        pointer.slots = DeckRail.slots(forHeight: DeckRail.compactTwoHeight) ?? []
        XCTAssertEqual(pointer.slots.count, 14)
        XCTAssertTrue(pointer.force(letter: "M", dx: 0, reduceMotion: false))
        // A to Z every other letter: M is the 7th slot, mid-band at 20 pt.
        XCTAssertEqual(pointer.state, .hovering(y: 125))
    }
}
