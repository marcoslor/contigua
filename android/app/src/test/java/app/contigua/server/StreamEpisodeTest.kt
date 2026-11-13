package app.contigua.server

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The episode's lifetime (docs/specs/controls.md CTRL-14): every open app
 * stream keeps its display wake, a covered window stays in the set, and only
 * the last close or every window covered ends the episode.
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
    fun `a covered sibling keeps its wake while another window is live`() {
        val m = machine()
        opened(m, setOf(a, b))
        // The Mac covers b; a is still live, so nothing changes.
        assertEquals(emptyList<EpisodeAction>(), opened(m, setOf(a, b), allPaused = false))
        assertEquals(setOf(a, b), m.state.displays)
    }

    @Test
    fun `the visible window closing over a covered one ends the episode`() {
        val m = machine()
        opened(m, setOf(a, b))

        val actions = opened(m, setOf(b), allPaused = true)

        assertEquals(listOf(EpisodeAction.Drop(a), EpisodeAction.Drop(b), EpisodeAction.End), actions)
        assertEquals(EpisodePhase.IDLE, m.state.phase)
    }

    @Test
    fun `every window covered ends the episode, and one live again starts it`() {
        val m = machine()
        opened(m, setOf(a))
        assertEquals(listOf(EpisodeAction.Drop(a), EpisodeAction.End), opened(m, setOf(a), allPaused = true))
        assertFalse(m.state.active)

        val resumed = opened(m, setOf(a))

        assertEquals(listOf(EpisodeAction.Start, EpisodeAction.Hold(a)), resumed)
        assertEquals(EpisodePhase.LIVE, m.state.phase)
        assertEquals(setOf(a), m.state.displays)
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
        assertEquals(emptyList<EpisodeAction>(), opened(m, setOf(a), allPaused = true))
        assertEquals(EpisodePhase.IDLE, m.state.phase)
    }

    @Test
    fun `the step is pure`() {
        val s = EpisodeState(EpisodePhase.LIVE, setOf(a))
        val event = EpisodeEvent.Streams(setOf(a, b), allPaused = false)
        assertEquals(episodeStep(s, event), episodeStep(s, event))
        assertEquals(EpisodeState(EpisodePhase.LIVE, setOf(a)), s)
    }
}
