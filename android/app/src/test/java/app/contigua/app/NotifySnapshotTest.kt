package app.contigua.app

import android.app.Notification
import android.content.Context
import android.os.Process
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.TimeUnit
import org.junit.After
import org.junit.Assert.assertEquals
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
 * NOTIFY-1/PATH-6 (ISS-5): the Mac repeats `notify.enable on` after a
 * same-session rejoin, and the phone answers with its active set — one quiet
 * post per notification still on the phone, then `notify.snapshot` naming the
 * ids that went out (in that order). A second enable is a second snapshot; the
 * Mac reconciles against it instead of showing a second banner.
 */
@RunWith(AndroidJUnit4::class)
@Config(sdk = [34])
class NotifySnapshotTest {

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
        val worker = ReflectionHelpers.getField<android.os.HandlerThread>(listener, "worker")
        val looper = shadowOf(worker.looper)
        repeat(3) { looper.idleFor(1, TimeUnit.SECONDS) }
    }

    private fun sbn(id: Int, pkg: String = "com.example.chat"): StatusBarNotification {
        val notification = Notification.Builder(ctx, "test")
            .setContentTitle("Fake title")
            .setContentText("Fake text")
            .setSmallIcon(android.R.drawable.ic_dialog_info)
            .build()
        val sbn = Shadow.newInstanceOf(StatusBarNotification::class.java)
        ReflectionHelpers.setField(sbn, "pkg", pkg)
        ReflectionHelpers.setField(sbn, "opPkg", pkg)
        ReflectionHelpers.setField(sbn, "id", id)
        ReflectionHelpers.setField(sbn, "uid", 1000)
        ReflectionHelpers.setField(sbn, "initialPid", 1000)
        ReflectionHelpers.setField(sbn, "notification", notification)
        ReflectionHelpers.setField(sbn, "postTime", System.currentTimeMillis())
        ReflectionHelpers.setField(sbn, "user", Process.myUserHandle())
        return sbn
    }

    /** What the shell does on every answered enable while forwarding. */
    private fun enableAnswered() {
        PdNotificationBridge.resyncSink?.invoke()
    }

    @Test
    fun `a repeated enable resends the active set once, posts before the snapshot`() {
        val listener = start()
        val shadow = shadowOf(listener as NotificationListenerService)
        shadow.addActiveNotification(sbn(1))
        shadow.addActiveNotification(sbn(2, "com.example.mail"))
        pushed.clear()
        enableAnswered()
        settle(listener)

        val posts = pushed.filter { it["t"] == "notify.post" }
        val snapshots = pushed.filter { it["t"] == "notify.snapshot" }
        assertEquals("one quiet post per active notification", 2, posts.size)
        assertEquals("one snapshot per enable", 1, snapshots.size)
        assertTrue(
            "a snapshot post never alerts (no second banner)",
            posts.all { it["alert"] == false },
        )
        val ids = (snapshots.first()["ids"] as List<*>).map { it.toString() }
        assertEquals("the snapshot names exactly what it posted", posts.map { it["id"] }, ids)
        assertTrue(
            "the posts precede the marker",
            pushed.indexOf(snapshots.first()) > pushed.indexOf(posts.last()),
        )

        // A second enable (another rejoin) answers with another complete set.
        enableAnswered()
        settle(listener)
        assertEquals(2, pushed.count { it["t"] == "notify.snapshot" })
        assertEquals(4, pushed.count { it["t"] == "notify.post" })
    }

    @Test
    fun `an active notification the phone does not forward stays out of the set`() {
        val listener = start()
        val shadow = shadowOf(listener as NotificationListenerService)
        shadow.addActiveNotification(sbn(1))
        // A media session's notification is Now Playing's (NOTIFY-3), never a
        // banner, so the snapshot must not name it.
        val media = sbn(2, "com.example.player")
        media.notification.extras.putParcelable(
            Notification.EXTRA_MEDIA_SESSION,
            android.os.Bundle(),
        )
        shadow.addActiveNotification(media)
        pushed.clear()
        enableAnswered()
        settle(listener)

        val ids = pushed.filter { it["t"] == "notify.snapshot" }
            .flatMap { (it["ids"] as List<*>).map { id -> id.toString() } }
        assertEquals(1, ids.size)
        assertEquals(1, pushed.count { it["t"] == "notify.post" })
    }

    @Test
    fun `nothing is resent while the gate is off`() {
        DeckState.notifyForward = false
        val listener = start()
        val shadow = shadowOf(listener as NotificationListenerService)
        shadow.addActiveNotification(sbn(1))
        pushed.clear()
        enableAnswered()
        settle(listener)
        assertTrue("no post and no marker while sharing is off", pushed.isEmpty())
    }
}
