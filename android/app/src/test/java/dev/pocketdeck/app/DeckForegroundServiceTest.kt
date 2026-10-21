package dev.pocketdeck.app

import android.app.Application
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.After
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config

/**
 * The background switch decides the task lifetime: with it on the service
 * ignores the task being swiped away (and starts at boot); with it off the
 * service stops when the app leaves Recents.
 */
@RunWith(AndroidJUnit4::class)
@Config(sdk = [34])
class DeckForegroundServiceTest {

    private val ctx: Application = ApplicationProvider.getApplicationContext()

    @After
    fun tearDown() {
        Prefs.setEnabled(ctx, false)
    }

    @Test
    fun `the service stops when the task is removed and the switch is off`() {
        Prefs.setEnabled(ctx, false)
        val controller = Robolectric.buildService(DeckForegroundService::class.java).create()
        val service = controller.get()

        service.onTaskRemoved(null)

        assertTrue(shadowOf(service).isStoppedBySelf)
        controller.destroy()
    }

    @Test
    fun `the service survives task removal when the switch is on`() {
        Prefs.setEnabled(ctx, true)
        val controller = Robolectric.buildService(DeckForegroundService::class.java).create()
        val service = controller.get()

        service.onTaskRemoved(null)

        assertFalse(shadowOf(service).isStoppedBySelf)
        controller.destroy()
    }

    @Test
    fun `boot starts the deck only with the switch on and Shizuku running`() {
        assertFalse(startsAtBoot(enabled = false, shizukuRunning = true))
        assertFalse(startsAtBoot(enabled = true, shizukuRunning = false))
        assertTrue(startsAtBoot(enabled = true, shizukuRunning = true))
    }
}
