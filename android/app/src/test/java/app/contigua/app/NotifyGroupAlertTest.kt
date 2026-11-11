package app.contigua.app

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
import org.junit.Assert.assertEquals
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
 * Row 13 (NOTIFY-20, r3): the group's alerting mode. A summary forwarded alone
 * (no children on the Mac) is quiet when the app asked for children-only
 * alerts, and the child that supersedes a summary still alerts.
 */
@RunWith(AndroidJUnit4::class)
@Config(sdk = [34])
class NotifyGroupAlertTest {

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

    private fun sbn(
        id: Int,
        title: String,
        text: String,
        group: String? = null,
        alertBehavior: Int = Notification.GROUP_ALERT_ALL,
        summary: Boolean = false,
    ): StatusBarNotification {
        val builder = Notification.Builder(ctx, "test")
            .setContentTitle(title)
            .setContentText(text)
            .setSmallIcon(android.R.drawable.ic_dialog_info)
            .setGroupAlertBehavior(alertBehavior)
        if (group != null) builder.setGroup(group)
        val notification = builder.build()
        if (summary) notification.flags = notification.flags or Notification.FLAG_GROUP_SUMMARY
        val sbn = Shadow.newInstanceOf(StatusBarNotification::class.java)
        ReflectionHelpers.setField(sbn, "pkg", "com.example.chat")
        ReflectionHelpers.setField(sbn, "opPkg", "com.example.chat")
        ReflectionHelpers.setField(sbn, "id", id)
        ReflectionHelpers.setField(sbn, "uid", 1000)
        ReflectionHelpers.setField(sbn, "initialPid", 1000)
        ReflectionHelpers.setField(sbn, "notification", notification)
        ReflectionHelpers.setField(sbn, "postTime", System.currentTimeMillis())
        ReflectionHelpers.setField(sbn, "user", Process.myUserHandle())
        ReflectionHelpers.setField(sbn, "groupKey", group)
        return sbn
    }

    private fun posts(): List<Map<String, Any?>> = pushed.filter { it["t"] == "notify.post" }

    @Test
    fun `a lone summary that asked for children-only alerts is quiet`() {
        val listener = start()
        listener.onNotificationPosted(
            sbn(1, "Chat", "3 new messages", group = "chat",
                alertBehavior = Notification.GROUP_ALERT_CHILDREN, summary = true),
        )
        settle(listener)
        assertEquals(1, posts().size)
        assertEquals("the summary is listed, not presented", false, posts()[0]["alert"])
    }

    @Test
    fun `a lone summary that asked for a summary alert still alerts`() {
        val listener = start()
        listener.onNotificationPosted(
            sbn(2, "Chat", "3 new messages", group = "chat",
                alertBehavior = Notification.GROUP_ALERT_SUMMARY, summary = true),
        )
        settle(listener)
        assertEquals(1, posts().size)
        assertEquals(true, posts()[0]["alert"])
    }

    @Test
    fun `a child that supersedes a summary still alerts`() {
        val listener = start()
        listener.onNotificationPosted(
            sbn(3, "Chat", "3 new messages", group = "chat",
                alertBehavior = Notification.GROUP_ALERT_SUMMARY, summary = true),
        )
        settle(listener)
        pushed.clear()
        listener.onNotificationPosted(
            sbn(4, "Chat", "one more", group = "chat",
                alertBehavior = Notification.GROUP_ALERT_SUMMARY),
        )
        settle(listener)
        val events = pushed.map { it["t"] }
        assertEquals("the summary goes first", listOf("notify.remove", "notify.post"), events)
        assertEquals(true, posts()[0]["alert"])
    }
}
