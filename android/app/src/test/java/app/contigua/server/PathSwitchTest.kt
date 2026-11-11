package app.contigua.server

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** docs/design/paths.md §5.4, PATH-5/9: the marker's order and the keyframes. */
class PathSwitchTest {

    /** E-3: the Mac closes a path it leaves; the phone keeps it a standby. */
    @Test
    fun aPlannedSwitchSendsTheMarkerOnTheOldPathAndNeverClosesIt() {
        val plan = PathSwitch.plan(PathSwitchKind.PLANNED, "aaa", "bbb", 42, listOf(1, 2))
        assertEquals(
            listOf(
                PathSwitchStep.Marker("aaa", 42),
                PathSwitchStep.ReplayFromLastAck,
                PathSwitchStep.RequestKeyframe(1),
                PathSwitchStep.RequestKeyframe(2),
            ),
            plan,
        )
    }

    @Test
    fun anUnplannedSwitchSendsTheMarkerFirstOnTheNewPath() {
        val plan = PathSwitch.plan(PathSwitchKind.UNPLANNED, "aaa", "bbb", 7, listOf(3))
        assertEquals(PathSwitchStep.Marker("bbb", 7), plan.first())
    }

    @Test
    fun aMarkerForAnUnknownPathIsIgnored() {
        assertTrue(PathSwitch.accepts("aaa", setOf("aaa", "bbb")))
        assertFalse(PathSwitch.accepts("ccc", setOf("aaa", "bbb")))
    }

    @Test
    fun oneKeyframeRequestPerOpenStream() {
        assertEquals(
            0,
            PathSwitch.plan(PathSwitchKind.PLANNED, "a", "b", 1, emptyList())
                .count { it is PathSwitchStep.RequestKeyframe },
        )
        assertEquals(
            3,
            PathSwitch.plan(PathSwitchKind.UNPLANNED, "a", "b", 1, listOf(9, 8, 7))
                .count { it is PathSwitchStep.RequestKeyframe },
        )
    }
}
