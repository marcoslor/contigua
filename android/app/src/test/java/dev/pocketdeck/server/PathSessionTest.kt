package dev.pocketdeck.server

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** docs/design/paths.md §6: every state/event pair, ignored events, every timer. */
class PathSessionTest {
    private fun machine(
        live: Set<String> = setOf("a"),
        current: String = "a",
        ended: String? = null,
        orphanedSince: Double? = null,
    ): PathSessionMachine = if (ended != null) {
        PathSessionMachine(state = PathSessionState.Ended(ended))
    } else if (orphanedSince != null) {
        PathSessionMachine(state = PathSessionState.Orphaned(orphanedSince))
    } else {
        PathSessionMachine(
            state = PathSessionState.Live(current),
            live = live.toMutableSet(),
            scores = live.associateWith { 500 }.toMutableMap(),
        )
    }

    @Test
    fun pathUpAddsAPathAndStartsItsPing() {
        val m = machine()
        val actions = m.handle(PathSessionEvent.PathUp("b", joined = true), 10.0)
        assertEquals(PathSessionState.Live("a"), m.state)
        assertTrue(m.live.contains("b"))
        assertEquals(
            listOf(
                PathSessionAction.StartPing("b"),
                PathSessionAction.Ranking(PathRankingEvent.PathUp("b")),
            ),
            actions,
        )
    }

    @Test
    fun aSecondPathUpForALivePathClosesTheSecondSocket() {
        val m = machine()
        assertEquals(
            listOf(PathSessionAction.ClosePath("a")),
            m.handle(PathSessionEvent.PathUp("a", joined = true), 10.0),
        )
    }

    @Test
    fun aPathUpAfterTheEndIsIgnored() {
        val m = machine(ended = "close")
        assertEquals(
            listOf(PathSessionAction.Ignore),
            m.handle(PathSessionEvent.PathUp("b", joined = false), 1.0),
        )
    }

    @Test
    fun aPlannedPeerSwitchMigratesAndKeepsTheOldPathAsStandby() {
        val m = machine(live = setOf("a", "b"))
        val actions = m.handle(PathSessionEvent.PeerSwitch("b", 9, "a"), 20.0)
        assertEquals(PathSessionState.Migrating("a", "b", 20.0), m.state)
        assertEquals(
            listOf(
                PathSessionAction.StartPing("b"),
                PathSessionAction.Ranking(PathRankingEvent.ExternalSwitch("b")),
            ),
            actions,
        )
        assertEquals(
            listOf(PathSessionAction.Ranking(PathRankingEvent.ExternalSwitch("b"))),
            m.handle(PathSessionEvent.PeerSwitch("b", 3, "b"), 20.1),
        )
        assertEquals(PathSessionState.Live("b"), m.state)
        assertEquals("E-3: the old path stays attached as a standby", true, m.live.contains("a"))
    }

    /** E-3/RR-3: the Mac decides a path's life; a marker arriving on the new
     * path moves our sending path and leaves the old one a standby, never
     * closed (the Mac's demoted path, its pings and its margin win-back were
     * dying on a real phone). */
    @Test
    fun aPeerSwitchArrivingOnTheNewPathKeepsTheOldPathAsStandby() {
        val m = machine(live = setOf("a", "b"))
        val actions = m.handle(PathSessionEvent.PeerSwitch("b", 9, "b"), 3.0)
        assertEquals(PathSessionState.Live("b"), m.state)
        assertTrue("the old path stays attached as a standby", m.live.contains("a"))
        assertEquals(
            listOf(
                PathSessionAction.StartPing("b"),
                PathSessionAction.Ranking(PathRankingEvent.ExternalSwitch("b")),
            ),
            actions,
        )
    }

    @Test
    fun aMarkerForAnUnknownPathIsIgnored() {
        val m = machine()
        assertEquals(
            listOf(PathSessionAction.Ignore),
            m.handle(PathSessionEvent.PeerSwitch("zz", 1, "a"), 0.0),
        )
    }

    @Test
    fun theCurrentPathFailingSwitchesAtOnce() {
        val m = machine(live = setOf("a", "b"))
        m.scores["a"] = 100
        m.scores["b"] = 900
        val actions = m.handle(PathSessionEvent.CurrentFailed("a"), 5.0)
        assertEquals(PathSessionState.Migrating("a", "b", 5.0), m.state)
        assertFalse("a socket error fails the path", m.live.contains("a"))
        assertEquals(
            listOf(
                PathSessionAction.StopPing("a"),
                PathSessionAction.SwitchTo("b"),
                PathSessionAction.RequestKeyframes,
                PathSessionAction.StartPing("b"),
                PathSessionAction.Ranking(PathRankingEvent.CurrentFailed("a")),
            ),
            actions,
        )
    }

    @Test
    fun currentFailedWithNoOtherPathOrphansAndSaysReconnecting() {
        val m = machine()
        val actions = m.handle(PathSessionEvent.CurrentFailed("a"), 7.0)
        assertEquals(PathSessionState.Orphaned(7.0), m.state)
        assertTrue(actions.contains(PathSessionAction.MarkReconnecting))
        assertFalse(actions.contains(PathSessionAction.SwitchTo("a")))
    }

