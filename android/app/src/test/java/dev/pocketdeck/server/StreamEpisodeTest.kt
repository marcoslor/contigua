package dev.pocketdeck.server

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The episode's lifetime (docs/specs/controls.md CTRL-14): every open app
 * stream keeps its display wake, a covered window stays in the set, and only
 * the last close or the all-paused grace ends the episode.
 */
class StreamEpisodeTest {

    private val a = 69
    private val b = 70

    private fun machine() = StreamEpisode {}

    private fun opened(machine: StreamEpisode, displays: Set<Int>, allPaused: Boolean = false) =
        machine.dispatch(EpisodeEvent.Streams(displays, allPaused))

    @Test
    fun `two streams open, one closes and the other display keeps its wake`() {
        val m = machine()
        assertEquals(
            listOf(EpisodeAction.Start, EpisodeAction.Hold(a), EpisodeAction.Hold(b)),
            opened(m, setOf(a, b)),
        )

        val actions = opened(m, setOf(a))

        assertEquals("only the closed stream's display loses its wake", listOf(EpisodeAction.Drop(b)), actions)
        assertTrue("the episode must still be active", m.state.active)
        assertEquals(EpisodePhase.LIVE, m.state.phase)
        assertEquals(setOf(a), m.state.displays)
    }

    @Test
    fun `a second stream opening keeps the first's display and does not restart the episode`() {
        val m = machine()
        opened(m, setOf(a))

        val actions = opened(m, setOf(a, b))

        assertEquals(listOf(EpisodeAction.Hold(b)), actions)
        assertFalse("an open is not an episode restart", actions.contains(EpisodeAction.Start))
        assertTrue(m.state.active)
    }

    @Test
    fun `the episode ends only when the last stream ends`() {
        val m = machine()
        opened(m, setOf(a, b))
        assertEquals(listOf(EpisodeAction.Drop(b)), opened(m, setOf(a)))

        val last = opened(m, emptySet())

        assertEquals(listOf(EpisodeAction.Drop(a), EpisodeAction.End), last)
        assertEquals(EpisodePhase.IDLE, m.state.phase)
        assertFalse(m.state.active)
    }

    @Test
    fun `a covered sibling stays in the episode when the visible one closes`() {
        val m = machine()
        opened(m, setOf(a, b))
        // The Mac covers b; a is still live, so the episode is not paused.
        assertEquals(emptyList<EpisodeAction>(), opened(m, setOf(a, b), allPaused = false))

        val actions = opened(m, setOf(b), allPaused = true)

        assertFalse("the covered window keeps the episode alive", actions.contains(EpisodeAction.End))
        assertEquals(EpisodePhase.PAUSED, m.state.phase)
        assertEquals(setOf(b), m.state.displays)
    }

    @Test
    fun `every window covered pauses, and a resume inside the grace does not restart`() {
        val m = machine()
        opened(m, setOf(a))
        val paused = opened(m, setOf(a), allPaused = true)
        assertEquals(listOf(EpisodeAction.Pause), paused)

        val resumed = opened(m, setOf(a))
        assertEquals(listOf(EpisodeAction.Resume), resumed)
        assertEquals(EpisodePhase.LIVE, m.state.phase)
        assertEquals(setOf(a), m.state.displays)
    }

    @Test
    fun `the grace ending releases every display and ends the episode`() {
        val m = machine()
        opened(m, setOf(a, b))
        // One window paused while the other is live is not the all-paused pause.
        opened(m, setOf(a, b), allPaused = false)
        opened(m, setOf(b), allPaused = true)

        val expired = m.dispatch(EpisodeEvent.GraceExpired)

        assertEquals(listOf(EpisodeAction.Drop(b), EpisodeAction.End), expired)
        assertEquals(EpisodePhase.IDLE, m.state.phase)
        assertFalse(m.state.active)
    }

    @Test
    fun `a grace expiry outside the pause is ignored`() {
        val m = machine()
        assertEquals(emptyList<EpisodeAction>(), m.dispatch(EpisodeEvent.GraceExpired))
        opened(m, setOf(a))
        assertEquals(emptyList<EpisodeAction>(), m.dispatch(EpisodeEvent.GraceExpired))
        assertTrue(m.state.active)
    }

    @Test
    fun `an empty set while idle changes nothing`() {
        val m = machine()
        assertEquals(emptyList<EpisodeAction>(), opened(m, emptySet()))
        assertEquals(EpisodePhase.IDLE, m.state.phase)
    }

    @Test
    fun `a first set that is already covered is not an episode start`() {
        val m = machine()
        val actions = opened(m, setOf(a), allPaused = true)
        assertFalse("a covered set must not take the phone over", actions.contains(EpisodeAction.Start))
        assertEquals(EpisodePhase.PAUSED, m.state.phase)
    }
}
