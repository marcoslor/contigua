package dev.pocketdeck.app

import android.app.Notification
import android.content.Context
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
 * Which removals the phone announces (NOTIFY-20, r2 finding 3): every removal
 * the Mac was told about, even after the forwarded-id map forgot the id, and
 * none for a summary the phone deliberately kept. The bridge records what would
 * cross the wire; no text appears here.
 */
@RunWith(AndroidJUnit4::class)
@Config(sdk = [34])
class NotifyRemovalTest {

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

    /** Runs the listener's worker thread to the end of what it has to do. */
    private fun settle(listener: PdNotificationListener) {
        val worker = ReflectionHelpers.getField<HandlerThread>(listener, "worker")
        val looper = shadowOf(worker.looper)
        repeat(2) { looper.idleFor(1, TimeUnit.SECONDS) }
    }

    private fun sbn(
        pkg: String,
        id: Int,
        title: String,
        text: String,
        group: String? = null,
        flags: Int = 0,
    ): StatusBarNotification {
        val builder = Notification.Builder(ctx, "test")
            .setContentTitle(title)
            .setContentText(text)
            .setSmallIcon(android.R.drawable.ic_dialog_info)
        if (group != null) builder.setGroup(group)
        val notification = builder.build()
        notification.flags = flags
        // StatusBarNotification's constructor is not public API; a real one
        // carries the app's group and the system's group key.
        val sbn = Shadow.newInstanceOf(StatusBarNotification::class.java)
        ReflectionHelpers.setField(sbn, "pkg", pkg)
        ReflectionHelpers.setField(sbn, "opPkg", pkg)
        ReflectionHelpers.setField(sbn, "id", id)
        ReflectionHelpers.setField(sbn, "uid", 1000)
        ReflectionHelpers.setField(sbn, "initialPid", 1000)
        ReflectionHelpers.setField(sbn, "notification", notification)
        ReflectionHelpers.setField(sbn, "postTime", System.currentTimeMillis())
        ReflectionHelpers.setField(sbn, "user", Process.myUserHandle())
        ReflectionHelpers.setField(sbn, "groupKey", group)
        return sbn
    }

    @Test
    fun `a removal for a forwarded id the listener no longer holds is announced`() {
        val listener = start()
        val posted = sbn("com.chat", 1, "Design", "one")
        listener.onNotificationPosted(posted)
        settle(listener)
        assertTrue(
            "the post crossed the wire first",
            pushed.any { it["t"] == "notify.post" },
        )
        // A long session evicts old ids from the forwarded-id map; the Mac
        // still holds their banners, so the removal must not be swallowed.
        NotifyIntents.clear()
        listener.onNotificationRemoved(posted)
        settle(listener)
        assertTrue(
            "an evicted forwarded id's removal is still announced",
            pushed.any { it["t"] == "notify.remove" },
        )
    }

    @Test
    fun `a skipped summary's removal is not announced`() {
        val listener = start()
        listener.onNotificationPosted(sbn("com.chat", 1, "Design", "one", group = "chat"))
        settle(listener)
        assertTrue("the child was forwarded", pushed.any { it["t"] == "notify.post" })
        pushed.clear()
        // The group's summary: the phone keeps it because a child is active.
        val summary = sbn(
            "com.chat", 2, "Design", "2 new messages", group = "chat",
            flags = Notification.FLAG_GROUP_SUMMARY,
        )
        listener.onNotificationPosted(summary)
        settle(listener)
        assertTrue("a skipped summary never reaches the Mac", pushed.none { it["t"] == "notify.post" })
        listener.onNotificationRemoved(summary)
        settle(listener)
        assertTrue(
            "a skipped summary's removal is not news",
            pushed.none { it["t"] == "notify.remove" },
        )
    }
}
