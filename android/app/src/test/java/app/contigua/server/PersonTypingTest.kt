package app.contigua.server

import android.app.UiAutomation
import android.content.ClipData
import android.content.ClipDescription
import android.content.Context
import android.os.Looper
import android.view.InputEvent
import android.view.KeyEvent
import androidx.test.core.app.ApplicationProvider
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

/**
 * The person's typing (WIN-80) in order and without stalling the reader: a
 * key sent before a set-text run lands before the field is read, and a busy
 * UI tree is waited on for a short bound only, then counts as unreadable.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class PersonTypingTest {

    /**
     * A focused field in an app that handles its input queue only when it
     * gets to it: an async injection is queued, and an injection that waits
     * for the app to finish (`INJECT_MODE_WAIT_FOR_FINISH`) is handled with
     * everything queued before it, in order. Letters insert at the cursor.
     */
    private class SlowApp {
        private val queue = ArrayList<KeyEvent>()
        @Volatile var text = ""
        @Volatile var cursor = 0

        @Synchronized fun inject(e: InputEvent, mode: Int) {
            if (e is KeyEvent) queue += KeyEvent(e)
            if (mode == WAIT_FOR_FINISH) handle()
        }

        @Synchronized fun handle() {
            for (e in queue) {
                if (e.action != KeyEvent.ACTION_DOWN) continue
                if (e.keyCode !in KeyEvent.KEYCODE_A..KeyEvent.KEYCODE_Z) continue
                val ch = 'a' + (e.keyCode - KeyEvent.KEYCODE_A)
                text = text.substring(0, cursor) + ch + text.substring(cursor)
                cursor += 1
            }
            queue.clear()
        }

        /** The node as the tree reads it now: only what the app has handled. */
        val focus = object : TextEntry.Focus {
            override val field: TextEntry.Field
                get() = TextEntry.Field(text, cursor, cursor)
            override fun setText(text: String): Boolean {
                this@SlowApp.text = text
                return true
            }
            override fun setSelection(start: Int, end: Int): Boolean {
                cursor = start
                return true
            }
        }
    }

    private class Fields(private val focus: TextEntry.Focus?) : FocusedFieldSource {
        override fun <T> withFocus(displayId: Int, block: (TextEntry.Focus?) -> T): T? = block(focus)
    }

    @Test
    fun testAKeySentBeforeASetTextRunLandsFirst() { // [WIN-80]
        // The Mac's KEY frame for "a", then a `text` message for "é", fast.
        val app = SlowApp()
        val injector = AndroidInjector(
            log = {}, injected = { e, _, mode -> app.inject(e, mode) }, fields = Fields(app.focus),
        )
        injector.key(0, KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_A, 0, 1L, 1L)
        injector.key(0, KeyEvent.ACTION_UP, KeyEvent.KEYCODE_A, 0, 1L, 2L)
        injector.text(0, "é")
        app.handle() // the app catches up with whatever is still queued
        assertEquals("the key landed before the run was set", "aé", app.text)

        // One `text` message mixing a key-map run and a set-text run.
        val mixed = SlowApp()
        val second = AndroidInjector(
            log = {}, injected = { e, _, mode -> mixed.inject(e, mode) }, fields = Fields(mixed.focus),
        )
        second.text(0, "bé")
        mixed.handle()
        assertEquals("the message's own key landed before its run was set", "bé", mixed.text)
    }

    /** The shell user's IClipboard holding the person's text clip. */
    private class TextService(@Volatile var clip: ClipData?) : ClipboardService {
        override fun getPrimaryClip(packageName: String, uid: Int): ClipData? = clip
        override fun getPrimaryClipDescription(packageName: String, uid: Int): ClipDescription? = clip?.description
        override fun setPrimaryClip(clip: ClipData, packageName: String, uid: Int) {
            this.clip = clip
        }
        override fun addClipListener(listener: ClipChangeListener): Boolean = true
        override fun removeClipListener(listener: ClipChangeListener) = Unit
    }

    @Test
    fun testABusyTreeIsWaitedOnBrieflyThenTakesTheFallback() { // [WIN-80]
        val tree = UiAutomationTree(log = {})
        val held = CountDownLatch(1)
        val release = CountDownLatch(1)
        // Another reader (an agent's ui.tree, say) holds the tree for 3 s.
        val holder = Thread {
            tree.readLock.lock()
            try {
                held.countDown()
                release.await(3, TimeUnit.SECONDS)
            } finally {
                tree.readLock.unlock()
            }
        }
        holder.start()
        assertTrue("the holder has the tree", held.await(2, TimeUnit.SECONDS))

        var ran = false
        val started = System.nanoTime()
        val answer = tree.withFocus(0) { ran = true; "read" }
        val waitedMs = TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - started)
        assertEquals("a busy tree answers unreadable", null, answer)
        assertFalse("nothing ran on the busy tree", ran)
        assertTrue("the wait is bounded (waited $waitedMs ms)", waitedMs < 1_000)

        // The person's run takes the fallback under its guards: a text clip, pasted and put back.
        val person = ClipData(ClipDescription("person-text", arrayOf("text/plain")), ClipData.Item("synthetic-person-clip"))
        val service = TextService(person)
        val pastes = CopyOnWriteArrayList<String?>()
        val injector = AndroidInjector(
            log = {},
            sink = { e, _ ->
                if (e is KeyEvent && e.action == KeyEvent.ACTION_DOWN && e.keyCode == KeyEvent.KEYCODE_PASTE) {
                    pastes += service.clip?.getItemAt(0)?.text?.toString()
                }
            },
            clipboard = ShellClipboard(ctx = null, log = {}, callerUid = SHELL_UID, service = service),
            fields = tree,
        )
        val typing = System.nanoTime()
        injector.text(0, "é")
        val typedMs = TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - typing)
        release.countDown()
        holder.join(5_000)
        assertTrue("the reader thread was not held by the tree (took $typedMs ms)", typedMs < 1_000)
        assertEquals("the run went in by the fallback's paste", listOf<String?>("é"), pastes.toList())
    }

    /**
     * WIN-80 bounds the person's wait for the tree at 150 ms, but only the
     * lock wait was inside it: behind it, on the session's reader thread, sat a
     * connect of up to 2.5 s and a 300 ms sleep when no window has focus, so
     * each character could hold back the person's touches and keys by that
     * much. The person's path takes the tree as it is: an unconnected tree is
     * unreadable at once and never connects, and a connected one with no
     * focused field answers without the settle sleep.
     */
    @Test
    fun testThePersonNeverWaitsForAConnectOrASettle() { // [WIN-80]
        val tree = UiAutomationTree(log = {})
        val made = automation()
        val connects = AtomicInteger()
        tree.connector = { connects.incrementAndGet(); made }
        try {
            var ran = false
            val started = System.nanoTime()
            val answer = tree.withFocus(0) { ran = true; "read" }
            val waitedMs = TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - started)
            assertEquals("an unconnected tree is unreadable", null, answer)
            assertFalse("nothing ran without a tree", ran)
            assertEquals("the person's typing never connects", 0, connects.get())
            assertTrue("answered at once (waited $waitedMs ms)", waitedMs < 150)

            // The tree connected for an agent's read; no window has focus, so
            // the settle sleep would be the price of every character typed.
            assertTrue("the agent's read connected", tree.ensureAutomation() != null)
            tree.withFocus(0) { } // a warm-up read: it pays the platform's class loading, not the tree
            val connectsBefore = connects.get()
            var ranAgain = false
            var fastest = Long.MAX_VALUE
            repeat(3) {
                val second = System.nanoTime()
                val none = tree.withFocus(0) { ranAgain = true; "read" }
                fastest = minOf(fastest, TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - second))
                assertEquals("a connected tree runs the block", "read", none)
            }
            assertTrue("the block ran", ranAgain)
            assertEquals("no second connect", connectsBefore, connects.get())
            assertTrue("no settle sleep, which alone is 300 ms (fastest $fastest ms)", fastest < 150)
        } finally {
            tree.disconnect()
        }
    }

    /** An unconnected `UiAutomation`, built the way the tree builds its own. */
    private fun automation(): UiAutomation {
        val iface = Class.forName("android.app.IUiAutomationConnection")
        val connection = Class.forName("android.app.UiAutomationConnection")
            .getDeclaredConstructor().newInstance()
        return runCatching {
            UiAutomation::class.java.getDeclaredConstructor(Context::class.java, iface)
                .newInstance(ApplicationProvider.getApplicationContext<Context>(), connection)
        }.getOrElse {
            UiAutomation::class.java.getDeclaredConstructor(Looper::class.java, iface)
                .newInstance(Looper.getMainLooper(), connection)
        }
    }

    private companion object {
        /** `InputManager.INJECT_INPUT_EVENT_MODE_WAIT_FOR_FINISH`. */
        const val WAIT_FOR_FINISH = 2
    }
}
