package app.contigua.app

import android.app.Notification
import android.app.Person
import android.content.Context
import android.os.HandlerThread
import android.os.Process
import android.service.notification.StatusBarNotification
import android.text.SpannableString
import android.text.Spanned
import android.text.style.StyleSpan
import android.text.style.URLSpan
import android.graphics.Typeface
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
 * ISS-43: an app may post its title and text as a SpannableString (bold, a
 * link, a colour). `Bundle.getString` returns null for those — Android logs
 * "Key android.title expected String but value was a android.text.SpannableString"
 * — so the banner arrived without its content. Every text extra is read as a
 * CharSequence and converted to plain text.
 */
@RunWith(AndroidJUnit4::class)
@Config(sdk = [34])
class NotifyStyledTextTest {

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

    /** Bold plus a link, the shape that made `getString` return null. */
    private fun styled(text: String): SpannableString = SpannableString(text).apply {
        setSpan(StyleSpan(Typeface.BOLD), 0, 1, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
        setSpan(URLSpan("https://example.invalid/x"), 1, text.length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
    }

    private fun sbn(id: Int, notification: Notification): StatusBarNotification {
        val sbn = Shadow.newInstanceOf(StatusBarNotification::class.java)
        ReflectionHelpers.setField(sbn, "pkg", "com.example.styled")
        ReflectionHelpers.setField(sbn, "opPkg", "com.example.styled")
        ReflectionHelpers.setField(sbn, "id", id)
        ReflectionHelpers.setField(sbn, "uid", 1000)
        ReflectionHelpers.setField(sbn, "initialPid", 1000)
        ReflectionHelpers.setField(sbn, "notification", notification)
        ReflectionHelpers.setField(sbn, "postTime", System.currentTimeMillis())
        ReflectionHelpers.setField(sbn, "user", Process.myUserHandle())
        return sbn
    }

    private fun notification(): Notification =
        Notification.Builder(ctx, "test")
            .setSmallIcon(android.R.drawable.ic_dialog_info)
            .build()

    private fun posts(): List<Map<String, Any?>> = pushed.filter { it["t"] == "notify.post" }

    @Test
    fun `a styled title and text arrive as plain text`() {
        val listener = start()
        val notification = notification()
        notification.extras.putCharSequence(Notification.EXTRA_TITLE, styled("Release notes"))
        notification.extras.putCharSequence(Notification.EXTRA_TEXT, styled("Build 140 is ready"))
        listener.onNotificationPosted(sbn(1, notification))
        settle(listener)
        assertEquals(1, posts().size)
        assertEquals("Release notes", posts()[0]["title"])
        assertEquals("Build 140 is ready", posts()[0]["text"])
    }

    @Test
    fun `a styled big title and big text arrive as plain text`() {
        val listener = start()
        val notification = notification()
        notification.extras.putCharSequence(Notification.EXTRA_TITLE_BIG, styled("Big title"))
        notification.extras.putCharSequence(Notification.EXTRA_BIG_TEXT, styled("Big body"))
        listener.onNotificationPosted(sbn(2, notification))
        settle(listener)
        assertEquals(1, posts().size)
        assertEquals("Big title", posts()[0]["title"])
        assertEquals("Big body", posts()[0]["text"])
    }

    /**
     * Sub text is the header line (often the account), never the body: a post
     * with a title and only a sub text has no text, as before ISS-43.
     */
    @Test
    fun `a sub text or summary text is not the body`() {
        val listener = start()
        val notification = notification()
        notification.extras.putCharSequence(Notification.EXTRA_TITLE, styled("Downloading"))
        notification.extras.putCharSequence(Notification.EXTRA_SUB_TEXT, styled("3 of 10 files"))
        notification.extras.putCharSequence(Notification.EXTRA_SUMMARY_TEXT, styled("3 new messages"))
        listener.onNotificationPosted(sbn(3, notification))
        settle(listener)
        // A title-only post may be sent or skipped as contentless; either way
        // neither header line becomes its text.
        assertTrue("posts: ${posts().size}", posts().size <= 1)
        posts().firstOrNull()?.let { post ->
            assertEquals("Downloading", post["title"])
            assertTrue("text was ${post["text"]}", post["text"] == null || post["text"] == "")
        }
    }

    @Test
    fun `a styled conversation title arrives as plain text`() {
        val me = Person.Builder().setName("Me").build()
        val style = Notification.MessagingStyle(me)
            .addMessage("first", 1_700_000_000_000, Person.Builder().setName("Ada").build())
        val notification = Notification.Builder(ctx, "test")
            .setStyle(style)
            .setSmallIcon(android.R.drawable.ic_dialog_info)
            .build()
        notification.extras.remove(Notification.EXTRA_TITLE)
        notification.extras.remove(Notification.EXTRA_TITLE_BIG)
        notification.extras.putCharSequence(
            Notification.EXTRA_CONVERSATION_TITLE,
            styled("Team chat"),
        )
        val listener = start()
        listener.onNotificationPosted(sbn(5, notification))
        settle(listener)
        assertEquals(1, posts().size)
        assertEquals("Team chat", posts()[0]["title"])
        assertEquals("first", posts()[0]["text"])
    }
}
