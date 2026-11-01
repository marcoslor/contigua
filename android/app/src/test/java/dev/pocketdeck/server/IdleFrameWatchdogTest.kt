package dev.pocketdeck.server

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * K1 for the still-screen heartbeat (WIN-17, PHONE-21).
 *
 * The field bug: a healthy but still Contacts window showed "Not responding"
 * about 15 s after it opened. The phone's vendor encoder dropped
 * `KEY_REPEAT_PREVIOUS_FRAME_AFTER` on a static picture (no output while the
 * input was static), so the Mac's 1.5 s rule fired. [VendorCodec] is that
 * encoder: it only makes a frame when a sync frame is asked for.
 */
class IdleFrameWatchdogTest {

    /** The vendor encoder: no output while its input stays static. */
    private class VendorCodec {
        val framesMs = ArrayList<Long>()
        var requestsMs = ArrayList<Long>()
        var stuck = false

        /** A sync request makes a keyframe at once, unless the encoder is stuck. */
        fun requestSync(nowMs: Long) {
            requestsMs += nowMs
            if (!stuck) framesMs += nowMs
        }
    }

    /** A still screen: the drain loop's 10 ms poll, the codec and the machine. */
    private class StillScreen(val codec: VendorCodec = VendorCodec()) {
        var model = IdleFrameWatchdogModel()
            private set
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

        private fun step(event: IdleFrameWatchdogEvent) {
            val result = idleFrameWatchdogTransition(model, event)
            model = result.model
            val asked = result.actions.count { it == IdleFrameWatchdogAction.RequestSyncFrame }
            repeat(asked) {
                codec.requestSync(now)
                // The answer arrives at the request: this is the fake codec's
                // whole point, a real encoder adds a few ms.
                if (!codec.stuck) {
                    model = idleFrameWatchdogTransition(
                        model,
                        IdleFrameWatchdogEvent.Frame(now, keyframe = true),
                    ).model
                }
            }
        }
    }

    @Test
    fun aStillScreenNeverSilencesTheMacForLongerThanTheWatchdog() {
        val screen = StillScreen()
        screen.start()
        screen.frame()
        screen.advance(30_000)

        val frames = screen.codec.framesMs
        assertTrue(
            "a still screen sent no frame at all: the Mac's 1.5 s rule (WIN-17) calls it stalled",
            frames.isNotEmpty(),
        )
        var previous = 0L
        for (at in frames) {
            val gap = at - previous
            assertTrue("frame gap ${gap}ms at ${at}ms is outside 1000-1200", gap in 1_000L..1_200L)
            previous = at
        }
        assertEquals("one keyframe a second for 30 s of a still screen", 30, frames.size)
        assertEquals(30, screen.model.idleFrames)
        assertEquals(30, screen.codec.requestsMs.size)
    }

    @Test
    fun aPausedOrCoveredStreamAsksForNothing() {
        val screen = StillScreen()
        screen.start()
        screen.frame()
        screen.advance(500)
        // The Mac's occlusion rule sends `window.pause` for a covered window.
        screen.pause()
        screen.advance(5_000)
        assertEquals("a paused stream sends nothing on purpose", 0, screen.codec.requestsMs.size)
        assertEquals(IdleFrameWatchdogState.Idle, screen.model.state)
        screen.frame()
        assertEquals("a frame while paused does not arm it", IdleFrameWatchdogState.Idle, screen.model.state)
    }

    @Test
    fun aResumedStreamAsksAgainAfterOneSecond() {
        val screen = StillScreen()
        screen.start()
        screen.frame()
        screen.pause()
        screen.advance(3_000)
        screen.resume()
        screen.advance(1_000)
        assertEquals(listOf(4_000L), screen.codec.requestsMs)
        screen.advance(1_000)
        assertEquals(listOf(4_000L, 5_000L), screen.codec.requestsMs)
    }

    @Test
    fun aClosedStreamStopsTheWatchdog() {
        val screen = StillScreen()
        screen.start()
        screen.frame()
        screen.close()
        screen.advance(10_000)
        assertEquals(0, screen.codec.requestsMs.size)
        assertEquals(IdleFrameWatchdogState.Closed, screen.model.state)
        screen.start()
        screen.frame()
        screen.advance(5_000)
        assertEquals("a closed stream stays closed", 0, screen.codec.requestsMs.size)
        assertEquals(IdleFrameWatchdogState.Closed, screen.model.state)
    }

    @Test
    fun aStuckEncoderIsAskedOnceASecondAndStillProducesNothing() {
        val codec = VendorCodec().apply { stuck = true }
        val screen = StillScreen(codec)
        screen.start()
        screen.frame()
        screen.advance(5_000)

        assertEquals(listOf(1_000L, 2_000L, 3_000L, 4_000L, 5_000L), screen.codec.requestsMs)
        assertEquals(0, screen.model.idleFrames)
        assertEquals(IdleFrameWatchdogState.Requested, screen.model.state)
        assertEquals("a real stall still reaches the Mac's rule", 0, screen.codec.framesMs.size)
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
            listOf(IdleFrameWatchdogAction.RequestSyncFrame),
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

        // Armed/Requested ignore a second live.
        val armed = modelAfter(idle, IdleFrameWatchdogEvent.Live(0)).model
        assertEquals(armed, modelAfter(armed, IdleFrameWatchdogEvent.Live(500)).model)
        val requested = modelAfter(armed, IdleFrameWatchdogEvent.Tick(1_000)).model
        assertEquals(IdleFrameWatchdogState.Requested, requested.state)
        assertEquals(requested, modelAfter(requested, IdleFrameWatchdogEvent.Live(1_500)).model)

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
