package app.contigua.server

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * K1 for the still-screen heartbeat (WIN-17, PHONE-21).
 *
 * The field bug: a healthy but still Contacts window showed "Not responding"
 * about 15 s after it opened. The phone's vendor encoder dropped
 * `KEY_REPEAT_PREVIOUS_FRAME_AFTER` on a static picture (no output while the
 * input was static), and a sync-frame request is applied to a next input frame
 * that never comes. So a live stream says `window.still` instead.
 */
class IdleFrameWatchdogTest {

    /**
     * A still screen: the drain loop's 10 ms poll and the machine. The fake
     * encoder produces no output at all while its input stays static; only a
     * real drawn frame would move the clock.
     */
    private class StillScreen {
        var model = IdleFrameWatchdogModel()
            private set

        /** When each `window.still` would have gone out. */
        val stillsMs = ArrayList<Long>()
        private var now = 0L

        fun start() = step(IdleFrameWatchdogEvent.Live(now))

        fun frame(keyframe: Boolean = true) = step(IdleFrameWatchdogEvent.Frame(now, keyframe))

        fun pause() = step(IdleFrameWatchdogEvent.Pause)

        fun resume() = step(IdleFrameWatchdogEvent.Resume(now))

        fun close() = step(IdleFrameWatchdogEvent.Close)

        /** Advances the drain's poll up to [ms] later, one tick every [pollMs]. */
        fun advance(ms: Long, pollMs: Long = 10L) {
            val end = now + ms
            while (now < end) {
                now = minOf(now + pollMs, end)
                step(IdleFrameWatchdogEvent.Tick(now))
            }
        }

        /** Time passes with no poll: a stuck drain loop takes no output. */
        fun stalledFor(ms: Long) {
            now += ms
        }

        private fun step(event: IdleFrameWatchdogEvent) {
            val result = idleFrameWatchdogTransition(model, event)
            model = result.model
            repeat(result.actions.count { it == IdleFrameWatchdogAction.SendStill }) {
                stillsMs += now
            }
        }
    }

    @Test
    fun aStillScreenTellsTheMacItIsAliveEverySecond() {
        val screen = StillScreen()
        screen.start()
        screen.frame()
        screen.advance(30_000)

        val stills = screen.stillsMs
        assertTrue(
            "a still screen said nothing: the Mac's 1.5 s rule (WIN-17) calls it stalled",
            stills.isNotEmpty(),
        )
        var previous = 0L
        for (at in stills) {
            val gap = at - previous
            assertTrue("still gap ${gap}ms at ${at}ms is outside 1000-1200", gap in 1_000L..1_200L)
            previous = at
        }
        assertEquals("one still a second for 30 s of a silent screen", 30, stills.size)
        assertEquals(30, screen.model.stills)
        assertEquals(IdleFrameWatchdogState.Still, screen.model.state)
    }

    @Test
    fun aPausedOrCoveredStreamSendsNoStill() {
        val screen = StillScreen()
        screen.start()
        screen.frame()
        screen.advance(500)
        // The Mac's occlusion rule sends `window.pause` for a covered window.
        screen.pause()
        screen.advance(5_000)
        assertEquals("a paused stream sends nothing on purpose", 0, screen.stillsMs.size)
        assertEquals(IdleFrameWatchdogState.Idle, screen.model.state)
        screen.frame()
        assertEquals("a frame while paused does not arm it", IdleFrameWatchdogState.Idle, screen.model.state)
    }

    @Test
    fun aResumedStreamSaysStillAgainAfterOneSecond() {
        val screen = StillScreen()
        screen.start()
        screen.frame()
        screen.pause()
        screen.advance(3_000)
        screen.resume()
        screen.advance(1_000)
        assertEquals(listOf(4_000L), screen.stillsMs)
        screen.advance(1_000)
        assertEquals(listOf(4_000L, 5_000L), screen.stillsMs)
    }

