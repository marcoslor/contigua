package dev.pocketdeck.server

import dev.pocketdeck.proto.Crypto
import dev.pocketdeck.proto.FrameReader
import dev.pocketdeck.proto.Frames
import dev.pocketdeck.proto.Json
import dev.pocketdeck.proto.AudioConfigPayload
import dev.pocketdeck.proto.VideoConfigPayload
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import java.net.ServerSocket
import java.net.Socket

/**
 * The notification/media part of the session (docs/design/notify.md): gates,
 * validated pushes and media command dispatch, over the same loopback harness
 * as [SessionTest].
 */
class NotifySessionTest {

    private lateinit var platform: FakePlatform
    private lateinit var serverSocket: ServerSocket
    private lateinit var client: Socket
    private lateinit var reader: FrameReader

    @Volatile private var listenerAccess = false
    @Volatile private var grantAttempts = 0
    @Volatile private var grantSucceeds = false
    @Volatile private var session: Session? = null
    private val mediaCommands = java.util.concurrent.CopyOnWriteArrayList<String>()
    private val mediaChooses = java.util.concurrent.CopyOnWriteArrayList<String>()
    private val forwards = java.util.concurrent.CopyOnWriteArrayList<Boolean>()
    private val notifyReasons = java.util.concurrent.CopyOnWriteArrayList<String?>()
    private val notifyOpens = java.util.concurrent.CopyOnWriteArrayList<Pair<String, Int>>()
    private var clock = 1_000L

    @Before
    fun setUp() {
        platform = FakePlatform()
    }

    private fun connect() {
        serverSocket = ServerSocket(0)
        val accept = Thread {
            val s = serverSocket.accept()
            s.tcpNoDelay = true
            val sess = Session(
                socket = s,
                display = platform,
                catalog = platform,
                launcher = platform,
                injector = platform,
                power = platform,
                device = platform,
                store = platform,
                callback = platform,
                clipboard = platform,
                now = { clock++ },
                log = { message -> logs.add(message) },
                handshakeTimeoutMs = 3_000,
                pairDecisionTimeoutMs = 30_000,
                autoApprovePairing = true,
                tlsView = TlsV2Fixture.view,
                gateProvider = { GateSettings(true, true) },
                notifyAccess = { listenerAccess },
                notifyGrant = {
                    grantAttempts += 1
                    listenerAccess = grantSucceeds
                    grantSucceeds
                },
                mediaCommand = { command -> mediaCommands.add(command) },
                mediaChoose = { key -> mediaChooses.add(key) },
                notifyState = { forward, reason -> forwards.add(forward); notifyReasons.add(reason) },
                notifyOpen = { id, displayId -> notifyOpens.add(id to displayId) },
            )
            session = sess
            sess.run()
        }
        accept.isDaemon = true
        accept.start()
        client = Socket("127.0.0.1", serverSocket.localPort)
        client.soTimeout = 5_000
        reader = FrameReader(client.getInputStream())
    }

    val logs = java.util.concurrent.CopyOnWriteArrayList<String>()

    @After
    fun tearDown() {
        runCatching { client.close() }
        runCatching { serverSocket.close() }
    }

    private fun send(obj: Map<String, Any?>) {
        val out = client.getOutputStream()
        out.write(Frames.encodeJson(0, Json.encode(obj)))
        out.flush()
    }

    private fun readJson(): Map<String, Any?> {
        val frame = reader.readFrame() ?: error("connection closed; logs: $logs")
        return Json.parseObject(String(frame.payload))
    }

    private fun await(timeoutMs: Long = 2_000, condition: () -> Boolean) {
        val deadline = System.currentTimeMillis() + timeoutMs
        while (System.currentTimeMillis() < deadline) {
            if (condition()) return
            Thread.sleep(5)
        }
        error("condition never became true (after ${timeoutMs}ms); logs: $logs")
    }

    private fun readUntil(t: String): Map<String, Any?> {
        try {
            repeat(40) {
                val m = readJson()
                if (m["t"] == t) return m
            }
        } catch (e: java.net.SocketTimeoutException) {
            error("timed out waiting for '$t'; logs: $logs")
        }
        error("never received '$t'; logs: $logs")
    }

