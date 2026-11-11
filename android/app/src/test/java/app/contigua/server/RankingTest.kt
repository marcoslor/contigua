package app.contigua.server

import app.contigua.proto.PathKind
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** docs/design/paths.md §7: the terms, the worked example and the machine. */
class RankingTest {

    @Test
    fun theFormulaTermsAtTheirBoundaries() {
        assertEquals(1000, PathRanking.score(0.0, 0.0, 0.0, 209))
        assertEquals(775, PathRanking.score(10.0, 10.0, 0.0, 209))
        assertEquals(800, PathRanking.score(0.0, 0.0, 0.10, 209))
        assertEquals(800, PathRanking.score(0.0, 0.0, 0.50, 209))
        assertEquals(925, PathRanking.score(0.0, 25.0, 0.0, 209))
        assertEquals(800, PathRanking.score(0.0, 0.0, 0.0, 0))
    }

    @Test
    fun theWorkedExample() {
        assertEquals(722, PathRanking.score(5.5, 8.0, 0.0, 100))
        assertEquals(463, PathRanking.score(13.0, 39.8, 0.0065, 8))
        assertEquals(412, PathRanking.score(30.0, 90.0, 0.02, 100))
        assertEquals(321, PathRanking.score(40.0, 120.0, 0.05, 100))
        assertTrue(463 - 412 < PathRanking.MARGIN)
        assertTrue(463 - 321 >= PathRanking.MARGIN)
    }

    private fun feed(
        ranking: PathRanking,
        id: String,
        rtt: Double,
        at: Double,
        pings: Int = 2,
        lost: Int = 0,
        kind: PathKind = PathKind.LAN,
    ) {
        ranking.register(id, kind)
        for (i in 0 until pings) {
            ranking.addSample(id, if (i < pings - lost) rtt else null, at)
        }
    }

    @Test
    fun theFirstTickWithPongsElectsTheRealSessionsCurrentPath() {
        // PathUp arrives before the first pong can: the ranking must not stay
        // idle forever (the founder becomes current on the first tick with a
        // ranked path).
        val r = PathRanking()
        r.register("lan", PathKind.LAN)
        assertTrue(r.handle(PathRankingEvent.PathUp("lan"), 0.0).isEmpty())
        assertEquals(PathRankingState.Idle, r.state)
        feed(r, "lan", 5.5, 2.0)
        assertEquals(emptyList<PathRankingAction>(), r.handle(PathRankingEvent.Tick(2.0), 2.0))
        assertEquals(PathRankingState.Steady("lan"), r.state)
    }

    @Test
    fun aHealthyCurrentPathKeepsTheMarginAndDoesNotSwitch() {
        val r = PathRanking()
        feed(r, "lan", 5.5, 0.0)
        r.handle(PathRankingEvent.PathUp("lan"), 0.0)
        feed(r, "direct", 13.0, 0.0, kind = PathKind.DIRECT)
        assertEquals(PathRankingState.Steady("lan"), r.state)
        assertEquals(emptyList<PathRankingAction>(), r.handle(PathRankingEvent.Tick(6.0), 6.0))
        assertEquals(PathRankingState.Steady("lan"), r.state)
    }

    @Test
    fun aFullMarginChallengeSwitchesOnlyAfterFiveSeconds() {
        val r = PathRanking()
        feed(r, "slow", 1000.0, 0.0)
        r.handle(PathRankingEvent.PathUp("slow"), 0.0)
        feed(r, "fast", 1.0, 0.0)
        assertEquals(PathRankingState.Steady("slow"), r.state)
        assertEquals(emptyList<PathRankingAction>(), r.handle(PathRankingEvent.Tick(10.0), 10.0))
        assertEquals(PathRankingState.Challenging("slow", "fast", 10.0), r.state)
        assertEquals(emptyList<PathRankingAction>(), r.handle(PathRankingEvent.Tick(14.9), 14.9))
        assertEquals(listOf(PathRankingAction.SwitchTo("fast")), r.handle(PathRankingEvent.Tick(15.0), 15.0))
        assertEquals(PathRankingState.Steady("fast"), r.state)
    }

    @Test
    fun theChallengeRestartsWhenTheChallengerLeaves() {
        val r = PathRanking()
        feed(r, "slow", 1000.0, 0.0)
        r.handle(PathRankingEvent.PathUp("slow"), 0.0)
        feed(r, "fast", 1.0, 0.0)
        r.handle(PathRankingEvent.Tick(10.0), 10.0)
        assertEquals(emptyList<PathRankingAction>(), r.handle(PathRankingEvent.PathDown("fast"), 12.0))
        assertEquals(PathRankingState.Steady("slow"), r.state)
        feed(r, "fast", 1.0, 13.0)
        assertEquals(emptyList<PathRankingAction>(), r.handle(PathRankingEvent.Tick(14.0), 14.0))
        assertEquals(PathRankingState.Challenging("slow", "fast", 14.0), r.state)
    }

    @Test
    fun aFailureSwitchesAtOnceWithNoHysteresis() {
        val r = PathRanking()
        feed(r, "a", 5.0, 0.0)
        r.handle(PathRankingEvent.PathUp("a"), 0.0)
        feed(r, "b", 50.0, 0.0)
        assertEquals(listOf(PathRankingAction.SwitchTo("b")), r.handle(PathRankingEvent.CurrentFailed("a"), 1.0))
        assertEquals(PathRankingState.Steady("b"), r.state)
    }

    @Test
    fun aFailureWithNoLivePathAsksTheSessionToOrphan() {
        val r = PathRanking()
        feed(r, "a", 5.0, 0.0)
        r.handle(PathRankingEvent.PathUp("a"), 0.0)
        assertEquals(listOf(PathRankingAction.SessionOrphan), r.handle(PathRankingEvent.CurrentFailed("a"), 1.0))
        assertEquals(PathRankingState.Idle, r.state)
    }

    @Test
    fun anUnrankablePathNeverWinsOnMargin() {
        val r = PathRanking()
        feed(r, "a", 1000.0, 0.0)
        r.register("b")
        r.addSample("b", 0.0, 0.0)
        assertNull(r.score("b", 0.0))
        r.handle(PathRankingEvent.PathUp("a"), 0.0)
        var tick = 1.0
        while (tick <= 20.0) {
            assertEquals(emptyList<PathRankingAction>(), r.handle(PathRankingEvent.Tick(tick), tick))
            tick += 1.0
        }
        assertEquals(PathRankingState.Steady("a"), r.state)
    }

    @Test
    fun anExternalSwitchMovesTheRankingAtOnce() {
        val r = PathRanking()
        feed(r, "a", 5.0, 0.0)
        r.handle(PathRankingEvent.PathUp("a"), 0.0)
        feed(r, "b", 50.0, 0.0)
        assertEquals(emptyList<PathRankingAction>(), r.handle(PathRankingEvent.ExternalSwitch("b"), 1.0))
        assertEquals(PathRankingState.Steady("b"), r.state)
    }

    @Test
    fun theWindowPrunesSamplesOlderThanThirtySeconds() {
        val r = PathRanking()
        r.register("a")
        r.addSample("a", 5.0, 0.0)
        r.addSample("a", 5.0, 31.0)
        assertNull(r.score("a", 31.0))
        r.addSample("a", 5.0, 32.0)
        assertTrue(r.score("a", 32.0) != null)
    }
}
