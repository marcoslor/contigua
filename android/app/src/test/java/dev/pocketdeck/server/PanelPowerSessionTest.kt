package dev.pocketdeck.server

import dev.pocketdeck.proto.FrameReader
import dev.pocketdeck.proto.Frames
import dev.pocketdeck.proto.Json
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import java.net.ServerSocket
import java.net.Socket
import java.util.concurrent.CopyOnWriteArrayList

/**
 * What the session tells the power policy (docs/PROTOCOL.md "Phone screen",
 * docs/design/phone-mirror.md): a covered window is a pause, not the end of
 * streaming, and an open phone window is visible to the panel decision.
 */
class PanelPowerSessionTest {

    private lateinit var platform: FakePlatform
    private lateinit var serverSocket: ServerSocket
    private lateinit var client: Socket
    private lateinit var reader: FrameReader
    private val logs = CopyOnWriteArrayList<String>()

    @Before
    fun setUp() {
        platform = FakePlatform()
    }

    @After
    fun tearDown() {
        runCatching { client.close() }
        runCatching { serverSocket.close() }
    }

    private fun connect() {
        serverSocket = ServerSocket(0)
        val accept = Thread {
            val socket = serverSocket.accept()
            socket.tcpNoDelay = true
            val session = Session(
                socket = socket,
                display = platform,
                catalog = platform,
                launcher = platform,
                injector = platform,
                power = platform,
                device = platform,
                store = platform,
                callback = platform,
                clipboard = platform,
                now = { 1_000L },
                log = { message -> logs.add(message) },
                handshakeTimeoutMs = 3_000,
                pairDecisionTimeoutMs = 30_000,
                autoApprovePairing = true,
                tlsView = TlsV2Fixture.view,
                gateProvider = { GateSettings(true, true) },
            )
            session.run()
        }
        accept.isDaemon = true
        accept.start()
        client = Socket("127.0.0.1", serverSocket.localPort)
        client.soTimeout = 5_000
        reader = FrameReader(client.getInputStream())
    }

    private fun send(obj: Map<String, Any?>) {
        val out = client.getOutputStream()
        out.write(Frames.encodeJson(0, Json.encode(obj)))
        out.flush()
    }

    private fun readJson(): Map<String, Any?> {
        val frame = readPathFrame(reader) ?: error("connection closed; logs: $logs")
        return pathJson(frame)
    }

    private fun readUntil(t: String): Map<String, Any?> {
        repeat(60) {
            val message = readJson()
            if (message["t"] == t) return message
        }
        error("never received '$t'; logs: $logs")
    }

    private fun authenticate() {
        send(mapOf("t" to "hello", "v" to 4, "path" to "a1b2c3d4", "clientId" to "c1", "name" to "Mac", "pair" to true))
        send(mapOf("t" to "pair.request"))
        readUntil("pair.commit")
        send(mapOf("t" to "pair.nonce", "n" to "0".repeat(32)))
        readUntil("welcome")
        readUntil("state")
    }

    /** The last call the session made into the power policy. */
    private fun lastPowerCall(): Triple<List<Int>, Boolean, Boolean> {
        val deadline = System.currentTimeMillis() + 5_000
        while (System.currentTimeMillis() < deadline) {
            platform.streamCalls.lastOrNull()?.let { return it }
            Thread.sleep(10)
        }
        error("the session never called the power policy; logs: $logs")
    }

    private fun awaitPowerCall(predicate: (Triple<List<Int>, Boolean, Boolean>) -> Boolean) {
        val deadline = System.currentTimeMillis() + 5_000
        while (System.currentTimeMillis() < deadline) {
            if (platform.streamCalls.lastOrNull()?.let(predicate) == true) return
            Thread.sleep(10)
        }
        error("no power call matched; calls: ${platform.streamCalls.toList()}; logs: $logs")
    }

    /** The next power call after [count] calls were already recorded. */
    private fun callAfter(count: Int): Triple<List<Int>, Boolean, Boolean> {
        val deadline = System.currentTimeMillis() + 5_000
        while (System.currentTimeMillis() < deadline) {
            val calls = platform.streamCalls.toList()
            if (calls.size > count) return calls[count]
            Thread.sleep(10) // real-time: the session answers on its own thread
        }
        error("no power call after #$count; calls: ${platform.streamCalls.toList()}; logs: $logs")
    }

    private fun awaitTrue(what: () -> Boolean) {
        val deadline = System.currentTimeMillis() + 5_000
        while (System.currentTimeMillis() < deadline) {
            if (what()) return
            Thread.sleep(10)
        }
        error("condition never held; requests: ${platform.panelRequests.toList()}; logs: $logs")
    }

    @Test
    fun `a covered window is a pause not the end of streaming`() {
        connect()
        authenticate()
        send(mapOf("t" to "window.open", "stream" to 1, "w" to 1000, "h" to 700, "dpi" to 160,
                   "pkg" to "com.android.settings"))
        readUntil("window.opened")
        awaitPowerCall { (ids, allPaused, _) -> ids.isNotEmpty() && !allPaused }

        send(mapOf("t" to "window.pause", "stream" to 1))
        awaitPowerCall { (ids, allPaused, _) -> ids.isNotEmpty() && allPaused }

        send(mapOf("t" to "window.resume", "stream" to 1))
        awaitPowerCall { (ids, allPaused, _) -> ids.isNotEmpty() && !allPaused }
    }

