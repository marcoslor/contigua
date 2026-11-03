package dev.pocketdeck.app

import android.app.Notification
import android.content.Context
import android.media.session.MediaSession
import android.os.HandlerThread
import android.os.Process
import android.service.notification.StatusBarNotification
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
import org.robolectric.util.ReflectionHelpers

/**
 * Row 16 (NOTIFY-3, r3): a notification carrying a media session is Now
 * Playing's, not a banner — a paused player stops being ongoing, so it would
 * otherwise banner. It is never forwarded, so its removal is not announced.
 */
@RunWith(AndroidJUnit4::class)
@Config(sdk = [34])
class NotifyMediaSkipTest {

    private val ctx: Context = ApplicationProvider.getApplicationContext()
    private val pushed = CopyOnWriteArrayList<Map<String, Any?>>()
    private var service: ServiceController<PdNotificationListener>? = null

    @Before
    fun setUp() {
        DeckState.notifyForward = true
        pushed.clear()
        NotifyIntents.clear()
        PdNotificationBridge.recordForTest = { event -> pushed += event }
    }

    @After
    fun tearDown() {
        service?.destroy()
        service = null
        NotifyIntents.clear()
        PdNotificationBridge.recordForTest = null
        DeckState.notifyForward = false
        DeckState.notifyChanged()
    }

    private fun start(): PdNotificationListener {
        val controller = Robolectric.buildService(PdNotificationListener::class.java).create()
        service = controller
        return controller.get()
    }

    private fun settle(listener: PdNotificationListener) {
        val worker = ReflectionHelpers.getField<HandlerThread>(listener, "worker")
        val looper = shadowOf(worker.looper)
        repeat(2) { looper.idleFor(1, TimeUnit.SECONDS) }
    }

    /** A player's notification, with the session token a real one carries. */
    private fun sbn(id: Int, title: String): StatusBarNotification {
        val notification = Notification.Builder(ctx, "test")
            .setContentTitle(title)
            .setContentText("Fake Song")
            .setSmallIcon(android.R.drawable.ic_dialog_info)
            .build()
        notification.extras.putParcelable(
            Notification.EXTRA_MEDIA_SESSION,
            Shadow.newInstanceOf(MediaSession.Token::class.java),
        )
        val sbn = Shadow.newInstanceOf(StatusBarNotification::class.java)
        ReflectionHelpers.setField(sbn, "pkg", "com.example.player")
        ReflectionHelpers.setField(sbn, "opPkg", "com.example.player")
        ReflectionHelpers.setField(sbn, "id", id)
        ReflectionHelpers.setField(sbn, "uid", 1000)
        ReflectionHelpers.setField(sbn, "initialPid", 1000)
        ReflectionHelpers.setField(sbn, "notification", notification)
        ReflectionHelpers.setField(sbn, "postTime", System.currentTimeMillis())
        ReflectionHelpers.setField(sbn, "user", Process.myUserHandle())
        return sbn
    }

    @Test
    fun `a media session's notification never banners`() {
        val listener = start()
        val posted = sbn(1, "Fake Song")
        listener.onNotificationPosted(posted)
        settle(listener)
        assertTrue(
            "Now Playing owns it, not a banner",
            pushed.none { it["t"] == "notify.post" },
        )
        pushed.clear()
        listener.onNotificationRemoved(posted)
        settle(listener)
        assertTrue(
            "a notification that never went out needs no removal",
            pushed.none { it["t"] == "notify.remove" },
        )
    }
}
