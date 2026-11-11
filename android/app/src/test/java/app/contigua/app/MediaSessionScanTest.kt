package app.contigua.app

import android.content.Context
import android.media.MediaMetadata
import android.media.session.MediaController
import android.media.session.MediaSession
import android.media.session.MediaSessionManager
import android.media.session.PlaybackState
import android.os.HandlerThread
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.TimeUnit
import org.junit.After
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.Shadows.shadowOf
import org.robolectric.android.controller.ServiceController
import org.robolectric.annotation.Config
import org.robolectric.shadow.api.Shadow
import org.robolectric.shadows.ShadowMediaSessionManager
import org.robolectric.util.ReflectionHelpers

/**
 * The listener's media stack (docs/design/notify.md "Media part 2 design"):
 * `media.sessions` must not depend on one read at connect or on a callback the
 * system may never deliver. Two cases the emulator rig hit (silent Now Playing):
 * the Mac opts in after the app already read an empty stack, and a session
 * appears without the change callback. The gate is exercised for real; the
 * bridge records what would cross the wire (nothing here logs or keeps a title).
 */
@RunWith(AndroidJUnit4::class)
@Config(sdk = [34])
class MediaSessionScanTest {

    private val ctx: Context = ApplicationProvider.getApplicationContext()
    private val pushed = CopyOnWriteArrayList<Map<String, Any?>>()
    private var service: ServiceController<PdNotificationListener>? = null
    private lateinit var manager: ShadowMediaSessionManager

    @Before
    fun setUp() {
        DeckState.notifyForward = false
        pushed.clear()
        PdNotificationBridge.recordForTest = { event -> pushed += event }
        manager = shadowOf(ctx.getSystemService(MediaSessionManager::class.java))
        manager.clearControllers()
    }

    @After
    fun tearDown() {
        service?.destroy()
        service = null
        manager.clearControllers()
        PdNotificationBridge.recordForTest = null
        DeckState.notifyForward = false
        DeckState.notifyChanged()
    }

    @Test
    fun `sessions held while the Mac had not opted in are sent when it does`() {
        val listener = start()
        manager.addController(controller("com.example.one"))
        manager.addController(controller("com.example.two"))
        // The app is up and reads the stack while nothing is forwarded: every
        // push is dropped by the gate.
        listener.onListenerConnected()
        settle(listener)
        assertTrue(
            "nothing reaches the Mac before the gate opens",
            pushed.none { sessionsIn(it) == 2 },
        )

        DeckState.notifyForward = true
        DeckState.notifyChanged()
        settle(listener)

        assertTrue(
            "the list is re-read and re-sent when the Mac's gate opens",
            pushed.any { sessionsIn(it) == 2 },
        )
    }

    @Test
    fun `a session that appears without the change callback is still found`() {
        DeckState.notifyForward = true
        val listener = start()
        listener.onListenerConnected()
        settle(listener)

        // The stack moves but the system tells no one (the rig's symptom).
        addWithoutCallback(controller("com.example.three"))
        // A command from the Mac finds nothing attached: re-read before giving up.
        PdNotificationBridge.mediaSink?.invoke("""{"t":"media.command","action":"play","key":"zzz"}""")
        settle(listener)

        assertTrue(
            "a command with nothing attached re-reads the stack",
            pushed.any { sessionsIn(it) == 1 },
        )
    }

    private fun start(): PdNotificationListener {
        val controller = Robolectric.buildService(PdNotificationListener::class.java).create()
        service = controller
        return controller.get()
    }

    /**
     * Runs the listener's worker thread to the end of what it has to do. A scan
     * runs inside an idle pass and only schedules its push on the same worker
     * (the 200 ms merge), which is due after that pass's clock advance: a second
     * pass runs what the first one set in motion. Two fixed passes, not a
     * longer wait.
     */
    private fun settle(listener: PdNotificationListener) {
        val worker = ReflectionHelpers.getField<HandlerThread>(listener, "worker")
        val looper = shadowOf(worker.looper)
        repeat(2) { looper.idleFor(1, TimeUnit.SECONDS) }
    }

    /** One active session as the system would report it (no artwork, no text sent). */
    private fun controller(pkg: String): MediaController {
        val controller = Shadow.newInstanceOf(MediaController::class.java)
        // Distinct tokens: the listener keys sessions by token identity.
        ReflectionHelpers.setField(
            controller,
            "mToken",
            Shadow.newInstanceOf(MediaSession.Token::class.java),
        )
        val shadow = shadowOf(controller)
        shadow.setPackageName(pkg)
        shadow.setPlaybackState(
            PlaybackState.Builder()
                .setActions(PlaybackState.ACTION_PLAY or PlaybackState.ACTION_SEEK_TO)
                .setState(PlaybackState.STATE_PLAYING, 1_000L, 1.0f, 0L)
                .build(),
        )
        shadow.setMetadata(
            MediaMetadata.Builder()
                .putLong(MediaMetadata.METADATA_KEY_DURATION, 180_000L)
                .build(),
        )
        return controller
    }

    /**
     * Adds a controller to the manager's list without notifying its change
     * listeners: the callback is a signal, not a guarantee.
     */
    private fun addWithoutCallback(controller: MediaController) {
        val field = ShadowMediaSessionManager::class.java.getDeclaredField("controllers")
        field.isAccessible = true
        @Suppress("UNCHECKED_CAST")
        (field.get(null) as MutableList<MediaController>).add(controller)
    }

    private fun sessionsIn(event: Map<String, Any?>): Int =
        if (event["t"] == "media.sessions") (event["list"] as? List<*>)?.size ?: 0 else 0
}