    private fun expectNoMore(t: String): Boolean {
        // A short window: no message of type t may arrive in it.
        client.soTimeout = 400
        return try {
            repeat(6) {
                val m = readJson()
                if (m["t"] == t) return false
            }
            true
        } catch (_: java.net.SocketTimeoutException) {
            true
        } finally {
            client.soTimeout = 5_000
        }
    }

    private fun authenticate() {
        send(mapOf("t" to "hello", "v" to 3, "clientId" to "c1", "name" to "Mac"))
        send(mapOf("t" to "pair.request"))
        readUntil("pair.commit")
        send(mapOf("t" to "pair.nonce", "n" to "0".repeat(32)))
        readUntil("welcome")
    }

    @Test
    fun `enable without listener access replies no_access and forwards nothing`() {
        connect()
        authenticate()
        send(mapOf("t" to "notify.enable", "on" to true))
        val state = readUntil("notify.state")
        assertEquals(false, state["on"])
        assertEquals("no_access", state["reason"])
        assertEquals("the phone tries the shell grant once", 1, grantAttempts)
        assertEquals(listOf<String?>("no_access"), notifyReasons.toList())
        session!!.onDeviceEvent("notify.post", mapOf("t" to "notify.post", "id" to "k", "pkg" to "com.a", "title" to "hi"))
        assertTrue(expectNoMore("notify.post"))
        assertTrue("nothing forwarded", forwards.none { it })
    }

    @Test
    fun `enable with a listener grant forwards without asking the phone's switch`() {
        connect()
        authenticate()
        listenerAccess = true
        send(mapOf("t" to "notify.enable", "on" to true))
        val state = readUntil("notify.state")
        assertEquals(true, state["on"])
        assertNull(state["reason"])
        assertEquals("an existing grant needs no shell round trip", 0, grantAttempts)
        assertEquals(listOf(true), forwards.toList())
    }

    @Test
    fun `a successful shell grant turns forwarding on in the same answer`() {
        connect()
        authenticate()
        grantSucceeds = true
        send(mapOf("t" to "notify.enable", "on" to true))
        val state = readUntil("notify.state")
        assertEquals(true, state["on"])
        assertEquals(1, grantAttempts)
    }

    @Test
    fun `turning sharing off clears no_access on the phone`() {
        connect()
        authenticate()
        send(mapOf("t" to "notify.enable", "on" to true))
        assertEquals("no_access", readUntil("notify.state")["reason"])
        send(mapOf("t" to "notify.enable", "on" to false))
        val state = readUntil("notify.state")
        assertEquals(false, state["on"])
        assertNull(state["reason"])
        // The app's attention item is local state: it must be cleared too.
        assertEquals(listOf<String?>("no_access", null), notifyReasons.toList())
    }

    @Test
    fun `closing the session clears no_access locally`() {
        connect()
        authenticate()
        send(mapOf("t" to "notify.enable", "on" to true))
        assertEquals("no_access", readUntil("notify.state")["reason"])
        session!!.close()
        val deadline = System.currentTimeMillis() + 3_000
        while (notifyReasons.lastOrNull() != null && System.currentTimeMillis() < deadline) {
            Thread.sleep(20) // real-time: the close path runs on the session reader thread
        }
        assertEquals(listOf<String?>("no_access", null), notifyReasons.toList())
        assertEquals(false, forwards.last())
    }

    @Test
    fun `a later listener grant forwards without another Mac toggle`() {
        connect()
        authenticate()
        send(mapOf("t" to "notify.enable", "on" to true))
        assertEquals("no_access", readUntil("notify.state")["reason"])
        // The person granted notification access on the phone; the app announces
        // it and the phone turns forwarding on by itself.
        listenerAccess = true
        session!!.listenerAccessChanged(true)
        val state = readUntil("notify.state")
        assertEquals(true, state["on"])
        assertNull(state["reason"])
        assertEquals(listOf(false, true), forwards.toList())
        assertNull("the attention item is cleared by the grant", notifyReasons.last())
    }

    @Test
    fun `the Mac turning enable off stays off with no reason`() {
        connect()
        authenticate()
        listenerAccess = true
        send(mapOf("t" to "notify.enable", "on" to true))
        readUntil("notify.state")
        send(mapOf("t" to "notify.enable", "on" to false))
        val state = readUntil("notify.state")
        assertEquals(false, state["on"])
        assertNull(state["reason"])
    }

