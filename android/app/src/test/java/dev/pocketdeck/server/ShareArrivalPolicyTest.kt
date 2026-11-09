package dev.pocketdeck.server

import dev.pocketdeck.server.ShareArrivalPolicy.Decision
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * WIN-50/ISS-51: a task an app starts right after a paste or a drop into its
 * window is moved back onto that window's display when the system put it on
 * the phone's own screen, and left alone in every other case.
 */
class ShareArrivalPolicyTest {

    private val chrome = "com.android.chrome"
    private val now = 10_000L

    private fun window(
        stream: Int = 1,
        pkg: String = chrome,
        displayId: Int = 100,
        shareAtMs: Long? = now - 200,
    ) = ShareArrivalPolicy.Window(stream, pkg, displayId, shareAtMs)

    @Test
    fun aTaskThatLandedOnThePhoneScreenMovesToTheWindowsDisplay() {
        assertEquals(Decision.Move(1, 100),
            ShareArrivalPolicy.decide(listOf(window()), chrome, ShareArrivalPolicy.PHONE_DISPLAY, now))
    }

    @Test
    fun aTaskAlreadyOnTheWindowsDisplayStays() {
        assertEquals(Decision.Keep,
            ShareArrivalPolicy.decide(listOf(window()), chrome, 100, now))
    }

    @Test
    fun aTaskOnAnotherWindowsDisplayIsNotStolen() {
        val other = window(stream = 2, displayId = 101)
        assertEquals(Decision.Keep,
            ShareArrivalPolicy.decide(listOf(window(), other), chrome, 101, now))
    }

    @Test
    fun aTaskAfterTheShareWindowIsIgnored() {
        val old = window(shareAtMs = now - ShareArrivalPolicy.WINDOW_MS - 1)
        assertEquals(Decision.Ignore,
            ShareArrivalPolicy.decide(listOf(old), chrome, ShareArrivalPolicy.PHONE_DISPLAY, now))
    }

    @Test
    fun theShareWindowEndsExactlyAtItsBoundary() {
        val edge = window(shareAtMs = now - ShareArrivalPolicy.WINDOW_MS)
        assertEquals(Decision.Move(1, 100),
            ShareArrivalPolicy.decide(listOf(edge), chrome, ShareArrivalPolicy.PHONE_DISPLAY, now))
    }

    @Test
    fun aWindowWithNoShareTriggerIsIgnored() {
        assertEquals(Decision.Ignore,
            ShareArrivalPolicy.decide(listOf(window(shareAtMs = null)), chrome, ShareArrivalPolicy.PHONE_DISPLAY, now))
    }

    @Test
    fun anotherPackagesTaskIsIgnored() {
        assertEquals(Decision.Ignore,
            ShareArrivalPolicy.decide(listOf(window()), "com.example.other", ShareArrivalPolicy.PHONE_DISPLAY, now))
    }

    @Test
    fun aTaskWithNoPackageIsIgnored() {
        assertEquals(Decision.Ignore,
            ShareArrivalPolicy.decide(listOf(window()), null, ShareArrivalPolicy.PHONE_DISPLAY, now))
    }

    @Test
    fun anUnreadableDisplayIsIgnored() {
        assertEquals(Decision.Ignore,
            ShareArrivalPolicy.decide(listOf(window()), chrome, null, now))
        assertEquals(Decision.Ignore,
            ShareArrivalPolicy.decide(listOf(window()), chrome, -1, now))
    }

    @Test
    fun aPhoneMirrorIsNeverATarget() {
        val mirror = window(displayId = ShareArrivalPolicy.PHONE_DISPLAY)
        assertEquals(Decision.Ignore,
            ShareArrivalPolicy.decide(listOf(mirror), chrome, ShareArrivalPolicy.PHONE_DISPLAY, now))
    }

    @Test
    fun twoWindowsOfOnePackageTheLastShareWins() {
        val older = window(stream = 1, displayId = 100, shareAtMs = now - 2_000)
        val newer = window(stream = 2, displayId = 101, shareAtMs = now - 100)
        assertEquals(Decision.Move(2, 101),
            ShareArrivalPolicy.decide(listOf(older, newer), chrome, ShareArrivalPolicy.PHONE_DISPLAY, now))
    }

    @Test
    fun aTriggerInTheFutureIsIgnored() {
        val skew = window(shareAtMs = now + 1)
        assertEquals(Decision.Ignore,
            ShareArrivalPolicy.decide(listOf(skew), chrome, ShareArrivalPolicy.PHONE_DISPLAY, now))
    }
}
