package dev.pocketdeck.server

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

/** Every transition of the process's HEVC state, and the ignored events. */
class HevcCodecStateTest {

    private val supports: (Int, Int) -> Boolean = { _, _ -> true }

    @Test
    fun unknownProbesToAvailable() {
        val moved = HevcCodecState.transition(
            HevcCodecState.State.Unknown,
            HevcCodecState.Event.Probed(HevcCodecState.Probe.Hardware(supports)),
        )
        assertEquals(HevcCodecState.State.Available(supports), moved.state)
        assertEquals("hevc: unknown --probe--> available", moved.line)
    }

    @Test
    fun unknownProbesToUnavailableForSoftwareOrMissing() {
        val software = HevcCodecState.transition(
            HevcCodecState.State.Unknown,
            HevcCodecState.Event.Probed(HevcCodecState.Probe.Software),
        )
        assertEquals(HevcCodecState.State.Unavailable("encoder"), software.state)
        assertEquals("hevc: unknown --probe--> unavailable(encoder)", software.line)

        val missing = HevcCodecState.transition(
            HevcCodecState.State.Unknown,
            HevcCodecState.Event.Probed(HevcCodecState.Probe.Missing),
        )
        assertEquals(HevcCodecState.State.Unavailable("encoder"), missing.state)
    }

    @Test
    fun anAvailableEncoderFailingConfigureIsRetiredForTheProcess() {
        val available = HevcCodecState.State.Available(supports)
        val moved = HevcCodecState.transition(available, HevcCodecState.Event.ConfigureFailed)
        assertEquals(HevcCodecState.State.Unavailable("configure"), moved.state)
        assertEquals("hevc: available --configure--> unavailable(configure)", moved.line)
    }

    @Test
    fun aProbeIsIgnoredOnceKnown() {
        val available = HevcCodecState.State.Available(supports)
        val moved = HevcCodecState.transition(
            available,
            HevcCodecState.Event.Probed(HevcCodecState.Probe.Software),
        )
        assertSame(available, moved.state)
        assertNull(moved.line)
    }

    @Test
    fun anUnavailableEncoderIgnoresEveryEvent() {
        val unavailable = HevcCodecState.State.Unavailable("configure")
        for (event in listOf(
            HevcCodecState.Event.Probed(HevcCodecState.Probe.Hardware(supports)),
            HevcCodecState.Event.ConfigureFailed,
        )) {
            val moved = HevcCodecState.transition(unavailable, event)
            assertSame(unavailable, moved.state)
            assertNull(moved.line)
        }
    }

    @Test
    fun configureCannotFailBeforeAProbe() {
        val moved = HevcCodecState.transition(
            HevcCodecState.State.Unknown,
            HevcCodecState.Event.ConfigureFailed,
        )
        assertSame(HevcCodecState.State.Unknown, moved.state)
        assertNull(moved.line)
    }

    @Test
    fun resolveProbesOnceAndLogsOneLine() {
        var probes = 0
        val lines = mutableListOf<String>()
        val state = HevcCodecState {
            probes++
            HevcCodecState.Probe.Hardware(supports)
        }

        val first = state.resolve(lines::add)
        val second = state.resolve(lines::add)

        assertSame(first, second)
        assertEquals(1, probes)
        assertEquals(listOf("hevc: unknown --probe--> available"), lines)
    }

    @Test
    fun theStateOutlivesTheStreamAndLatchesTheFailure() {
        val lines = mutableListOf<String>()
        var probes = 0
        val state = HevcCodecState {
            probes++
            HevcCodecState.Probe.Hardware(supports)
        }

        state.resolve(lines::add)
        state.configureFailed(lines::add)
        state.configureFailed(lines::add)
        state.resolve(lines::add)

        assertEquals(1, probes)
        assertEquals(
            listOf(
                "hevc: unknown --probe--> available",
                "hevc: available --configure--> unavailable(configure)",
            ),
            lines,
        )
        assertTrue(state.state is HevcCodecState.State.Unavailable)
    }
}