    @Test
    fun `enable with a listener grant forwards validated pushes`() {
        connect()
        authenticate()
        platform.pushState(platform.deviceState) // no; the state watcher is not the gate
        readUntil("state")
        listenerAccess = true
        send(mapOf("t" to "notify.enable", "on" to true))
        assertEquals(true, readUntil("notify.state")["on"])
        assertEquals(listOf(true), forwards.toList())

        val push = mapOf(
            "t" to "notify.post", "id" to "key_wa_1", "pkg" to "com.whatsapp",
            "title" to "Design review", "text" to "Deck at 4", "when" to 5L, "alert" to true,
        )
        session!!.onDeviceEvent("notify.post", push)
        val posted = readUntil("notify.post")
        assertEquals("com.whatsapp", posted["pkg"])
        assertEquals("Design review", posted["title"])
        assertEquals(5L, posted["when"])
    }

    @Test
    fun `malformed pushes are dropped at the session`() {
        connect()
        authenticate()
        readUntil("state")
        listenerAccess = true
        send(mapOf("t" to "notify.enable", "on" to true))
        readUntil("notify.state")

        session!!.onDeviceEvent("notify.post", mapOf("t" to "notify.post", "id" to "k", "pkg" to "bad pkg!", "title" to "t"))
        session!!.onDeviceEvent("notify.post", mapOf("t" to "notify.post", "id" to "", "pkg" to "com.a", "title" to "t"))
        session!!.onDeviceEvent("notify.post", mapOf("t" to "notify.post", "id" to "k", "pkg" to "com.a"))
        session!!.onDeviceEvent("media.state", mapOf("t" to "media.state"))
        session!!.onDeviceEvent("media.state", mapOf("t" to "media.state", "playing" to true)) // no rate
        session!!.onDeviceEvent("media.state", mapOf("t" to "media.state", "playing" to true, "rate" to 99.0))
        session!!.onDeviceEvent("notify.remove", mapOf("t" to "notify.remove", "id" to "bad/id"))
        assertTrue(expectNoMore("notify.post"))
    }

    @Test
    fun `media state clears and playing state passes rate`() {
        connect()
        authenticate()
        readUntil("state")
        listenerAccess = true
        send(mapOf("t" to "notify.enable", "on" to true))
        readUntil("notify.state")

        session!!.onDeviceEvent(
            "media.state",
            mapOf("t" to "media.state", "playing" to true, "pkg" to "org.fossify.musicplayer",
                "title" to "tone440", "durationMs" to 30_000L, "positionMs" to 2_111L, "rate" to 1.0),
        )
        val playing = readUntil("media.state")
        assertEquals(true, playing["playing"])
        assertEquals(1.0, (playing["rate"] as Number).toDouble(), 0.0001)
        assertEquals(30_000L, playing["durationMs"])

        session!!.onDeviceEvent("media.state", mapOf("t" to "media.state", "playing" to false,
            "pkg" to "org.fossify.musicplayer", "title" to "tone440", "positionMs" to 2_500L))
        val paused = readUntil("media.state")
        assertNull(paused["rate"])
    }

    @Test
    fun `notify open is dropped while forwarding is off`() {
        connect()
        authenticate()
        readUntil("state")
        send(mapOf("t" to "notify.open", "id" to "key_wa_1", "target" to "phone"))
        Thread.sleep(200)
        assertTrue(notifyOpens.isEmpty())
    }

    @Test
    fun `notify open with the phone target asks for display 0`() {
        connect()
        authenticate()
        readUntil("state")
        listenerAccess = true
        send(mapOf("t" to "notify.enable", "on" to true))
        readUntil("notify.state")
        send(mapOf("t" to "notify.open", "id" to "key_wa_1", "target" to "phone"))
        await { notifyOpens.isNotEmpty() }
        assertEquals(listOf("key_wa_1" to 0), notifyOpens.toList())
    }