    @Test
    fun aClosedStreamStopsTheWatchdog() {
        val screen = StillScreen()
        screen.start()
        screen.frame()
        screen.advance(500)
        screen.close()
        screen.advance(10_000)
        assertEquals(0, screen.stillsMs.size)
        assertEquals(IdleFrameWatchdogState.Closed, screen.model.state)
        screen.start()
        screen.frame()
        screen.advance(5_000)
        assertEquals("a closed stream stays closed", 0, screen.stillsMs.size)
        assertEquals(IdleFrameWatchdogState.Closed, screen.model.state)
    }

    @Test
    fun aStuckDrainSendsNeitherFramesNorStill() {
        val screen = StillScreen()
        screen.start()
        screen.frame()
        screen.advance(500)
        // The encoder or the drain loop hangs: no output and no poll, so the
        // stream cannot claim to be alive. The Mac's 1.5 s rule fires.
        screen.stalledFor(30_000)
        assertEquals(0, screen.stillsMs.size)
        assertEquals(IdleFrameWatchdogState.Armed, screen.model.state)
    }

    @Test
    fun aFrameRearmsTheOneSecondClock() {
        var model = IdleFrameWatchdogModel()
        model = idleFrameWatchdogTransition(model, IdleFrameWatchdogEvent.Live(0)).model
        model = idleFrameWatchdogTransition(model, IdleFrameWatchdogEvent.Frame(600, keyframe = false)).model
        assertEquals(
            "an ordinary frame moves the deadline with it",
            emptyList<IdleFrameWatchdogAction>(),
            idleFrameWatchdogTransition(model, IdleFrameWatchdogEvent.Tick(1_500)).actions,
        )
        assertEquals(
            listOf(IdleFrameWatchdogAction.SendStill),
            idleFrameWatchdogTransition(model, IdleFrameWatchdogEvent.Tick(1_600)).actions,
        )
    }

    @Test
    fun eventsEachStateIgnoresChangeNothing() {
        val idle = IdleFrameWatchdogModel()
        fun modelAfter(model: IdleFrameWatchdogModel, event: IdleFrameWatchdogEvent) =
            idleFrameWatchdogTransition(model, event)

        // Idle: only a live/resumed stream arms it.
        for (event in listOf(
            IdleFrameWatchdogEvent.Tick(9_000),
            IdleFrameWatchdogEvent.Frame(9_000, keyframe = true),
            IdleFrameWatchdogEvent.Close,
        )) {
            assertEquals(idle, modelAfter(idle, event).model)
            assertEquals(emptyList<IdleFrameWatchdogAction>(), modelAfter(idle, event).actions)
        }
        val paused = idleFrameWatchdogTransition(idle, IdleFrameWatchdogEvent.Pause).model
        assertEquals(idle, paused)

        // Armed/Still ignore a second live.
        val armed = modelAfter(idle, IdleFrameWatchdogEvent.Live(0)).model
        assertEquals(armed, modelAfter(armed, IdleFrameWatchdogEvent.Live(500)).model)
        val still = modelAfter(armed, IdleFrameWatchdogEvent.Tick(1_000)).model
        assertEquals(IdleFrameWatchdogState.Still, still.state)
        assertEquals(still, modelAfter(still, IdleFrameWatchdogEvent.Live(1_500)).model)

        // Closed is terminal for every event.
        val closed = modelAfter(armed, IdleFrameWatchdogEvent.Close).model
        for (event in listOf(
            IdleFrameWatchdogEvent.Live(2_000),
            IdleFrameWatchdogEvent.Frame(2_000, keyframe = true),
            IdleFrameWatchdogEvent.Tick(9_000),
            IdleFrameWatchdogEvent.Pause,
            IdleFrameWatchdogEvent.Resume(2_000),
            IdleFrameWatchdogEvent.Close,
        )) {
            assertEquals(closed, modelAfter(closed, event).model)
            assertEquals(emptyList<IdleFrameWatchdogAction>(), modelAfter(closed, event).actions)
        }
    }
}
