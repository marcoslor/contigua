package app.contigua.ui

import android.app.Application
import android.os.Binder
import android.os.Looper
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import app.contigua.app.DeckState
import app.contigua.app.Prefs
import app.contigua.proto.Json
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import rikka.shizuku.Shizuku
import java.time.Duration
import java.util.concurrent.Executor

/**
 * The foreground service's readings reach the status card through the
 * ViewModel (PHONE-4): the notification-access item, like every other fact,
 * must be passed to `mapStatus` rather than kept in the state beside it.
 *
 * The two pairing pushes (Forget All, Forget one Mac) are here too: both run
 * off the main thread, because the push is a binder call and the identity
 * rotation is key generation (docs/specs/pairing.md PAIR-20).
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

    /**
     * PAIR-20: the person taps Forget All and the list must empty before the
     * key generation and the binder push even start; both then run on the
     * background executor, the push after the rotation.
     */
    @Test
    fun `forget all empties the list at once and pushes the rotated identity off the main thread`() {
        clearStore()
        Prefs.addPaired(ctx, Prefs.PairedMac("1a2b3c4d", "Studio Mac", "aa".repeat(32)))
        Prefs.addPaired(ctx, Prefs.PairedMac("5e6f7a8b", "Pixel 9", "bb".repeat(32)))
        val before = identityOf(Prefs.serviceStateJson(ctx))

        val queued = ArrayDeque<Runnable>()
        val pushes = mutableListOf<String>()
        val vm = DeckViewModel(ctx, Executor { queued.addLast(it) }, { pushes.add(it) })
        assertEquals(2, vm.state.value.paired.size)

        vm.forgetAllMacs()

        assertTrue("the list did not empty at once", vm.state.value.paired.isEmpty())
        assertEquals("the store was cleared on the main thread", 2, Prefs.paired(ctx).size)
        assertTrue("the push ran on the main thread", pushes.isEmpty())

        while (queued.isNotEmpty()) queued.removeFirst().run()
        shadowOf(Looper.getMainLooper()).idle()

        assertEquals("one push after the rotation", 1, pushes.size)
        val pushed = Json.parseObject(pushes.single())
        assertEquals("the pushed set is not empty", 0, Json.asList(pushed["clients"])!!.size)
        assertNotEquals("the identity did not rotate", before, identityOf(pushes.single()))
        assertTrue(Prefs.paired(ctx).isEmpty())
        assertTrue(vm.state.value.paired.isEmpty())
    }

    /** The same rule for one Mac's Undo window: the delayed delete pushes too. */
    @Test
    fun `forgetting one Mac pushes the new list off the main thread`() {
        clearStore()
        Prefs.addPaired(ctx, Prefs.PairedMac("1a2b3c4d", "Studio Mac", "aa".repeat(32)))

        val queued = ArrayDeque<Runnable>()
        val pushes = mutableListOf<String>()
        val vm = DeckViewModel(ctx, Executor { queued.addLast(it) }, { pushes.add(it) })

        vm.forget(vm.state.value.paired.single())
        shadowOf(Looper.getMainLooper()).idleFor(Duration.ofSeconds(5))

        assertTrue("the push ran on the main thread", pushes.isEmpty())
        assertTrue("the Mac is still stored after the Undo window", Prefs.paired(ctx).isEmpty())

        while (queued.isNotEmpty()) queued.removeFirst().run()

        assertEquals(1, pushes.size)
        assertEquals(0, Json.asList(Json.parseObject(pushes.single())["clients"])!!.size)
    }

    private fun identityOf(json: String): String = Json.str(Json.parseObject(json)["identityFp"]).orEmpty()

    /** The store and the identity file, as Clear data would leave them. */
    private fun clearStore() {
        ctx.filesDir.deleteRecursively()
        ctx.filesDir.mkdirs()
        ctx.getSharedPreferences("contigua", android.content.Context.MODE_PRIVATE)
            .edit().clear().commit()
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
