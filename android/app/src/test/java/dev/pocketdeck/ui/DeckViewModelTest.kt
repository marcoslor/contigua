package dev.pocketdeck.ui

import android.app.Application
import android.os.Binder
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import dev.pocketdeck.app.DeckState
import dev.pocketdeck.app.Prefs
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.annotation.Config
import rikka.shizuku.Shizuku

/**
 * The foreground service's readings reach the status card through the
 * ViewModel (PHONE-4): the notification-access item, like every other fact,
 * must be passed to `mapStatus` rather than kept in the state beside it.
 */
@RunWith(AndroidJUnit4::class)
@Config(sdk = [34])
class DeckViewModelTest {

    private val ctx: Application = ApplicationProvider.getApplicationContext()

    @Before
    fun clean() {
        Prefs.setEnabled(ctx, true)
        Prefs.setAllowConnections(ctx, true)
        Prefs.setAllowPairings(ctx, true)
        DeckState.port = 4711
        DeckState.connectedMac = null
        DeckState.connectedClientId = null
        DeckState.notifyNoAccess = false
        // The JVM has no Shizuku service; the app's two readings are the
        // process-global binder and the cached grant.
        fakeShizuku(running = true, granted = true)
    }

    @After
    fun tearDown() {
        fakeShizuku(running = false, granted = false)
        DeckState.port = -1
        DeckState.notifyNoAccess = false
        Prefs.setEnabled(ctx, false)
    }

    @Test
    fun `a missing listener grant while the Mac asked reaches the card`() {
        // The Mac's switch asked for notifications and the listener grant is
        // missing: the phone's home must show the item, and the service's flag
        // is the only input it comes from.
        DeckState.notifyNoAccess = true

        val vm = DeckViewModel(ctx)

        assertEquals(AttentionKind.NOTIFY_ACCESS, vm.state.value.status.attention)
        assertEquals(StatusState.NEEDS_ATTENTION, vm.state.value.status.state)
    }

    @Test
    fun `no listener flag is no attention item`() {
        DeckState.notifyNoAccess = false

        val vm = DeckViewModel(ctx)

        assertEquals(StatusState.READY, vm.state.value.status.state)
        assertEquals(AttentionKind.NONE, vm.state.value.status.attention)
        assertNull(vm.state.value.connectedMac)
    }

    /** Sets Shizuku's two process-global readings the way its provider would. */
    private fun fakeShizuku(running: Boolean, granted: Boolean) {
        runCatching {
            Shizuku::class.java.getDeclaredField("binder").apply { isAccessible = true }
                .set(null, if (running) Binder() else null)
            Shizuku::class.java.getDeclaredField("permissionGranted").apply { isAccessible = true }
                .setBoolean(null, granted)
        }
    }
}
