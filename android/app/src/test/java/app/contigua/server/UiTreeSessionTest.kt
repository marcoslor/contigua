package app.contigua.server

import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
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

    /** A source whose settle records its arguments and answers [answer]. */
    private class SettleSource(
        val answer: SettleAnswer = SettleAnswer.Settled(0, 0),
        val started: CountDownLatch = CountDownLatch(1),
        val release: CountDownLatch? = null,
    ) : UiTreeSource {
        @Volatile var args: Triple<Int, Long, Long>? = null
        override fun dump(displayId: Int, size: IntSize): UiTree.Answer = UiTree.Answer.Tree(emptyList())
        override fun settle(displayId: Int, quietMs: Long, timeoutMs: Long, arrivedAt: Long, owner: Any): SettleAnswer {
            args = Triple(displayId, quietMs, timeoutMs)
            started.countDown()
            release?.await(5, TimeUnit.SECONDS)
            return answer
        }
    }

    @Test
    fun testUiSettleClampsItsArguments() { // [MCP-81]
        // PROTOCOL.md "UI tree" item 7: quietMs 100–2000, timeoutMs 200–10000.
        val source = SettleSource()
        connect(uiTree = source)
        openPhoneMirror(640, 480)
        send(mapOf("t" to "ui.settle", "stream" to 1, "seq" to 1, "quietMs" to 5, "timeoutMs" to 99_999))
        val reply = readUntil("ui.settle")
        assertEquals(true, reply["ok"])
        assertEquals(100L to 10_000L, source.args!!.let { it.second to it.third })
    }

    @Test
    fun testUiSettleAnswersSettled() { // [MCP-81]
        connect(uiTree = SettleSource(SettleAnswer.Settled(420, 3)))
        openPhoneMirror(640, 480)
        send(mapOf("t" to "ui.settle", "stream" to 1, "seq" to 7, "quietMs" to 300, "timeoutMs" to 2_000))
        val reply = readUntil("ui.settle")
        assertEquals(1L, (reply["stream"] as Number).toLong())
        assertEquals(7L, (reply["seq"] as Number).toLong())
        assertEquals(true, reply["ok"])
        assertEquals(true, reply["settled"])
        assertEquals(420L, (reply["waitedMs"] as Number).toLong())
        assertEquals(3L, (reply["events"] as Number).toLong())
        assertFalse(reply.containsKey("reason"))
    }

    @Test
    fun testUiSettleAnswersItsReason() { // [MCP-107]
        connect(uiTree = SettleSource(SettleAnswer.StillChanging(2_000, 0, "loading")))
        openPhoneMirror(640, 480)
        send(mapOf("t" to "ui.settle", "stream" to 1, "seq" to 1, "quietMs" to 300, "timeoutMs" to 2_000))
        val reply = readUntil("ui.settle")
        assertEquals(true, reply["ok"])
        assertEquals(false, reply["settled"])
        assertEquals("loading", reply["reason"])
        assertEquals(2_000L, (reply["waitedMs"] as Number).toLong())
    }

    @Test
    fun testUiSettleAnswersNoWindow() { // [MCP-81]
        connect(uiTree = SettleSource())
        openPhoneMirror(640, 480)
        send(mapOf("t" to "ui.settle", "stream" to 99, "seq" to 1))
        assertEquals("no_window", readUntil("ui.settle")["code"])
        send(mapOf("t" to "ui.settle", "seq" to 2))
        assertEquals("no_window", readUntil("ui.settle")["code"])
    }

    @Test
    fun testUiSettleAnswersNotAvailable() { // [MCP-81]
        connect()
        openPhoneMirror(640, 480)
        send(mapOf("t" to "ui.settle", "stream" to 1, "seq" to 1))
        assertEquals("not_available", readUntil("ui.settle")["code"])
    }

    @Test
    fun testOneUiRequestAtATime() { // [MCP-9] [MCP-81]
        // A ui.tree arriving while a settle runs is refused busy (PROTOCOL.md
        // "UI tree" item 6), and so is a second settle; after it, a read runs.
        val release = CountDownLatch(1)
        val source = SettleSource(release = release)
        connect(uiTree = source)
        openPhoneMirror(640, 480)
        send(mapOf("t" to "ui.settle", "stream" to 1, "seq" to 1, "quietMs" to 300, "timeoutMs" to 2_000))
        assertTrue("the settle is running", source.started.await(2, TimeUnit.SECONDS))
        send(mapOf("t" to "ui.tree", "stream" to 1, "seq" to 2))
        val tree = readUntil("ui.tree")
        assertEquals(false, tree["ok"])
        assertEquals("busy", tree["code"])
        send(mapOf("t" to "ui.settle", "stream" to 1, "seq" to 3))
        val second = readUntil("ui.settle")
        assertEquals(3L, (second["seq"] as Number).toLong())
        assertEquals("busy", second["code"])
        release.countDown()
        assertEquals(1L, (readUntil("ui.settle")["seq"] as Number).toLong())
        send(mapOf("t" to "ui.tree", "stream" to 1, "seq" to 4))
        assertEquals(true, readUntil("ui.tree")["ok"])
    }

    @Test
    fun testUiSettleClampsQuietMsToTimeoutMs() { // [MCP-81]
        val source = SettleSource()
        connect(uiTree = source)
        openPhoneMirror(640, 480)
        send(mapOf("t" to "ui.settle", "stream" to 1, "seq" to 1, "quietMs" to 2_000, "timeoutMs" to 300))
        assertEquals(true, readUntil("ui.settle")["ok"])
        assertEquals(300L to 300L, source.args!!.let { it.second to it.third })
    }

    @Test
    fun testUiSettleWaitedMsCountsFromArrival() { // [MCP-81]
        // A source that starts 500 ms after the request arrived (a slow
        // connect): its waitedMs counts from the arrival the session hands it.
        val source = object : UiTreeSource {
            override fun dump(displayId: Int, size: IntSize): UiTree.Answer = UiTree.Answer.Tree(emptyList())
            override fun settle(displayId: Int, quietMs: Long, timeoutMs: Long, arrivedAt: Long, owner: Any): SettleAnswer {
                clock += 500
                return SettleAnswer.Settled(clock - arrivedAt, 0)
            }
        }
        connect(uiTree = source)
        openPhoneMirror(640, 480)
        send(mapOf("t" to "ui.settle", "stream" to 1, "seq" to 1, "quietMs" to 300, "timeoutMs" to 2_000))
        val reply = readUntil("ui.settle")
        assertTrue((reply["waitedMs"] as Number).toLong() >= 500)
    }

    @Test
    fun testSessionEndStopsTheWatch() { // [MCP-81]
        val started = CountDownLatch(1)
        val cancelled = CountDownLatch(1)
        val ended = CountDownLatch(1)
        var cancelledOwner: Any? = null
        var settleOwner: Any? = null
        val source = object : UiTreeSource {
            override fun dump(displayId: Int, size: IntSize): UiTree.Answer = UiTree.Answer.Tree(emptyList())
            override fun settle(displayId: Int, quietMs: Long, timeoutMs: Long, arrivedAt: Long, owner: Any): SettleAnswer {
                settleOwner = owner
                started.countDown()
                cancelled.await(5, TimeUnit.SECONDS)
                ended.countDown()
                return SettleAnswer.Cancelled
            }
            override fun cancel(owner: Any) {
                cancelledOwner = owner
                cancelled.countDown()
            }
        }
        connect(uiTree = source)
        openPhoneMirror(640, 480)
        send(mapOf("t" to "ui.settle", "stream" to 1, "seq" to 1, "quietMs" to 300, "timeoutMs" to 10_000))
        assertTrue("the watch is running", started.await(2, TimeUnit.SECONDS))
        session!!.close()
        // The session's end cancels its own watch, well before the 10 s timeout.
        assertTrue("the session end cancels the watch", cancelled.await(3, TimeUnit.SECONDS))
        assertTrue(ended.await(2, TimeUnit.SECONDS))
        assertTrue(cancelledOwner != null && cancelledOwner === settleOwner)
    }
}
