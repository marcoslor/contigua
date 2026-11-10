package dev.pocketdeck.server

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * K1 for the no-frame episode record (WIN-66, ISS-10): the fields, the closed
 * tokens and the privacy rule — ids, counts, durations and states only.
 */
class NoFrameEpisodeTest {

    private fun open() = NoFrameEpisode(
        episode = 41,
        stream = 7,
        recordedMs = NO_FRAME_AFTER_MS,
        display = DisplayPhase.Virtual,
        encoder = EncoderPhase.Attached,
        paused = false,
        suspended = false,
        task = NoFrameTask.Launched,
        displayState = NoFrameDisplay.Doze,
        keyguard = NoFrameKeyguard.Showing,
        doze = NoFrameDoze.Idle,
        screen = NoFrameScreen.Off,
        nudges = 2,
        framesOut = 0,
        keyframesOut = 0,
        bytesOut = 0,
    )

    @Test
    fun theWireCarriesTheDocumentedFieldsAndClosedTokens() {
        val wire = open().wire()
        assertEquals(
            listOf(
                "ep", "ms", "phase", "display", "task", "on", "keyguard", "doze",
                "screen", "nudge", "out", "kf", "bytes",
            ),
            wire.keys.toList(),
        )
        assertEquals(41, wire["ep"])
        assertEquals(NO_FRAME_AFTER_MS, wire["ms"])
        assertEquals("draining", wire["phase"])
        assertEquals("virtual", wire["display"])
        assertEquals("launched", wire["task"])
        assertEquals("doze", wire["on"])
        assertEquals("showing", wire["keyguard"])
        assertEquals("idle", wire["doze"])
        assertEquals("off", wire["screen"])
        assertEquals(2, wire["nudge"])
        assertEquals(0L, wire["out"])
        assertEquals(0L, wire["kf"])
        assertEquals(0L, wire["bytes"])
        assertNull(wire["outcome"])
        assertNull(wire["waitedMs"])
    }

    @Test
    fun anEndedEpisodeCarriesItsOutcomeAndWaitedTime() {
        val wire = open().copy(outcome = NoFrameOutcome.Late, waitedMs = 2_600L).wire()
        assertEquals("late", wire["outcome"])
        assertEquals(2_600L, wire["waitedMs"])
        assertEquals(NO_FRAME_AFTER_MS, wire["ms"])
    }

    @Test
    fun theLinesAreTheDocumentedOnes() {
        assertEquals(
            "stream 7: no frame for 1.5s phase=draining display=virtual task=launched" +
                " on=doze keyguard=showing doze=idle screen=off nudge=2 out=0 kf=0 bytes=0",
            open().line(),
        )
        assertEquals(
            "stream 7: no frame ended outcome=late after 2600ms",
            open().copy(outcome = NoFrameOutcome.Late, waitedMs = 2_600L).endedLine(),
        )
        assertEquals(
            "stream 7: no frame ended outcome=closed after 22000ms",
            open().copy(outcome = NoFrameOutcome.Closed, waitedMs = 22_000L).endedLine(),
        )
    }

    @Test
    fun theEncoderTokenNamesTheHeldStates() {
        assertEquals(
            "paused",
            open().copy(encoder = EncoderPhase.Attached, paused = true).wire()["phase"],
        )
        assertEquals(
            "paused+suspended",
            open().copy(encoder = EncoderPhase.Attached, paused = true, suspended = true).wire()["phase"],
        )
        assertEquals(
            "prepared",
            open().copy(encoder = EncoderPhase.Prepared, paused = true).wire()["phase"],
        )
    }

    /** The record holds no free text: every string it can send is a closed token. */
    @Test
    fun theRecordHasNoStringFields() {
        val strings = NoFrameEpisode::class.java.declaredFields
            .filterNot { it.isSynthetic }
            .filter { it.type == String::class.java }
            .map { it.name }
        assertTrue("free-text fields: $strings", strings.isEmpty())
    }

    /** A stray token from a newer phone still lands inside the Mac's closed set. */
    @Test
    fun everyWireValueIsANumberOrAClosedToken() {
        val allowed = mapOf(
            "phase" to setOf("empty", "opening", "prepared", "draining", "paused", "suspended",
                "paused+suspended", "swapping", "released"),
            "display" to setOf("none", "mirror", "virtual"),
            "task" to setOf("none", "launched", "unknown"),
            "on" to setOf("on", "off", "doze", "doze-suspend", "vr", "on-suspend", "unknown"),
            "keyguard" to setOf("showing", "hidden", "unknown"),
            "doze" to setOf("active", "light", "idle", "unknown"),
            "screen" to setOf("on", "off", "unknown"),
            "outcome" to setOf("late", "closed"),
        )
        for (phase in EncoderPhase.values()) {
            for (display in DisplayPhase.values()) {
                val wire = open().copy(encoder = phase, display = display).wire()
                for ((key, tokens) in allowed) {
                    val value = wire[key]
                    if (value is String) {
                        assertTrue("$key=$value", value in tokens)
                    }
                }
            }
        }
    }
}
