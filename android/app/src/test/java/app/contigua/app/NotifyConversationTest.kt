package app.contigua.app

import android.app.Notification
import android.app.Person
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
 * Row 14 (NOTIFY-3, r3): a MessagingStyle conversation carries its messages in
 * EXTRA_MESSAGES and its name in EXTRA_CONVERSATION_TITLE, so a post without a
 * plain title and text must not be dropped as contentless. The last message is
 * the body; the conversation title, else its sender, is the title.
 */
@RunWith(AndroidJUnit4::class)
@Config(sdk = [34])
class NotifyConversationTest {

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

    /** A conversation as a chat app posts it; the plain title/text fields are cleared. */
    private fun conversation(
        id: Int,
        conversationTitle: String?,
        messages: List<Pair<String, String>>,
    ): StatusBarNotification {
        val me = Person.Builder().setName("Me").build()
        val style = Notification.MessagingStyle(me)
        messages.forEachIndexed { index, (sender, text) ->
            style.addMessage(text, 1_700_000_000_000 + index, Person.Builder().setName(sender).build())
        }
        val notification = Notification.Builder(ctx, "test")
            .setStyle(style)
            .setSmallIcon(android.R.drawable.ic_dialog_info)
            .build()
        val extras = notification.extras
        extras.remove(Notification.EXTRA_TITLE)
        extras.remove(Notification.EXTRA_TITLE_BIG)
        extras.remove(Notification.EXTRA_TEXT)
        extras.remove(Notification.EXTRA_BIG_TEXT)
        extras.remove(Notification.EXTRA_CONVERSATION_TITLE)
        if (conversationTitle != null) {
            extras.putCharSequence(Notification.EXTRA_CONVERSATION_TITLE, conversationTitle)
        }
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

    private fun posts(): List<Map<String, Any?>> = pushed.filter { it["t"] == "notify.post" }

    @Test
    fun `a conversation without plain text posts its last message`() {
        val listener = start()
        listener.onNotificationPosted(
            conversation(1, "Team", listOf("Ada" to "first", "Bo" to "second")),
        )
        settle(listener)
        assertEquals(1, posts().size)
        assertEquals("Team", posts()[0]["title"])
        assertEquals("second", posts()[0]["text"])
    }

    @Test
    fun `without a conversation title the last sender names the banner`() {
        val listener = start()
        listener.onNotificationPosted(
            conversation(2, null, listOf("Ada" to "first", "Bo" to "second")),
        )
        settle(listener)
        assertEquals(1, posts().size)
        assertEquals("Bo", posts()[0]["title"])
        assertEquals("second", posts()[0]["text"])
    }

    @Test
    fun `a plain title and text still win`() {
        val listener = start()
        val posted = conversation(3, "Team", listOf("Ada" to "first"))
        val notification = ReflectionHelpers.getField<Notification>(posted, "notification")
        notification.extras.putCharSequence(Notification.EXTRA_TITLE, "Design")
        notification.extras.putCharSequence(Notification.EXTRA_TEXT, "plain text")
        listener.onNotificationPosted(posted)
        settle(listener)
        assertEquals(1, posts().size)
        assertEquals("Design", posts()[0]["title"])
        assertEquals("plain text", posts()[0]["text"])
    }

    @Test
    fun `a conversation with nothing to show is still dropped`() {
        // MessagingStyle caps a message's own text at 1024, so the wire's cap is
        // unreachable from a real conversation (NotifyEventsTest covers it for
        // a plain text); an empty conversation still has nothing to show.
        val listener = start()
        listener.onNotificationPosted(conversation(4, null, emptyList()))
        settle(listener)
        assertTrue("no title and no text: no post", pushed.none { it["t"] == "notify.post" })
    }
}