    /** PATH-7: the 1.5 s rule is for two or more paths. On the only path a
     * lost pong is a ranking sample, not a failure: no switch, no reconnect. */
    @Test
    fun oneLostPongOnTheOnlyPathStaysLive() {
        val m = machine()
        assertEquals(emptyList<PathSessionAction>(), m.handle(PathSessionEvent.PongLost("a"), 2.0))
        assertEquals(PathSessionState.Live("a"), m.state)
        assertTrue(m.live.contains("a"))
        // A socket error still fails the only path.
        assertEquals(
            listOf(
                PathSessionAction.StopPing("a"),
                PathSessionAction.MarkReconnecting,
                PathSessionAction.Ranking(PathRankingEvent.CurrentFailed("a")),
            ),
            m.handle(PathSessionEvent.CurrentFailed("a"), 3.0),
        )
    }

    /** D-2/R-10: a pong-only failure demotes the current path to a standby; it
     * is not closed, stays pinged, and the phone never replays on it. */
    @Test
    fun aLostPongDemotesTheCurrentPathToStandbyWithoutClosingIt() {
        val m = machine(live = setOf("a", "b"))
        m.scores["a"] = 100
        m.scores["b"] = 900
        val actions = m.handle(PathSessionEvent.PongLost("a"), 4.0)
        assertEquals(PathSessionState.Live("b"), m.state)
        assertTrue("the demoted path stays open and pinged", m.live.contains("a"))
        assertFalse(actions.any { it is PathSessionAction.ClosePath })
        assertFalse(actions.contains(PathSessionAction.ReplayFromLastAck))
        assertEquals(listOf(PathSessionAction.Ranking(PathRankingEvent.CurrentFailed("a"))), actions)
    }

    /** D-2: a path that is still delivering bytes is alive; its lost pong is a
     * ranking sample, so the current path keeps its role. */
    @Test
    fun aPongLostCurrentPathWithFreshInboundKeepsItsRole() {
        val m = machine(live = setOf("a", "b"))
        assertEquals(null, pongFailure(PathHub.PongLoss("a", alive = true), "a"))
        assertEquals(PathSessionState.Live("a"), m.state)
        assertEquals(null, pongFailure(PathHub.PongLoss("b", alive = false), "a"))
        assertEquals(PathSessionEvent.PongLost("a"), pongFailure(PathHub.PongLoss("a", alive = false), "a"))
    }

    /** R-10: the phone's health decisions never replay; only followSwitch does. */
    @Test
    fun thePhoneNeverReplaysOnItsOwnHealthDecisions() {
        for (event in listOf(
            PathSessionEvent.PongLost("a"),
            PathSessionEvent.CurrentFailed("a"),
            PathSessionEvent.PathDown("a"),
        )) {
            val m = machine(live = setOf("a", "b"))
            val actions = m.handle(event, 1.0)
            assertFalse("$event emitted a replay", actions.contains(PathSessionAction.ReplayFromLastAck))
        }
    }

    @Test
    fun aLostPongForAStandbyPathIsOnlyASample() {
        val m = machine(live = setOf("a", "b"))
        assertEquals(emptyList<PathSessionAction>(), m.handle(PathSessionEvent.PongLost("b"), 1.0))
        assertEquals(PathSessionState.Live("a"), m.state)
    }

    @Test
    fun aLostPongOnTheNewPathDuringMigrationFallsBack() {
        val m = PathSessionMachine(
            state = PathSessionState.Migrating("a", "b", 1.0),
            live = mutableSetOf("a", "b"),
            scores = mutableMapOf("a" to 500, "b" to 500),
        )
        assertEquals(
            listOf(PathSessionAction.Ranking(PathRankingEvent.ExternalSwitch("a"))),
            m.handle(PathSessionEvent.PongLost("b"), 2.0),
        )
        assertEquals(PathSessionState.Live("a"), m.state)
    }

    /** Boot 6's grace: the drain left the migration's target as the only live
     * path and its pong stopped too. That is no usable path: the grace starts. */
    @Test
    fun aLostPongOnTheOnlyRemainingMigrationTargetOrphans() {
        val m = PathSessionMachine(
            state = PathSessionState.Migrating("a", "b", 1.0),
            live = mutableSetOf("b"),
            scores = mutableMapOf("b" to 500),
        )
        val actions = m.handle(PathSessionEvent.PongLost("b"), 4.0)
        assertEquals(PathSessionState.Orphaned(4.0), m.state)
        assertTrue(actions.contains(PathSessionAction.MarkReconnecting))
        assertFalse(actions.contains(PathSessionAction.SwitchTo("b")))
    }

    @Test
    fun thePongWatchIsTheMigrationTargetDuringASwitch() {
        assertEquals(
            "b",
            pongWatchPath(PathSessionState.Migrating("a", "b", 1.0), "a"),
        )
        assertEquals("a", pongWatchPath(PathSessionState.Live("a"), "a"))
        assertEquals("a", pongWatchPath(PathSessionState.Orphaned(1.0), "a"))
    }

