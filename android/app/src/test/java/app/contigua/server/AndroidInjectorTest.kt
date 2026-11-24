package app.contigua.server

import android.content.ClipData
import android.content.ClipDescription
import android.net.Uri
import android.view.KeyEvent
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

/**
 * The injector's KEY path, which `ui.type`'s keys and the Mac's KEY frames
 * share, and the person's own `text` path (WIN-80): a run the key map cannot
 * type goes in by set text when the focused field takes it; otherwise it is
 * pasted through the clipboard, and the person's whole clip is put back, or
 * nothing is pasted. These drive the real [AndroidInjector] and
 * [ShellClipboard] over a fake IClipboard, not a copy of them.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class AndroidInjectorTest {

    /** `InputManager.INJECT_INPUT_EVENT_MODE_WAIT_FOR_FINISH`. */
    private val waitForFinish = 2

    private fun keysDelivered(): Pair<AndroidInjector, MutableList<KeyEvent>> {
        val events = mutableListOf<KeyEvent>()
        return AndroidInjector(log = {}, sink = { e, _ -> events += e as KeyEvent }) to events
    }

    /**
     * B5's emulator proof typed "X" by keys right after a set-text insert and
     * read back a lowercase x: the injector built `KeyEvent(down, time, action,
     * code, metaState)`, whose fifth argument is the repeat count, so the key
     * map's SHIFT never reached the app (a full keyboard reads only the event's
     * own meta).
     */
    @Test
    fun testUiTypeKeysKeepTheKeyMapsShift() { // [MCP-109]
        val (injector, events) = keysDelivered()
        val strokes = injector.keyStrokes("X")
        assertNotNull("X has keys in the virtual key map", strokes)
        for (s in strokes!!) injector.key(0, s.action, s.keycode, s.metaState, 5L, 5L)
        val x = events.first { it.keyCode == KeyEvent.KEYCODE_X && it.action == KeyEvent.ACTION_DOWN }
        assertTrue("the X down carries SHIFT", x.isShiftPressed)
        assertEquals("a fresh press, not a repeat", 0, x.repeatCount)
        assertEquals('X'.code, x.getUnicodeChar(x.metaState))
    }

    /**
     * B5's MCP-110 proof copies the field's text with ctrl+A, ctrl+C sent as
     * KEY frames before the run: with the meta dropped they typed "a" and "c"
     * and nothing was copied, so the clip pasted after the run never matched.
     */
    @Test
    fun testAKeyFramesCtrlReachesTheApp() { // [MCP-110]
        val (injector, events) = keysDelivered()
        val ctrl = KeyEvent.META_CTRL_ON or KeyEvent.META_CTRL_LEFT_ON
        injector.key(0, KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_C, ctrl, 7L, 7L)
        injector.key(0, KeyEvent.ACTION_UP, KeyEvent.KEYCODE_C, ctrl, 7L, 8L)
        assertEquals(listOf(ctrl, ctrl), events.map { it.metaState })
        assertTrue("ctrl+C is a shortcut, so the app copies", events[0].isCtrlPressed)
        assertEquals(listOf(0, 0), events.map { it.repeatCount })
        assertEquals(listOf(7L, 7L), events.map { it.downTime })
        assertEquals(listOf(7L, 8L), events.map { it.eventTime })
    }

    /** A clipboard holding an image clip (no text) until something writes text over it. */
    private class ImageClipboard : ClipboardPort {
        @Volatile var holdsTheImage = true
        override fun getText(): ClipText? = null
        override fun setText(text: String) {
            holdsTheImage = false
        }
        override fun listen(onChange: () -> Unit): ClipRegistration = ClipRegistration(onChange)
        override fun stop(registration: ClipRegistration?) = Unit
    }

    /**
     * The hidden IClipboard as the shell user sees it: it holds a whole
     * [ClipData], hands it back on a read and takes one on a write. With
     * [refuseUris] a write of a clip carrying a content URI throws, as the
     * system does when the shell may not hand that URI back.
     */
    private class FakeService(@Volatile var clip: ClipData?) : ClipboardService {
        @Volatile var refuseUris = false
        val gets = AtomicInteger()
        val sets = CopyOnWriteArrayList<ClipData>()
        /** Called after every accepted write, with the clip now held. */
        @Volatile var onSet: (ClipData) -> Unit = {}

        fun text(): String? = clip?.takeIf { it.itemCount > 0 }?.getItemAt(0)?.text?.toString()

        override fun getPrimaryClip(packageName: String, uid: Int): ClipData? {
            gets.incrementAndGet()
            return clip
        }

        override fun getPrimaryClipDescription(packageName: String, uid: Int): ClipDescription? = clip?.description

        override fun setPrimaryClip(clip: ClipData, packageName: String, uid: Int) {
            if (refuseUris && (0 until clip.itemCount).any { clip.getItemAt(it).uri != null }) {
                throw SecurityException("synthetic: the shell may not grant this uri")
            }
            sets += clip
            this.clip = clip
            onSet(clip)
        }

        override fun addClipListener(listener: ClipChangeListener): Boolean = true
        override fun removeClipListener(listener: ClipChangeListener) = Unit
    }

    /** The focused node: what it holds, and what was done to it. */
    private class Focus(override val field: TextEntry.Field) : TextEntry.Focus {
        val actions = CopyOnWriteArrayList<String>()
        override fun setText(text: String): Boolean {
            actions += "set_text:$text"
            return true
        }
        override fun setSelection(start: Int, end: Int): Boolean {
            actions += "set_selection:$start,$end"
            return true
        }
    }

    /** The UI tree's focused field of every display: always [focus]. */
    private class Fields(private val focus: TextEntry.Focus?) : FocusedFieldSource {
        override fun <T> withFocus(displayId: Int, block: (TextEntry.Focus?) -> T): T? = block(focus)
    }

    private fun imageClip(): ClipData = ClipData(
        ClipDescription("person-image", arrayOf("image/png")),
        ClipData.Item(Uri.parse("content://synthetic.other.app/images/1")),
    )

    private fun textClip(text: String): ClipData =
        ClipData(ClipDescription("person-text", arrayOf("text/plain")), ClipData.Item(text))

    private fun noSetText(): Focus = Focus(TextEntry.Field("ab", 2, 2, setsText = false))

    private fun shell(service: ClipboardService, uid: Int = SHELL_UID, log: (String) -> Unit = {}) =
        ShellClipboard(ctx = null, log = log, callerUid = uid, service = service)

    /** Waits up to 3 s for [condition]; the restore runs a moment after the paste. */
    private fun eventually(condition: () -> Boolean): Boolean {
        val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(3)
        while (System.nanoTime() < deadline) {
            if (condition()) return true
            Thread.sleep(20) // real-time: the restore runs on the injector's own executor
        }
        return condition()
    }

    private fun sameClip(expected: ClipData, actual: ClipData?) {
        assertNotNull("the clipboard holds a clip", actual)
        actual!!
        assertEquals("the same label", expected.description.label, actual.description.label)
        assertEquals("the same MIME types",
            (0 until expected.description.mimeTypeCount).map { expected.description.getMimeType(it) },
            (0 until actual.description.mimeTypeCount).map { actual.description.getMimeType(it) })
        assertEquals("the same item count", expected.itemCount, actual.itemCount)
        for (i in 0 until expected.itemCount) {
            assertEquals("item $i's uri", expected.getItemAt(i).uri, actual.getItemAt(i).uri)
            assertEquals("item $i's text", expected.getItemAt(i).text?.toString(), actual.getItemAt(i).text?.toString())
        }
    }

    /**
     * #173: the person's typing pasted through the clipboard never put a
     * non-text clip back, so a copied image was lost. Now nothing in this path
     * writes text over a clipboard it cannot put back whole.
     */
    @Test
    fun testANonTextClipSurvivesTyping() { // [MCP-110]
        val clipboard = ImageClipboard()
        val injector = AndroidInjector(log = {}, sink = { _, _ -> }, clipboard = clipboard)
        injector.text(0, "café")
        // The paste path restores 400 ms after the paste; wait past it.
        Thread.sleep(800) // real-time: the old paste path restores the clip 400 ms later on a real executor
        assertTrue("the person's image clip is still on the clipboard", clipboard.holdsTheImage)
    }

    @Test
    fun testTextGoesInBySetTextWhenTheFieldTakesIt() { // [WIN-80]
        val service = FakeService(imageClip())
        val keys = CopyOnWriteArrayList<Int>()
        val focus = Focus(TextEntry.Field("ab", 2, 2))
        val injector = AndroidInjector(
            log = {},
            sink = { e, _ -> if (e is KeyEvent && e.action == KeyEvent.ACTION_DOWN) keys += e.keyCode },
            clipboard = shell(service),
            fields = Fields(focus),
        )

        injector.text(0, "é")

        assertEquals("the run is set whole, the cursor after it",
            listOf("set_text:abé", "set_selection:3,3"), focus.actions.toList())
        assertFalse("no paste key", keys.contains(KeyEvent.KEYCODE_PASTE))
        Thread.sleep(600) // real-time: past any deferred clipboard restore
        assertEquals("no clipboard read", 0, service.gets.get())
        assertEquals("no clipboard write", 0, service.sets.size)
    }

    /**
     * A clip that carries a URI (an image, a file) is never pasted over: the
     * shell may set a URI clip back only while it is the current clip, so once
     * the typing clip replaced it no trial proves it would come back (T14's
     * emulator boot 1; lead, 2026-11-22). The run is dropped and the clip is
     * never written, not even with itself.
     */
    @Test
    fun testAClipCarryingAUriIsNeverPastedOver() { // [WIN-80]
        val image = imageClip()
        val service = FakeService(image)
        val logs = CopyOnWriteArrayList<String>()
        val keys = CopyOnWriteArrayList<Int>()
        val injector = AndroidInjector(
            log = { logs += it },
            sink = { e, _ -> if (e is KeyEvent) keys += e.keyCode },
            clipboard = shell(service, log = { logs += it }),
            fields = Fields(noSetText()),
        )

        injector.text(0, "\u00e9")

        Thread.sleep(600) // real-time: past any deferred clipboard restore
        assertFalse("nothing pasted over a uri clip", keys.contains(KeyEvent.KEYCODE_PASTE))
        assertTrue("nothing written over a uri clip", service.sets.isEmpty())
        sameClip(image, service.clip)
        assertTrue("the drop is logged", logs.isNotEmpty())
        assertTrue("the log carries no typed text", logs.none { it.contains("\u00e9") })
    }

    @Test
    fun testATextClipGetsThePasteAndComesBack() { // [WIN-80]
        val previous = textClip("synthetic-previous-" + "g".repeat(4))
        val service = FakeService(previous)
        val pasted = CopyOnWriteArrayList<String?>()
        val injector = AndroidInjector(
            log = {},
            sink = { e, _ ->
                if (e is KeyEvent && e.action == KeyEvent.ACTION_DOWN && e.keyCode == KeyEvent.KEYCODE_PASTE) {
                    pasted += service.text()
                }
            },
            clipboard = shell(service),
            fields = Fields(noSetText()),
        )

        injector.text(0, "\u00e9")

        assertEquals("the run was pasted from a clip holding it", listOf<String?>("\u00e9"), pasted.toList())
        assertTrue("the person's clip is back",
            eventually { service.clip?.description?.label == previous.description.label })
        sameClip(previous, service.clip)
    }

    @Test
    fun testAClipThatCannotBePutBackIsNotPasted() { // [WIN-80]
        // A URI the shell cannot hand back.
        val image = imageClip()
        val service = FakeService(image).apply { refuseUris = true }
        val logs = CopyOnWriteArrayList<String>()
        val keys = CopyOnWriteArrayList<Int>()
        val sink = { e: android.view.InputEvent, _: Int -> if (e is KeyEvent) keys += e.keyCode }
        val injector = AndroidInjector(
            log = { logs += it }, sink = sink, clipboard = shell(service, log = { logs += it }), fields = Fields(noSetText()),
        )

        injector.text(0, "ação")

        Thread.sleep(600) // real-time: past any deferred clipboard restore
        assertFalse("nothing pasted", keys.contains(KeyEvent.KEYCODE_PASTE))
        sameClip(image, service.clip)
        assertTrue("the drop is logged", logs.isNotEmpty())
        assertTrue("the log carries no typed text", logs.none { it.contains("ç") || it.contains("ã") || it.contains("ação") })

        // A clip the system will not let it read: root, with no shell-user reader.
        val atRoot = FakeService(textClip("synthetic-person-clip"))
        val rootKeys = CopyOnWriteArrayList<Int>()
        val rootInjector = AndroidInjector(
            log = {},
            sink = { e, _ -> if (e is KeyEvent) rootKeys += e.keyCode },
            clipboard = shell(atRoot, uid = 0),
            fields = Fields(noSetText()),
        )
        rootInjector.text(0, "é")
        Thread.sleep(600) // real-time: past any deferred clipboard restore
        assertFalse("nothing pasted at root", rootKeys.contains(KeyEvent.KEYCODE_PASTE))
        assertEquals("the clip is untouched at root", 0, atRoot.sets.size)
        assertEquals("the person's clip", "synthetic-person-clip", atRoot.text())
    }

    @Test
    fun testTwoInterleavedFallbacksEachPasteTheirOwnText() { // [WIN-80]
        val service = FakeService(textClip("synthetic-person-clip"))
        val secondSet = CountDownLatch(1)
        service.onSet = { clip -> if (clip.getItemAt(0).text?.toString() == "ü") secondSet.countDown() }
        val pastes = ConcurrentHashMap<String, String>()
        lateinit var injector: AndroidInjector
        val second = Thread({ injector.text(0, "ü") }, "second")
        injector = AndroidInjector(
            log = {},
            sink = { e, _ ->
                if (e is KeyEvent && e.action == KeyEvent.ACTION_DOWN && e.keyCode == KeyEvent.KEYCODE_PASTE) {
                    val name = Thread.currentThread().name
                    if (name == "first") {
                        // The second run starts while the first is mid-paste.
                        second.start()
                        secondSet.await(500, TimeUnit.MILLISECONDS)
                    }
                    pastes[name] = service.text() ?: "<none>"
                }
            },
            clipboard = shell(service),
            fields = Fields(noSetText()),
        )

        val first = Thread({ injector.text(0, "é") }, "first")
        first.start()
        first.join(5_000)
        assertTrue("the second run started", eventually { second.state != Thread.State.NEW })
        second.join(5_000)

        assertEquals("the first run pasted its own text", "é", pastes["first"])
        assertEquals("the second run pasted its own text", "ü", pastes["second"])
        assertTrue("the person's clip is back", eventually { service.text() == "synthetic-person-clip" })
    }

    @Test
    fun testTheFallbackClipIsNotShared() { // [WIN-80]
        val service = FakeService(textClip("synthetic-person-clip"))
        val port = shell(service)
        val atPaste = CopyOnWriteArrayList<String?>()
        val shared = CopyOnWriteArrayList<ClipText?>()
        val injector = AndroidInjector(
            log = {},
            sink = { e, _ ->
                if (e is KeyEvent && e.action == KeyEvent.ACTION_DOWN && e.keyCode == KeyEvent.KEYCODE_PASTE) {
                    atPaste += service.text()
                    // What the SHARE-1 watcher reads on the change the paste's clip made.
                    shared += port.getText()
                }
            },
            clipboard = port,
            fields = Fields(noSetText()),
        )

        injector.text(0, "é")

        assertEquals("the temporary clip held the run", listOf<String?>("é"), atPaste.toList())
        assertEquals("the watcher reads no text to send", 1, shared.size)
        assertNull("the temporary clip is not shared", shared[0])
        assertTrue("the person's clip is back", eventually { service.text() == "synthetic-person-clip" })
        assertEquals("the person's clip is shared as before", "synthetic-person-clip", port.getText()?.text)
    }

    /**
     * Review of #176 (lead, 2026-11-23): the app handles the paste key when
     * its turn comes, which on a slow app is after the restore's 400 ms, so
     * it pasted the person's own clip into the field. The clip goes back only
     * once the app has finished the paste key.
     */
    @Test(timeout = 15_000)
    fun testTheClipComesBackOnlyAfterTheAppHandledThePaste() { // [WIN-80]
        val previous = textClip("synthetic-previous-" + "h".repeat(4))
        val service = FakeService(previous)
        val pasted = CopyOnWriteArrayList<String?>()
        // The app: one input queue, handled in order; its paste reads the clip 600 ms late.
        val app = Executors.newSingleThreadExecutor()
        val injector = AndroidInjector(
            log = {},
            injected = { e, _, mode ->
                val handled = app.submit {
                    if (e is KeyEvent && e.action == KeyEvent.ACTION_DOWN && e.keyCode == KeyEvent.KEYCODE_PASTE) {
                        Thread.sleep(600) // real-time: a slow app
                        pasted += service.text()
                    }
                }
                // Wait-for-finish returns once the app handled the event.
                if (mode == waitForFinish) handled.get()
            },
            clipboard = shell(service),
            fields = Fields(noSetText()),
        )
        try {
            injector.text(0, "\u00e9")
            assertTrue("the app handled the paste", eventually { pasted.isNotEmpty() })
            assertEquals("the app pasted the run, not the person's clip", listOf<String?>("\u00e9"), pasted.toList())
            assertTrue("the person's clip is back",
                eventually { service.clip?.description?.label == previous.description.label })
        } finally {
            app.shutdownNow()
        }
    }

    /**
     * Review of #176 (lead, 2026-11-23): a clip copied while the paste runs
     * (by the person, or from the Mac) is the newest clip. The restore leaves
     * it and never writes the older clip over it.
     */
    @Test
    fun testAClipCopiedDuringThePasteIsNotOverwritten() { // [WIN-80]
        val service = FakeService(textClip("synthetic-previous-" + "k".repeat(4)))
        val newer = ClipData(ClipDescription("person-newer", arrayOf("text/plain")), ClipData.Item("synthetic-newer"))
        val injector = AndroidInjector(
            log = {},
            sink = { e, _ ->
                if (e is KeyEvent && e.action == KeyEvent.ACTION_UP && e.keyCode == KeyEvent.KEYCODE_PASTE) {
                    service.clip = newer
                }
            },
            clipboard = shell(service),
            fields = Fields(noSetText()),
        )

        injector.text(0, "\u00e9")

        Thread.sleep(900) // real-time: past the deferred restore
        assertEquals("the newer clip stays", "synthetic-newer", service.text())
    }
}
