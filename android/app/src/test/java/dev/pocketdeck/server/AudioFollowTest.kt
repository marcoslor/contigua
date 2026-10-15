package dev.pocketdeck.server

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * The uid-set decision from open windows (docs/design/audio.md "follows the
 * window"): phone-mode window → all audio, unattributed window → all audio,
 * app windows → the sorted distinct uid set, nothing followable → idle.
 */
class AudioFollowTest {

    private val uids = mapOf("a" to 10215, "b" to 10216)
    private fun uidOf(pkg: String): Int? = uids[pkg]

    @Test
    fun `no windows means idle`() {
        assertEquals(FollowPlan.Idle, AudioFollow.plan(emptyList(), ::uidOf))
    }

    @Test
    fun `a phone window means all audio`() {
        assertEquals(
            FollowPlan.AllAudio,
            AudioFollow.plan(listOf(CaptureWindow.App("a"), CaptureWindow.Phone), ::uidOf),
        )
        assertEquals(
            FollowPlan.AllAudio,
            AudioFollow.plan(listOf(CaptureWindow.Phone), ::uidOf),
        )
    }

    @Test
    fun `an unattributed window falls back to all audio`() {
        assertEquals(
            FollowPlan.AllAudio,
            AudioFollow.plan(
                listOf(CaptureWindow.App("a"), CaptureWindow.Unresolved("link pending")),
                ::uidOf,
            ),
        )
    }

    @Test
    fun `app windows become the sorted distinct uid set`() {
        assertEquals(
            FollowPlan.PerApp(listOf(10215, 10216)),
            AudioFollow.plan(listOf(CaptureWindow.App("b"), CaptureWindow.App("a")), ::uidOf),
        )
        // Shared-UID apps and repeats collapse to one rule per uid.
        assertEquals(
            FollowPlan.PerApp(listOf(10215)),
            AudioFollow.plan(listOf(CaptureWindow.App("a"), CaptureWindow.App("a")), ::uidOf),
        )
    }

    @Test
    fun `silent windows contribute nothing`() {
        assertEquals(
            FollowPlan.PerApp(listOf(10215)),
            AudioFollow.plan(listOf(CaptureWindow.Silent, CaptureWindow.App("a")), ::uidOf),
        )
        assertEquals(
            FollowPlan.Idle,
            AudioFollow.plan(listOf(CaptureWindow.Silent, CaptureWindow.Silent), ::uidOf),
        )
    }

    @Test
    fun `unresolved-only windows mean all audio too`() {
        assertEquals(
            FollowPlan.AllAudio,
            AudioFollow.plan(listOf(CaptureWindow.Unresolved("link")), ::uidOf),
        )
    }
}