    @Test
    fun `a covered window keeps its display while its sibling closes`() {
        connect()
        authenticate()
        send(mapOf("t" to "window.open", "stream" to 1, "w" to 1000, "h" to 700, "dpi" to 160,
                   "pkg" to "com.android.settings"))
        readUntil("window.opened")
        val first = lastPowerCall().first.single()

        send(mapOf("t" to "window.open", "stream" to 2, "w" to 1000, "h" to 700, "dpi" to 160,
                   "pkg" to "com.android.settings"))
        readUntil("window.opened")
        awaitPowerCall { (ids, _, _) -> ids.size == 2 && ids.contains(first) }

        // The Mac covers window 1 when window 2 takes the focus: the phone keeps
        // window 1's display in the episode, paused or not (the 11-01 field log
        // released it and ended the episode while stream 6 was still open).
        val beforePause = platform.streamCalls.size
        send(mapOf("t" to "window.pause", "stream" to 1))
        val paused = callAfter(beforePause)
        assertTrue("a covered window's display must stay in the episode: $paused", paused.first.contains(first))
        assertFalse("a sibling is still live", paused.second)

        val beforeClose = platform.streamCalls.size
        send(mapOf("t" to "window.close", "stream" to 2))
        readUntil("window.closed")
        val after = callAfter(beforeClose)
        assertEquals("the open window keeps the episode", listOf(first), after.first)
        assertTrue("the remaining window is paused, not closed", after.second)
    }

    @Test
    fun `closing the last window is not a pause`() {
        connect()
        authenticate()
        send(mapOf("t" to "window.open", "stream" to 1, "w" to 1000, "h" to 700, "dpi" to 160,
                   "pkg" to "com.android.settings"))
        readUntil("window.opened")
        send(mapOf("t" to "window.close", "stream" to 1))
        readUntil("window.closed")
        val (ids, allPaused, _) = lastPowerCall()
        assertTrue("the session must stop the keep-alive", ids.isEmpty())
        assertFalse("a close hands the panel back at once", allPaused)
    }

    @Test
    fun `an open phone window is reported as mirroring`() {
        connect()
        authenticate()
        send(mapOf("t" to "window.open", "stream" to 2, "w" to 400, "h" to 800, "dpi" to 160,
                   "mode" to "phone"))
        readUntil("window.opened")
        awaitPowerCall { (_, _, mirroring) -> mirroring }
    }

    @Test
    fun `the phone window does not keep the app group awake by itself`() {
        connect()
        authenticate()
        send(mapOf("t" to "window.open", "stream" to 2, "w" to 400, "h" to 800, "dpi" to 160,
                   "mode" to "phone"))
        readUntil("window.opened")
        assertEquals(emptyList<Int>(), lastPowerCall().first)
    }

    // --- "Turn Off Phone Screen" --------------------------------------

    private fun openPhoneWindow() {
        send(mapOf("t" to "window.open", "stream" to 2, "w" to 400, "h" to 800, "dpi" to 160,
                   "mode" to "phone"))
        readUntil("window.opened")
    }

    @Test
    fun `turn off phone screen asks the panel and echoes the state`() {
        connect()
        authenticate()
        openPhoneWindow()
        send(mapOf("t" to "phone.panel", "off" to true))
        assertEquals("off", readUntil("state")["panel"])
        assertEquals(listOf(true), platform.mirrorPanelOffs.toList())
        // The hold reports the state from inside the call, before the session
        // writes its own line; wait for the line instead of racing it.
        awaitTrue { logs.any { it == "phone.panel off" } }

        send(mapOf("t" to "phone.panel", "off" to false))
        assertEquals("on", readUntil("state")["panel"])
        awaitTrue { logs.any { it == "phone.panel on" } }
    }

    @Test
    fun `phone panel off while paused is held and reported on until the resume`() {
        connect()
        authenticate()
        openPhoneWindow()
        send(mapOf("t" to "window.pause", "stream" to 2))
        awaitPowerCall { (_, _, mirroring) -> !mirroring }

        send(mapOf("t" to "phone.panel", "off" to true))
        // Held, not applied: `state.panel` is still on, so nothing is sent.
        awaitTrue { platform.panelRequests.isNotEmpty() }
        assertEquals(listOf(true to false), platform.panelRequests.toList())
        assertFalse("no hold without an unpaused window", platform.panelHeldOff)

        send(mapOf("t" to "window.resume", "stream" to 2))
        assertEquals("off", readUntil("state")["panel"])
        assertEquals("no new request on the resume", listOf(true), platform.mirrorPanelOffs.toList())
    }

    @Test
    fun `the off request carries the keep-it-off setting`() {
        connect()
        authenticate()
        openPhoneWindow()
        send(mapOf("t" to "phone.panel", "off" to true, "ignorePower" to true))
        assertEquals("off", readUntil("state")["panel"])
        assertEquals(listOf(true to true), platform.panelRequests.toList())
    }

    @Test
    fun `the phone ending the panel off sends a state with the panel on`() {
        connect()
        authenticate()
        openPhoneWindow()
        send(mapOf("t" to "phone.panel", "off" to true))
        assertEquals("off", readUntil("state")["panel"])

        platform.endPanelHold()
        assertEquals("on", readUntil("state")["panel"])
    }

    @Test
    fun `phone panel needs an open phone window`() {
        connect()
        authenticate()
        send(mapOf("t" to "phone.panel", "off" to true))
        assertEquals("bad_request", readUntil("error")["code"])
        assertTrue(platform.mirrorPanelOffs.isEmpty())
    }

    @Test
    fun `a build without panel control refuses the request`() {
        platform.mirrorPanelOffSupported = false
        connect()
        authenticate()
        openPhoneWindow()
        send(mapOf("t" to "phone.panel", "off" to true))
        assertEquals("unavailable", readUntil("error")["code"])
    }
}
