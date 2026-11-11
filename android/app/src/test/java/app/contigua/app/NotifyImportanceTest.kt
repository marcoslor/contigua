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
 * Rows 5/20 (NOTIFY-21, r3): a LOW or MIN channel is listed quietly and never
 * presents; DEFAULT and HIGH keep today's rules. The ranking is stubbed where
 * the system would answer; the log carries the number, never a channel name.
 */
@RunWith(AndroidJUnit4::class)
@Config(sdk = [34])
class NotifyImportanceTest {

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
        notifyImportanceForTest = null
        DeckState.notifyForward = false
        DeckState.notifyChanged()
    }

    private fun start(importance: Int?): PdNotificationListener {
        notifyImportanceForTest = { importance }
        val controller = Robolectric.buildService(PdNotificationListener::class.java).create()
        service = controller
        return controller.get()
    }

    private fun settle(listener: PdNotificationListener) {
        val worker = ReflectionHelpers.getField<HandlerThread>(listener, "worker")
        val looper = shadowOf(worker.looper)
        repeat(2) { looper.idleFor(1, TimeUnit.SECONDS) }
    }

    private fun sbn(id: Int, title: String, text: String): StatusBarNotification {
        val notification = Notification.Builder(ctx, "test")
            .setContentTitle(title)
            .setContentText(text)
            .setSmallIcon(android.R.drawable.ic_dialog_info)
            .build()
        val sbn = Shadow.newInstanceOf(StatusBarNotification::class.java)
        ReflectionHelpers.setField(sbn, "pkg", "com.example.chat")
        ReflectionHelpers.setField(sbn, "opPkg", "com.example.chat")
        ReflectionHelpers.setField(sbn, "id", id)
        ReflectionHelpers.setField(sbn, "uid", 1000)
        ReflectionHelpers.setField(sbn, "initialPid", 1000)
        ReflectionHelpers.setField(sbn, "notification", notification)
        ReflectionHelpers.setField(sbn, "postTime", System.currentTimeMillis())
        ReflectionHelpers.setField(sbn, "user", Process.myUserHandle())
        return sbn
    }

    private fun alert(index: Int): Boolean =
        pushed.filter { it["t"] == "notify.post" }[index]["alert"] as Boolean

    @Test
    fun `a low channel is listed quietly`() {
        val listener = start(NotifyEvents.IMPORTANCE_LOW)
        listener.onNotificationPosted(sbn(1, "Chat", "one"))
        settle(listener)
        assertEquals(1, pushed.count { it["t"] == "notify.post" })
        assertEquals("LOW never presents", false, alert(0))
    }

    @Test
    fun `a min channel is listed quietly too, never dropped`() {
        val listener = start(NotifyEvents.IMPORTANCE_MIN)
        listener.onNotificationPosted(sbn(2, "Chat", "two"))
        settle(listener)
        assertEquals("MIN is shown in the shade's silent section", 1, pushed.count { it["t"] == "notify.post" })
        assertEquals(false, alert(0))
    }

    @Test
    fun `default and high keep today's rules`() {
        val listener = start(NotifyEvents.IMPORTANCE_DEFAULT)
        listener.onNotificationPosted(sbn(3, "Chat", "three"))
        settle(listener)
        assertEquals(true, alert(0))
        notifyImportanceForTest = { NotifyEvents.IMPORTANCE_HIGH }
        listener.onNotificationPosted(sbn(4, "Chat", "four"))
        settle(listener)
        assertEquals(true, alert(1))
    }

    @Test
    fun `an unreadable ranking keeps today's rules`() {
        val listener = start(null)
        listener.onNotificationPosted(sbn(5, "Chat", "five"))
        settle(listener)
        assertTrue("the post still goes", pushed.any { it["t"] == "notify.post" })
        assertEquals(true, alert(0))
    }
}
