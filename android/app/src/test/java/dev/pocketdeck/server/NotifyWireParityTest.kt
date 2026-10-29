package dev.pocketdeck.server

import dev.pocketdeck.app.NotifyEvents
import dev.pocketdeck.app.NotifyImage
import dev.pocketdeck.app.NotifyImageRules
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
import java.util.Base64

/**
 * The wire guard for forwarded notifications (docs/design/notify.md): whatever
 * the app's builder puts in a `notify.post` or a `notify.image` must reach the
 * Mac unchanged, and the shell server's re-validation must only remove a field
 * its rules refuse.
 *
 * This exists because v120/v121 shipped a server that rebuilt the post from a
 * fixed field list (`alert`, `group` and `live` were dropped) and had no
 * `notify.image` case at all, while every e2e passed: the fake phone talks to
 * the Mac directly, so only the real phone's app→shell hop was broken. A key
 * added to the builder but not to the server now fails here.
 */
class NotifyWireParityTest {

    private lateinit var platform: FakePlatform
    private lateinit var serverSocket: ServerSocket
    private lateinit var client: Socket
    private lateinit var reader: FrameReader

    @Volatile private var listenerAccess = false
    @Volatile private var session: Session? = null
    private var clock = 1_000L

    val logs = java.util.concurrent.CopyOnWriteArrayList<String>()

    /**
     * Keys the phone's builder emits for its own use and that must not cross the
     * wire. Empty today: every field the listener builds is one the Mac reads.
     */
    private val PHONE_ONLY: Set<String> = emptySet()

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
                notifyGrant = { false },
                notifyState = { _, _ -> },
                notifyOpen = { _, _ -> },
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

    private fun send(obj: Map<String, Any?>) {
        val out = client.getOutputStream()
        out.write(Frames.encodeJson(0, Json.encode(obj)))
        out.flush()
    }

