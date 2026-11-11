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
 * Row 6 (NOTIFY-19, r3): a progress bar that only moves is not news. The
 * listener re-posts the same notification for every tick with a changed text
 * ("12 MB of 50 MB" → "13 MB of 50 MB") and an unchanged title; the first and
 * the post that drops the bar alert, the ticks between them do not.
 */
@RunWith(AndroidJUnit4::class)
@Config(sdk = [34])
class NotifyProgressTickTest {

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

    /** A download: one id, a progress bar, a title that stays and a text that moves. */
    private fun sbn(text: String, progress: Int?): StatusBarNotification {
        val builder = Notification.Builder(ctx, "test")
            .setContentTitle("Download")
            .setContentText(text)
            .setSmallIcon(android.R.drawable.ic_dialog_info)
        if (progress != null) {
            builder.setProgress(100, progress, false)
        }
        val sbn = Shadow.newInstanceOf(StatusBarNotification::class.java)
        ReflectionHelpers.setField(sbn, "pkg", "com.example.downloader")
        ReflectionHelpers.setField(sbn, "opPkg", "com.example.downloader")
        ReflectionHelpers.setField(sbn, "id", 7)
        ReflectionHelpers.setField(sbn, "uid", 1000)
        ReflectionHelpers.setField(sbn, "initialPid", 1000)
        ReflectionHelpers.setField(sbn, "notification", builder.build())
        ReflectionHelpers.setField(sbn, "postTime", System.currentTimeMillis())
        ReflectionHelpers.setField(sbn, "user", Process.myUserHandle())
        return sbn
    }

    private fun alertOf(index: Int): Boolean {
        val posts = pushed.filter { it["t"] == "notify.post" }
        return posts[index]["alert"] as Boolean
    }

    @Test
    fun `only the bar moving is quiet, the post that drops it alerts`() {
        val listener = start()
        listener.onNotificationPosted(sbn("12 MB of 50 MB", 24))
        settle(listener)
        listener.onNotificationPosted(sbn("13 MB of 50 MB", 26))
        settle(listener)
        listener.onNotificationPosted(sbn("14 MB of 50 MB", 28))
        settle(listener)
        listener.onNotificationPosted(sbn("Download complete", null))
        settle(listener)
        assertEquals(4, pushed.count { it["t"] == "notify.post" })
        assertEquals("the first post alerts", true, alertOf(0))
        assertEquals("a tick whose title stayed is quiet", false, alertOf(1))
        assertEquals("another tick is quiet too", false, alertOf(2))
        assertEquals("the post that drops the bar alerts", true, alertOf(3))
    }

    @Test
    fun `a new title on a moving bar alerts`() {
        val listener = start()
        listener.onNotificationPosted(sbn("12 MB of 50 MB", 24))
        settle(listener)
        // The app retitled it: something new to say.
        val renamed = sbn("12 MB of 50 MB", 24)
        val notification = ReflectionHelpers.getField<Notification>(renamed, "notification")
        notification.extras.putCharSequence(Notification.EXTRA_TITLE, "Download failed, retrying")
        listener.onNotificationPosted(renamed)
        settle(listener)
        assertEquals(true, alertOf(1))
    }
}
