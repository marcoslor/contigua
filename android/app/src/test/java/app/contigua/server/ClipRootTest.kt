package app.contigua.server

import android.content.ClipData
import android.content.ClipDescription
import android.view.KeyEvent
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.atomic.AtomicInteger

/**
 * ISS-27: reading the clipboard must never wipe it. AOSP's `getPrimaryClip`
 * clears the clip when the caller's UID does not own the package it names, so a
 * process with root privileges (UID 0) must not read directly. These cases drive
 * the real [ShellClipboard] and [AndroidInjector] over a fake IClipboard that
 * models that rule, not a copy of them.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class ClipRootTest : SessionFixture() {

    private fun service(): FakeClipboardService = FakeClipboardService()

    private fun shell(
        callerUid: Int,
        service: FakeClipboardService,
        helper: ClipboardHelperPort? = null,
        log: (String) -> Unit = {},
    ) = ShellClipboard(
        ctx = null,
        log = log,
        callerUid = callerUid,
        service = service,
        helper = helper,
    )

    /**
     * UID 0 without a helper: no read reaches `getPrimaryClip`, so the copy is
     * still there after the image poll and a listener dispatch. One log line
     * names the reason and never the clip.
     */
    @Test
    fun uid0WithoutHelperNeverReadsAndTheClipSurvives() {
        val service = service()
        val text = "synthetic-copy-" + "a".repeat(6)
        service.copy(text)
        val logs = CopyOnWriteArrayList<String>()
        val port = shell(0, service, log = { logs += it })

        val registration = port.listen { }
        service.copy(text)
        repeat(3) { port.getText() }
        repeat(3) { port.readImage() }

        assertTrue("the phone's copy was wiped", service.present())
        assertEquals("getPrimaryClip ran at uid 0", 0, service.gets.get())
        assertEquals("a read wiped the clip", 0, service.wipes.get())
        val off = logs.filter { it.contains("reads off") }
        assertEquals("one line for a session, got $off", 1, off.size)
        assertTrue("the reason lacks the uid: $off", off.single().contains("uid 0"))
        assertTrue("the reason lacks the missing helper: $off", off.single().contains("no helper"))
        port.stop(registration)
    }

    /**
     * The image poll on a text copy, as the shell user (the direct path, and the
     * helper's own process): the description has no image type, so
     * `filterMimeTypes` answers null. That is "no image", never a throw. On a
     * phone the throw killed the helper on every poll (ISS-27, 2026-11-04).
     */
    @Test
    fun uid2000ImagePollOnATextCopyIsNoImage() {
        val service = service()
        val port = shell(2000, service)
        service.copy("synthetic-text-" + "c".repeat(7))

        repeat(3) { assertEquals("a text copy read as an image", null, port.readImage()) }

        assertEquals("the probe let a text copy reach getPrimaryClip", 0, service.gets.get())
        assertTrue("the phone's copy was wiped", service.present())
    }

    /** UID 0 with a helper: the shell user reads, and the copy goes out once. */
    @Test
    fun uid0WithHelperSendsTheCopyOnce() {
        val service = service()
        val helper = FakeClipHelper(service)
        val port = shell(0, service, helper)
        connect(clipboard = port, clipImages = port)
        send(mapOf("t" to "clip.enable", "on" to true))
        await { session?.clipboardGateOn == true }

        val text = "synthetic-helper-" + "b".repeat(5)
        service.copy(text)

        assertEquals(text, readUntil("clip.set")["text"])
        assertEquals("a second copy went out", 0, clipsUntilPong(31))
        assertTrue("the phone's copy was wiped", service.present())
        assertTrue("a read ran in this process", service.readUids.all { it == 2000 })
    }

    /** UID 2000 is the real shell user: direct reads still work, unchanged. */
    @Test
    fun uid2000ReadsDirectlyAndSendsTheCopyOnce() {
        val service = service()
        val port = shell(2000, service)
        connect(clipboard = port, clipImages = port)
        send(mapOf("t" to "clip.enable", "on" to true))
        await { session?.clipboardGateOn == true }

        val text = "synthetic-shell-" + "c".repeat(5)
        service.copy(text)

        assertEquals(text, readUntil("clip.set")["text"])
        assertEquals("a second copy went out", 0, clipsUntilPong(32))
        assertTrue("the phone's copy was wiped", service.present())
        assertTrue("the direct read did not run at uid 2000", service.readUids.contains(2000))
    }

    /**
     * The gate is checked before any read: with it off, a copy produces no
     * `getPrimaryClip` and no description probe, text or image.
     */
    @Test
    fun gateOffReadsNothing() {
        val service = service()
        val port = shell(2000, service)
        connect(clipboard = port, clipImages = port)
        // The session registers its clipboard listener after `welcome` is out
        // (Session.welcome → startClipboardSync), and connect() returns on the
        // welcome: wait for the registration instead of racing it.
        await { service.listening }

        service.copy("synthetic-gate-" + "d".repeat(5))
        Thread.sleep(1_300) // real-time: at least one 1 s image-poll tick

        assertEquals("a read happened while the gate was off", 0, service.gets.get())
        assertEquals("an image probe happened while the gate was off", 0, service.descriptions.get())
    }

    /**
     * The injector's save/restore around a paste reads and writes through the
     * same clipboard port: at uid 0 it never reads, at uid 2000 it reads once
     * and puts the previous text back.
     */
    @Test
    fun theInjectorPastePathUsesTheClipboardPort() {
        val atRoot = service()
        atRoot.copy("synthetic-previous-" + "e".repeat(4))
        val rootPort = shell(0, atRoot)
        val rootKeys = CopyOnWriteArrayList<KeyEvent>()
        val rootInjector = AndroidInjector(
            log = {},
            sink = { event, _ -> if (event is KeyEvent) rootKeys += event },
            clipboard = rootPort,
        )

        rootInjector.text(7, "synth\u00e9tic-root")
        assertEquals("the injector read at uid 0", 0, atRoot.gets.get())
        assertTrue("the injector did not write through the port", atRoot.writes.isNotEmpty())
        assertTrue("no paste key", rootKeys.any { it.keyCode == KeyEvent.KEYCODE_PASTE })

        val atShell = service()
        atShell.copy("synthetic-previous-" + "f".repeat(4))
        val shellPort = shell(2000, atShell)
        val shellKeys = CopyOnWriteArrayList<KeyEvent>()
        val shellInjector = AndroidInjector(
            log = {},
            sink = { event, _ -> if (event is KeyEvent) shellKeys += event },
            clipboard = shellPort,
        )

        shellInjector.text(7, "synth\u00e9tic-shell")
        assertEquals("the injector did not use the port's read", 1, atShell.gets.get())
        assertTrue("the injector did not write through the port", atShell.writes.isNotEmpty())
        assertTrue("no paste key", shellKeys.any { it.keyCode == KeyEvent.KEYCODE_PASTE })
    }

    /** Reads every frame up to a pong and counts any clip.set in between. */
    private fun clipsUntilPong(ts: Int): Int {
        send(mapOf("t" to "ping", "ts" to ts))
        var clips = 0
        repeat(40) {
            val message = readJson()
            if (message["t"] == "clip.set") clips += 1
            if (message["t"] == "pong") return clips
        }
        error("never received pong")
    }

    /**
     * The IClipboard rule (ISS-27): a caller that does not own the package it
     * names clears the primary clip and gets null; the description call never
     * checks or clears.
     */
    private class FakeClipboardService : ClipboardService {
        private val lock = Any()
        private var text: String? = null
        private var sensitive = false
        @Volatile private var listener: ClipChangeListener? = null

        val gets = AtomicInteger()
        val descriptions = AtomicInteger()
        val wipes = AtomicInteger()
        val writes = CopyOnWriteArrayList<String>()
        val readUids = CopyOnWriteArrayList<Int>()

        @Volatile var listening = false

        fun copy(value: String, sensitive: Boolean = false) {
            synchronized(lock) {
                text = value
                this.sensitive = sensitive
            }
            listener?.onPrimaryClipChanged()
        }

        fun present(): Boolean = synchronized(lock) { text != null }

        override fun getPrimaryClip(packageName: String, uid: Int): ClipData? {
            gets.incrementAndGet()
            readUids += uid
            synchronized(lock) {
                if (!owns(packageName, uid)) {
                    text = null
                    wipes.incrementAndGet()
                    return null
                }
                val value = text ?: return null
                val description = ClipDescription("test", arrayOf("text/plain"))
                return ClipData(description, ClipData.Item(value))
            }
        }

        override fun getPrimaryClipDescription(packageName: String, uid: Int): ClipDescription? {
            descriptions.incrementAndGet()
            synchronized(lock) {
                text ?: return null
                return ClipDescription("test", arrayOf("text/plain"))
            }
        }

        override fun setPrimaryClip(clip: ClipData, packageName: String, uid: Int) {
            val value = clip.getItemAt(0).text?.toString() ?: ""
            writes += value
            synchronized(lock) { text = value }
            listener?.onPrimaryClipChanged()
        }

        override fun addClipListener(listener: ClipChangeListener): Boolean {
            this.listener = listener
            listening = true
            return true
        }

        override fun removeClipListener(listener: ClipChangeListener) {
            if (this.listener === listener) this.listener = null
            listening = false
        }

        private fun owns(packageName: String, uid: Int): Boolean =
            packageName == SHELL_PACKAGE && uid == 2000
    }

    /** The helper as a process running as the real shell user. */
    private class FakeClipHelper(private val service: FakeClipboardService) : ClipboardHelperPort {
        override val available: Boolean = true

        override fun start() = Unit
        override fun stop() = Unit

        override fun listen(onChange: () -> Unit) {
            service.addClipListener { onChange() }
        }

        override fun getText(): ClipText? {
            val clip = service.getPrimaryClip(SHELL_PACKAGE, 2000) ?: return null
            val text = clip.getItemAt(0).text?.toString() ?: return null
            return ClipText(text, sensitive = false)
        }

        override fun readImage(): ClipImage? = null
    }
}
