package app.contigua.server

import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * WIN-79 F2/F8: the session side of `ui.tree` over a loopback connection. The
 * tap point is normalized by the display's input space, not the stream's video
 * size; and every failure answers a sentence instead of a silence.
 */
class UiTreeSessionTest : SessionFixture() {

    private fun openPhoneMirror(w: Int, h: Int) {
        send(mapOf("t" to "window.open", "stream" to 1, "w" to w, "h" to h, "dpi" to 160, "mode" to "phone"))
        readUntil("window.opened")
    }

    @Test
    fun WIN79_mirrorTapPointUsesInputSpace() {
        // The mirror stream is 590×1280 but the input space (display 0's real
        // pixels) is 1440×3120: `box` lives there, so `at` must too (F2).
        val source = UiTreeSource { _, _ ->
            UiTree.Answer.Tree(listOf(UiTree.Layer("Mirror", "app", true, true, listOf(
                UiTree.Node(role = "android.widget.Button", text = "Buy",
                    box = UiTree.Box(620, 1_460, 820, 1_660), clickable = true),
            ))))
        }
        connect(uiTree = source)
        platform.screenSize = IntSize(1_440, 3_120) // the platform is made by connect()
        openPhoneMirror(590, 1_280)
        send(mapOf("t" to "ui.tree", "stream" to 1, "seq" to 1))
        val reply = readUntil("ui.tree")
        val nodes = (reply["nodes"] as? List<*>)?.filterIsInstance<Map<String, Any?>>().orEmpty()
        assertEquals(listOf(0.5, 0.5), nodes[0]["at"])
        // The JSON reader decodes numbers as Long or Double: compare the values.
        assertEquals(listOf(1_440, 3_120), (reply["size"] as List<*>).map { (it as Number).toInt() })
    }

    @Test
    fun WIN79_onUiTreeAnswersNoWindow() {
        connect(uiTree = UiTreeSource { _, _ -> UiTree.Answer.Tree(emptyList()) })
        openPhoneMirror(640, 480)
        send(mapOf("t" to "ui.tree", "stream" to 99, "seq" to 1))
        val reply = readUntil("ui.tree")
        assertEquals(false, reply["ok"])
        assertEquals("no_window", reply["code"])
    }

    @Test
    fun WIN79_onUiTreeAnswersNotAvailable() {
        // No source: the phone says so rather than dropping the read.
        connect()
        openPhoneMirror(640, 480)
        send(mapOf("t" to "ui.tree", "stream" to 1, "seq" to 1))
        val reply = readUntil("ui.tree")
        assertEquals(false, reply["ok"])
        assertEquals("not_available", reply["code"])
    }

    @Test
    fun WIN79_onUiTreeAnswersBusy() {
        val started = CountDownLatch(1)
        val release = CountDownLatch(1)
        val source = UiTreeSource { _, _ ->
            started.countDown()
            release.await(5, TimeUnit.SECONDS)
            UiTree.Answer.Tree(emptyList())
        }
        connect(uiTree = source)
        openPhoneMirror(640, 480)
        send(mapOf("t" to "ui.tree", "stream" to 1, "seq" to 1))
        assertTrue("the first read is running", started.await(2, TimeUnit.SECONDS))
        send(mapOf("t" to "ui.tree", "stream" to 1, "seq" to 2))
        val reply = readUntil("ui.tree")
        assertEquals(false, reply["ok"])
        assertEquals("busy", reply["code"])
        release.countDown()
    }

    @Test
    fun WIN79_onUiTreeAnswersFailed() {
        val source = UiTreeSource { _, _ -> throw IllegalStateException("boom") }
        connect(uiTree = source)
        openPhoneMirror(640, 480)
        send(mapOf("t" to "ui.tree", "stream" to 1, "seq" to 1))
        val reply = readUntil("ui.tree")
        assertEquals(false, reply["ok"])
        assertEquals("failed", reply["code"])
    }

    @Test
    fun WIN79_uiTreeWithoutStreamAnswersNoWindow() {
        // A `ui.tree` without a stream must answer, never hang the Mac's
        // deadline (F8).
        connect(uiTree = UiTreeSource { _, _ -> UiTree.Answer.Tree(emptyList()) })
        send(mapOf("t" to "ui.tree", "seq" to 1))
        val reply = readUntil("ui.tree")
        assertEquals(false, reply["ok"])
        assertEquals("no_window", reply["code"])
    }
}