    private fun readJson(): Map<String, Any?> {
        val frame = reader.readFrame() ?: error("connection closed; logs: $logs")
        return Json.parseObject(String(frame.payload))
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

    /** True when nothing of type [t] reaches the Mac in a short window. */
    private fun expectNoMore(t: String): Boolean {
        client.soTimeout = 400
        return try {
            repeat(6) {
                if (readJson()["t"] == t) return false
            }
            true
        } catch (_: java.net.SocketTimeoutException) {
            true
        } finally {
            client.soTimeout = 5_000
        }
    }

    private fun authenticate() {
        send(mapOf("t" to "hello", "v" to 3, "clientId" to "c1", "name" to "Mac", "pair" to true))
        send(mapOf("t" to "pair.request"))
        readUntil("pair.commit")
        send(mapOf("t" to "pair.nonce", "n" to "0".repeat(32)))
        readUntil("welcome")
    }

    /** The state every parity case starts in: READY and forwarding. */
    private fun forwarding() {
        connect()
        authenticate()
        listenerAccess = true
        send(mapOf("t" to "notify.enable", "on" to true))
        assertEquals(true, readUntil("notify.state")["on"])
    }

    /**
     * The app→shell hop exactly as `DeckService.pushDeviceEvent` makes it: the
     * app encodes the event, the shell parses the text and dispatches on `t`.
     */
    private fun push(event: Map<String, Any?>) {
        val obj = Json.parseObject(Json.encode(event))
        session!!.onDeviceEvent(Json.str(obj["t"])!!, obj)
    }

    private fun post(
        id: String,
        alert: Boolean,
        whenMs: Long = 0L,
        ongoing: Boolean = false,
        live: Map<String, Any?>? = null,
        group: String? = null,
        actions: List<NotifyEvents.ActionCandidate> = emptyList(),
    ): Map<String, Any?> = NotifyEvents.notificationEvent(
        id = id, pkg = "com.chat", title = "Review", text = "Deck at 4", when_ = whenMs,
        alert = alert, actions = actions, ongoing = ongoing, live = live, group = group,
    )!!

    /**
     * Every key the app emitted reaches the Mac with the same value, and the
     * wire adds nothing. Both sides are compared after a JSON round trip, which
     * is what each end actually sees.
     */
    private fun assertCarried(sent: Map<String, Any?>, received: Map<String, Any?>) {
        val expected = Json.parseObject(Json.encode(sent)).minus(PHONE_ONLY)
        val actual = received.minus(PHONE_ONLY)
        assertEquals("keys on the wire", expected.keys, actual.keys)
        for ((key, value) in expected) assertEquals("field '$key'", value, actual[key])
    }

    @Test
    fun `every field the app builds reaches the Mac`() {
        forwarding()
        val group = NotifyEvents.groupHash("com.chat", "chat-1")
        val chrono = 1_700_000_000_000L
        val liveCases = listOf(
            "live progress" to NotifyEvents.liveWire(0.4, null, null, false),
            "live chip" to NotifyEvents.liveWire(null, "12 min", null, false),
            "live chrono" to NotifyEvents.liveWire(null, null, chrono, false),
            "live countdown" to NotifyEvents.liveWire(null, null, chrono, true),
            "live every key" to NotifyEvents.liveWire(0.4, "12 min", chrono, true),
            "live empty marker" to emptyMap<String, Any?>(),
        )
        val events = listOf(
            "plain post" to post("k-plain", alert = true, whenMs = 1_700_000_000_000L),
            "quiet update" to post("k-quiet", alert = false),
            "grouped" to post("k-group", alert = true, group = group),
            "ongoing" to post("k-ongoing", alert = true, ongoing = true),
            "actions and reply" to post(
                "k-actions", alert = true,
                actions = listOf(
                    NotifyEvents.ActionCandidate(index = 0, title = "Reply", hasIntent = true,
                                                reply = true, contextual = false),
                    NotifyEvents.ActionCandidate(index = 1, title = "Mark read", hasIntent = true,
                                                reply = false, contextual = false),
                ),
            ),
        ) + liveCases.map { (name, live) ->
            name to post("k-" + name.replace(' ', '-'), alert = true, ongoing = true, live = live)
        }
        for ((name, event) in events) {
            assertTrue("$name was never built", event.isNotEmpty())
            push(event)
            val received = readUntil("notify.post")
            assertEquals("id of $name", event["id"], received["id"])
            assertCarried(event, received)
        }
    }

    @Test
    fun `every field of the app's picture reaches the Mac`() {
        forwarding()
        val image = NotifyImage(
            mime = NotifyImageRules.mime(hasAlpha = false),
            width = 320,
            height = 200,
            data = byteArrayOf(0xFF.toByte(), 0xD8.toByte(), 1, 2, 3, 4),
        )
        val event = image.wire("k-pic") { bytes -> Base64.getEncoder().encodeToString(bytes) }
        push(event)
        assertCarried(event, readUntil("notify.image"))
    }

    @Test
    fun `a post without the alert decision is dropped`() {
        forwarding()
        val event = post("k-no-alert", alert = true).toMutableMap().apply { remove("alert") }
        push(event)
        assertTrue("a post with no alert must not reach the Mac", expectNoMore("notify.post"))
        assertTrue(logs.contains("notify.post dropped: alert"))
    }

    @Test
    fun `a group that is not the builder's hash drops only the group`() {
        forwarding()
        val hash = NotifyEvents.groupHash("com.chat", "chat-1")
        val bad = listOf(
            "" to "empty",
            "abc" to "short",
            hash.uppercase() to "uppercase",
            hash.dropLast(1) + "Z" to "alphabet",
            hash + "0" to "long",
        )
        for ((index, case) in bad.withIndex()) {
            val (group, name) = case
            val event = post("k-bad-group-$index", alert = true, group = group)
            push(event)
            val received = readUntil("notify.post")
            assertFalse("group carried for $name", received.containsKey("group"))
            assertEquals("post kept for $name", event["id"], received["id"])
            assertEquals("title kept for $name", event["title"], received["title"])
            assertEquals("alert kept for $name", event["alert"], received["alert"])
        }
        assertEquals("one line per refused group", bad.size, logs.count { it == "notify.post group dropped" })
    }

    @Test
    fun `a malformed live key drops only the live field and names the key`() {
        forwarding()
        val bad = listOf(
            mapOf("progress" to 1.5) to "progress",
            mapOf("progress" to "half") to "progress",
            mapOf("progress" to 0.2, "chip" to "x".repeat(NotifyEvents.MAX_CHIP + 1)) to "chip",
            mapOf("chip" to 7) to "chip",
            mapOf("chrono" to 0L) to "chrono",
            mapOf("chrono" to "soon") to "chrono",
            mapOf("countDown" to "yes") to "countDown",
        )
        for ((index, case) in bad.withIndex()) {
            val (live, key) = case
            val event = post("k-bad-live-$index", alert = true, ongoing = true, live = live)
            push(event)
            val received = readUntil("notify.post")
            assertFalse("live carried for case $index", received.containsKey("live"))
            assertEquals("post kept for case $index", event["id"], received["id"])
            assertEquals("alert kept for case $index", event["alert"], received["alert"])
            assertTrue("live refusal names the key", logs.contains("notify.post live dropped: $key"))
        }
    }

    @Test
    fun `an unknown live key is dropped and the known ones stay`() {
        forwarding()
        val live = NotifyEvents.liveWire(0.4, null, null, false)!! + ("extra" to "not on the wire")
        push(post("k-extra-live", alert = true, ongoing = true, live = live))
        val received = readUntil("notify.post")
        assertEquals(mapOf("progress" to 0.4), received["live"])
    }

    @Test
    fun `a picture outside the promised shape is dropped`() {
        forwarding()
        val data = Base64.getEncoder().encodeToString(ByteArray(16) { it.toByte() })
        val good = linkedMapOf<String, Any?>(
            "t" to "notify.image", "id" to "k-pic", "mime" to NotifyImageRules.mime(hasAlpha = false),
            "w" to 320, "h" to 200, "data" to data,
        )
        val overCap = Base64.getEncoder().encodeToString(ByteArray(NotifyImageRules.MAX_BYTES + 1))
        val bad = listOf(
            "mime" to (good + ("mime" to "image/gif")),
            "w" to (good + ("w" to NotifyImageRules.MAX_SIDE + 1)),
            "h" to (good + ("h" to 0)),
            "data" to (good + ("data" to "not base64!")),
            "bytes" to (good + ("data" to overCap)),
            "id" to (good + ("id" to "bad/id")),
        )
        for ((field, event) in bad) {
            push(event)
            assertTrue("a $field picture must not reach the Mac", expectNoMore("notify.image"))
            assertTrue("refusal names $field", logs.contains("notify.image dropped: $field"))
        }
    }
}