    @Test
    fun `notify open with the window target uses that stream's display`() {
        connect()
        authenticate()
        readUntil("state")
        listenerAccess = true
        send(mapOf("t" to "notify.enable", "on" to true))
        readUntil("notify.state")
        send(mapOf("t" to "window.open", "stream" to 7, "w" to 800, "h" to 600, "dpi" to 160, "pkg" to "com.a"))
        val opened = readUntil("window.opened")
        val displayId = (opened["displayId"] as Number).toInt()
        send(mapOf("t" to "notify.open", "id" to "key_wa_1", "target" to "window", "stream" to 7))
        await { notifyOpens.isNotEmpty() }
        assertEquals(listOf("key_wa_1" to displayId), notifyOpens.toList())
    }

    @Test
    fun `notify open drops an unknown target or stream and a malformed id`() {
        connect()
        authenticate()
        readUntil("state")
        listenerAccess = true
        send(mapOf("t" to "notify.enable", "on" to true))
        readUntil("notify.state")
        send(mapOf("t" to "notify.open", "id" to "key_wa_1", "target" to "desk"))
        send(mapOf("t" to "notify.open", "id" to "bad/id", "target" to "phone"))
        send(mapOf("t" to "notify.open", "target" to "phone"))
        send(mapOf("t" to "notify.open", "id" to "key_wa_1", "target" to "window", "stream" to 99))
        assertEquals("no_stream", readUntil("error")["code"])
        assertTrue(notifyOpens.isEmpty())
    }

    @Test
    fun `media command is validated and driven, unknown dropped`() {
        connect()
        authenticate()
        readUntil("state")
        send(mapOf("t" to "media.command", "action" to "play"))
        send(mapOf("t" to "media.command", "action" to "pause"))
        send(mapOf("t" to "media.command", "action" to "seek-to-middle"))
        send(mapOf("t" to "media.command"))
        val deadline = System.currentTimeMillis() + 3_000
        while (mediaCommands.size < 2 && System.currentTimeMillis() < deadline) Thread.sleep(20)
        // The app process receives the validated command as JSON (part 2).
        assertEquals(listOf("play", "pause"),
                     mediaCommands.toList().map { Json.parseObject(it)["action"] })
    }

    @Test
    fun `media seek, volume and choose are validated before they reach the app`() {
        connect()
        authenticate()
        readUntil("state")
        send(mapOf("t" to "media.command", "action" to "seek", "positionMs" to 45_000, "key" to "s2"))
        send(mapOf("t" to "media.command", "action" to "volume", "level" to 9))
        send(mapOf("t" to "media.command", "action" to "seek"))
        send(mapOf("t" to "media.command", "action" to "volume", "level" to -1))
        send(mapOf("t" to "media.choose", "key" to "s1"))
        send(mapOf("t" to "media.choose", "key" to "bad key"))
        val deadline = System.currentTimeMillis() + 3_000
        while ((mediaCommands.size < 2 || mediaChooses.size < 1) && System.currentTimeMillis() < deadline) {
            Thread.sleep(20)
        }
        val commands = mediaCommands.toList().map { Json.parseObject(it) }
        assertEquals("seek", commands[0]["action"])
        assertEquals(45_000L, commands[0]["positionMs"])
        assertEquals("s2", commands[0]["key"])
        assertEquals("volume", commands[1]["action"])
        assertEquals(9L, (commands[1]["level"] as Number).toLong())
        assertEquals(listOf("s1"), mediaChooses.toList())
    }

    @Test
    fun `listener access being revoked stops forwarding and tells the Mac`() {
        connect()
        authenticate()
        readUntil("state")
        listenerAccess = true
        send(mapOf("t" to "notify.enable", "on" to true))
        assertEquals(true, readUntil("notify.state")["on"])
        session!!.listenerAccessChanged(false)
        val state = readUntil("notify.state")
        assertEquals(false, state["on"])
        assertEquals("no_access", state["reason"])
        assertFalse(forwards.last())
    }

    @Test
    fun `session close stops forwarding`() {
        connect()
        authenticate()
        readUntil("state")
        listenerAccess = true
        send(mapOf("t" to "notify.enable", "on" to true))
        readUntil("notify.state")
        session!!.close()
        // the close thread may run asynchronously; poll for the off callback
        val deadline = System.currentTimeMillis() + 3_000
        while (forwards.toBooleanArray().takeLast(1).firstOrNull() != false && System.currentTimeMillis() < deadline) {
            Thread.sleep(20)
        }
        assertFalse(forwards.last())
    }
}