    @Test
    fun aPathDownForAnotherPathKeepsTheSessionLive() {
        val m = machine(live = setOf("a", "b"))
        assertEquals(
            listOf(PathSessionAction.Ranking(PathRankingEvent.PathDown("b"))),
            m.handle(PathSessionEvent.PathDown("b"), 1.0),
        )
        assertEquals(PathSessionState.Live("a"), m.state)
    }

    @Test
    fun theGraceEndsTheSessionAtThirtySecondsNotBefore() {
        val m = machine(orphanedSince = 100.0)
        assertEquals(emptyList<PathSessionAction>(), m.handle(PathSessionEvent.GraceExpired, 129.9))
        assertEquals(PathSessionState.Orphaned(100.0), m.state)
        assertEquals(
            listOf(PathSessionAction.End("graceExpired")),
            m.handle(PathSessionEvent.GraceExpired, 130.0),
        )
        assertEquals(PathSessionState.Ended("graceExpired"), m.state)
    }

    @Test
    fun aJoinDuringTheGraceFoundTheLiveSessionAgain() {
        val m = machine(orphanedSince = 0.0)
        val actions = m.handle(PathSessionEvent.PathUp("b", joined = true), 12.0)
        assertEquals(PathSessionState.Live("b"), m.state)
        assertEquals(
            listOf(
                PathSessionAction.SwitchTo("b"),
                PathSessionAction.RequestKeyframes,
                PathSessionAction.StartPing("b"),
                PathSessionAction.Ranking(PathRankingEvent.PathUp("b")),
            ),
            actions,
        )
    }

    @Test
    fun pathDownDuringTheGraceStaysOrphaned() {
        val m = machine(orphanedSince = 1.0)
        assertEquals(
            listOf(PathSessionAction.Ranking(PathRankingEvent.PathDown("a"))),
            m.handle(PathSessionEvent.PathDown("a"), 2.0),
        )
        assertEquals(PathSessionState.Orphaned(1.0), m.state)
    }

    @Test
    fun theNewPathFailingDuringMigrationFallsBackToTheOldOne() {
        val m = machine(live = setOf("a", "b"))
        m.handle(PathSessionEvent.PeerSwitch("b", 1, "a"), 0.0)
        assertEquals(
            listOf(PathSessionAction.Ranking(PathRankingEvent.ExternalSwitch("a"))),
            m.handle(PathSessionEvent.PathDown("b"), 1.0),
        )
        assertEquals(PathSessionState.Live("a"), m.state)
    }

    @Test
    fun theNewPathFailingWithNothingElseOrphans() {
        val m = machine(live = setOf("a", "b"))
        m.handle(PathSessionEvent.PeerSwitch("b", 1, "a"), 0.0)
        m.live.remove("a")
        val actions = m.handle(PathSessionEvent.PathDown("b"), 1.0)
        assertEquals(PathSessionState.Orphaned(1.0), m.state)
        assertTrue(actions.contains(PathSessionAction.MarkReconnecting))
    }

    @Test
    fun closeEndsEveryLiveState() {
        val states = listOf(
            PathSessionState.Live("a"),
            PathSessionState.Migrating("a", "b", 0.0),
            PathSessionState.Orphaned(0.0),
        )
        for (s in states) {
            val m = PathSessionMachine(state = s, live = mutableSetOf("a", "b"))
            assertEquals(
                listOf(PathSessionAction.End("person")),
                m.handle(PathSessionEvent.Close("person"), 0.0),
            )
            assertEquals(PathSessionState.Ended("person"), m.state)
        }
    }

    @Test
    fun theEndedStateIgnoresEverything() {
        val m = machine(ended = "x")
        for (event in listOf(
            PathSessionEvent.PathDown("a"),
            PathSessionEvent.CurrentFailed("a"),
            PathSessionEvent.PeerSwitch("b", 1, "a"),
            PathSessionEvent.GraceExpired,
            PathSessionEvent.Close("y"),
        )) {
            assertEquals(listOf(PathSessionAction.Ignore), m.handle(event, 99.0))
        }
    }

    @Test
    fun theMachineLogsOnlyClosedTokens() {
        val m = machine()
        assertEquals("live a", m.describe())
        m.handle(PathSessionEvent.CurrentFailed("a"), 1.0)
        assertEquals("orphaned", m.describe())
    }

    @Test
    fun everyTransitionLogsAsPathsFromEventTo() {
        val before = PathSessionState.Live("a")
        assertEquals(
            "paths: live a --failed--> migrating a->b",
            PathSessionLog.line(before, PathSessionEvent.CurrentFailed("a"), PathSessionState.Migrating("a", "b", 1.0)),
        )
        assertEquals(
            "paths: live a --pong-lost--> live b",
            PathSessionLog.line(before, PathSessionEvent.PongLost("a"), PathSessionState.Live("b")),
        )
        assertEquals(
            "paths: live a --close--> ended person",
            PathSessionLog.line(before, PathSessionEvent.Close("person"), PathSessionState.Ended("person")),
        )
    }
}
