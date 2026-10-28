package dev.pocketdeck.ui

import android.app.Application
import android.content.Intent
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import dev.pocketdeck.app.DeckForegroundService
import dev.pocketdeck.app.DeckState
import dev.pocketdeck.app.Prefs
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config

/**
 * The two home switches are separate: "Keep running in the background" off no
 * longer stops the service while the task is open, and the status card's Turn
 * on touches only "Allow connections".
 */
@RunWith(AndroidJUnit4::class)
@Config(sdk = [34])
class StatusActionTest {

    private val ctx: Application = ApplicationProvider.getApplicationContext()

    @Before
    fun clean() {
        Prefs.setEnabled(ctx, false)
        Prefs.setAllowConnections(ctx, true)
        Prefs.setAllowPairings(ctx, true)
        DeckState.port = -1
        shadowOf(ctx).clearStartedServices()
    }

    @After
    fun tearDown() {
        Prefs.setEnabled(ctx, false)
        Prefs.setAllowConnections(ctx, true)
        Prefs.setAllowPairings(ctx, true)
        DeckState.port = -1
    }

    @Test
    fun `turn on fixes only allow connections`() {
        Prefs.setEnabled(ctx, false)
        Prefs.setAllowConnections(ctx, false)
        val vm = DeckViewModel(ctx)
        shadowOf(ctx).clearStartedServices()

        vm.runStatusAction(AttentionKind.CONNECTIONS_OFF)

        assertTrue(Prefs.isAllowConnections(ctx))
        assertFalse("the background switch must stay off", Prefs.isEnabled(ctx))
        assertNull("nothing should be started", shadowOf(ctx).nextStartedService)
    }

    @Test
    fun `turning the background switch off keeps the service running`() {
        Prefs.setEnabled(ctx, true)
        val vm = DeckViewModel(ctx)
        shadowOf(ctx).clearStartedServices()

        vm.setEnabled(false)

        assertFalse(Prefs.isEnabled(ctx))
        assertNull(shadowOf(ctx).nextStartedService)
    }

    @Test
    fun `turning the background switch on starts the service`() {
        Prefs.setEnabled(ctx, false)
        val vm = DeckViewModel(ctx)
        shadowOf(ctx).clearStartedServices()

        vm.setEnabled(true)

        assertTrue(Prefs.isEnabled(ctx))
        val started = shadowOf(ctx).nextStartedService
        assertNotNull(started)
        assertEquals(DeckForegroundService::class.java.name, started!!.component?.className)
    }

    /**
     * The Shizuku-not-running card's action has to fit the phone: with the
     * package absent, opening it cannot work and the store is the fix
     * (misses.md M6).
     */
    @Test
    fun `a phone without Shizuku offers its install page`() {
        val vm = DeckViewModel(ctx)

        vm.runStatusAction(AttentionKind.SHIZUKU_NOT_RUNNING)

        val started = shadowOf(ctx).nextStartedActivity
        assertNotNull("Get Shizuku must open the store", started)
        assertEquals(Intent.ACTION_VIEW, started!!.action)
        assertTrue(started.dataString.orEmpty().contains(DeckViewModel.SHIZUKU_PACKAGE))
    }
}
