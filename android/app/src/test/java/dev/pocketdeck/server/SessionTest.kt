package dev.pocketdeck.server

import dev.pocketdeck.proto.Crypto
import dev.pocketdeck.proto.FrameReader
import dev.pocketdeck.proto.Frames
import dev.pocketdeck.proto.Json
import dev.pocketdeck.proto.TouchPayload
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import java.net.ServerSocket
import java.net.Socket

/**
 * Drives [Session] over a real loopback TCP connection with a fake platform,
 * exercising the handshake, pairing, dispatch, queueing and window lifecycle.
 */
class SessionTest {

    private lateinit var platform: FakePlatform
    private lateinit var serverSocket: ServerSocket
    private lateinit var client: Socket
    private lateinit var reader: FrameReader

    @Volatile private var session: Session? = null
    @Volatile private var topApp: TopApp? = null
    @Volatile private var taskPresent = false
    private var clock = 1_000L

    @Before
    fun setUp() {
        platform = FakePlatform()
        connect(pairDecisionTimeoutMs = 30_000)
    }

    private fun connect(pairDecisionTimeoutMs: Long) {
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
                titleObserver = { topApp },
                taskPresence = { taskPresent },
                now = { clock++ },
                log = {},
                handshakeTimeoutMs = 3_000,
                pairDecisionTimeoutMs = pairDecisionTimeoutMs,
                exitPollIntervalMs = 50,
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

    @After
    fun tearDown() {
        runCatching { client.close() }
        runCatching { serverSocket.close() }
    }

    // ------------------------------------------------------------------
    // helpers
    // ------------------------------------------------------------------

    private fun send(obj: Map<String, Any?>) {
        val out = client.getOutputStream()
        out.write(Frames.encodeJson(0, Json.encode(obj)))
        out.flush()
    }

    private fun sendFrame(type: Int, stream: Int, payload: ByteArray) {
        val out = client.getOutputStream()
        out.write(Frames.encode(type, stream, payload))
        out.flush()
    }

    private fun readJson(): Map<String, Any?> {
        val frame = reader.readFrame() ?: error("connection closed")
        return Json.parseObject(String(frame.payload))
    }

    private fun readUntil(t: String): Map<String, Any?> {
        repeat(30) {
            val m = readJson()
            if (m["t"] == t) return m
        }
        error("never received '$t'")
    }

    private fun hello(clientId: String, name: String): String {
        send(mapOf("t" to "hello", "v" to 1, "clientId" to clientId, "name" to name))
        return readUntil("challenge")["nonce"] as String
    }

    private fun authenticate(clientId: String, keyHex: String, name: String = "MacBook"): Map<String, Any?> {
        val nonce = hello(clientId, name)
        val mac = Crypto.hmacSha256Hex(Crypto.fromHex(keyHex), nonce.toByteArray(Charsets.UTF_8))
        send(mapOf("t" to "auth", "mac" to mac))
        return readUntil("welcome")
    }

    private fun addAndAuthenticate(): String {
        val keyHex = Crypto.toHex(Crypto.randomBytes(32))
        platform.clients.add(PairedClient("c1", "MacBook", keyHex))
        authenticate("c1", keyHex)
        return keyHex
    }

    private fun await(timeoutMs: Long = 2_000, condition: () -> Boolean) {
        val deadline = System.currentTimeMillis() + timeoutMs
        while (System.currentTimeMillis() < deadline) {
            if (condition()) return
            Thread.sleep(5)
        }
        assertTrue("condition never became true", condition())
    }

    // ------------------------------------------------------------------

    @Test
    fun challengeCarriesDeviceId() {
        send(mapOf("t" to "hello", "v" to 1, "clientId" to "cX", "name" to "Mac"))
        val challenge = readUntil("challenge")
        assertEquals("dev1", challenge["id"])
        assertTrue((challenge["nonce"] as String).isNotEmpty())
    }

    @Test
    fun authSuccessSendsWelcome() {
        val keyHex = Crypto.toHex(Crypto.randomBytes(32))
        platform.clients.add(PairedClient("c1", "MacBook", keyHex))
        val welcome = authenticate("c1", keyHex)
        @Suppress("UNCHECKED_CAST")
        val device = welcome["device"] as Map<String, Any?>
        assertEquals("dev1", device["id"])
        assertEquals("Pixel 9", device["model"])
        assertEquals(36L, device["sdk"])
        assertEquals(true, device["locked"])
        @Suppress("UNCHECKED_CAST")
        val screen = device["screen"] as Map<String, Any?>
        assertEquals(1080L, screen["w"])
        await { platform.sessionChanges.any { it.connected } }
    }

    @Test
    fun authFailureSendsAuthFailedAndCloses() {
        val keyHex = Crypto.toHex(Crypto.randomBytes(32))
        platform.clients.add(PairedClient("c1", "MacBook", keyHex))
        val nonce = hello("c1", "MacBook")
        send(mapOf("t" to "auth", "mac" to "0".repeat(64)))
        val error = readUntil("error")
        assertEquals("auth_failed", error["code"])
        assertTrue(nonce.isNotEmpty())
    }

    @Test
    fun pairingShowsTheCodeToTheMacAndThePhone() {
        hello("c2", "NewMac")
        send(mapOf("t" to "pair.request"))
        val shown = readUntil("pair.code_shown")
        val request = platform.pairRequests.first()
        assertEquals(request.code, shown["code"])
        assertTrue(Regex("\\d{6}").matches(request.code))
    }

    @Test
    fun allowAfterFiveSecondsPairsWithoutAnyConfirm() {
        // The wait is far longer than the handshake timeout (3 s) on purpose:
        // a person reading two screens must not be cut off by it.
        client.soTimeout = 15_000
        platform.onPairingRequestHandler = { req ->
            Thread {
                Thread.sleep(5_000)
                session!!.respondPairing(req.requestId, true)
            }.start()
        }
        hello("c2", "NewMac")
        send(mapOf("t" to "pair.request"))
        readUntil("pair.code_shown")
        val ok = readUntil("pair.ok")
        assertEquals(64, (ok["key"] as String).length)
        readUntil("welcome")
        assertTrue(platform.clients.any { it.clientId == "c2" })
        assertTrue(platform.paired.any { it.clientId == "c2" })
        send(mapOf("t" to "ping", "ts" to 7))
        assertEquals(7, (readUntil("pong")["ts"] as Number).toInt())
    }

    @Test
    fun denyReportsPairDeniedAndCloses() {
        hello("c3", "Bad")
        send(mapOf("t" to "pair.request"))
        readUntil("pair.code_shown")
        session!!.respondPairing(platform.pairRequests.first().requestId, false)
        assertEquals("pair_denied", readUntil("error")["code"])
        assertEquals(null, reader.readFrame())
        assertTrue(platform.clients.none { it.clientId == "c3" })
    }

    @Test
    fun noDecisionTimesOutWithPairTimeout() {
        runCatching { client.close() }
        runCatching { serverSocket.close() }
        connect(pairDecisionTimeoutMs = 500)
        hello("c4", "Slow")
        send(mapOf("t" to "pair.request"))
        readUntil("pair.code_shown")
        assertEquals("pair_timeout", readUntil("error")["code"])
        assertEquals(null, reader.readFrame())
        assertEquals(listOf(platform.pairRequests.first().requestId), platform.pairEnded.toList())
    }

    @Test
    fun macHangingUpDismissesThePhonePrompt() {
        hello("c5", "Cancelling")
        send(mapOf("t" to "pair.request"))
        readUntil("pair.code_shown")
        val id = platform.pairRequests.first().requestId
        client.close()
        val deadline = System.currentTimeMillis() + 3_000
        while (platform.pairEnded.isEmpty() && System.currentTimeMillis() < deadline) Thread.sleep(20)
        assertEquals(listOf(id), platform.pairEnded.toList())
        session!!.respondPairing(id, true)
        assertTrue(platform.clients.none { it.clientId == "c5" })
    }

    @Test
    fun answeringAfterAllowIsIgnored() {
        hello("c6", "Twice")
        send(mapOf("t" to "pair.request"))
        readUntil("pair.code_shown")
        val id = platform.pairRequests.first().requestId
        session!!.respondPairing(id, true)
        session!!.respondPairing(id, false)
        readUntil("pair.ok")
        readUntil("welcome")
        assertEquals(1, platform.paired.count { it.clientId == "c6" })
    }

    @Test
    fun messagesRejectedBeforeWelcome() {
        send(mapOf("t" to "apps.list"))
        val error = readUntil("error")
        assertEquals("protocol", error["code"])
    }

    @Test
    fun pingPong() {
        addAndAuthenticate()
        send(mapOf("t" to "ping", "ts" to 5))
        val pong = readUntil("pong")
        assertEquals(5L, pong["ts"])
    }

    @Test
    fun appsListAndIcon() {
        addAndAuthenticate()
        platform.apps = listOf(
            AppEntry("com.a", "Alpha", "com.a/.Main"),
            AppEntry("com.b", "Beta", "com.b/.Main"),
        )
        platform.iconResult = "AAAA"
        send(mapOf("t" to "apps.list"))
        val apps = readUntil("apps")["apps"] as List<*>
        assertEquals(2, apps.size)
        send(mapOf("t" to "apps.icon", "pkg" to "com.a"))
        val icon = readUntil("icon")
        assertEquals("com.a", icon["pkg"])
        assertEquals("AAAA", icon["png"])
    }

    @Test
    fun windowLifecycleUsesFlooredSizes() {
        addAndAuthenticate()
        send(mapOf("t" to "window.open", "stream" to 7, "w" to 1000, "h" to 700, "dpi" to 160, "pkg" to "com.android.settings"))
        val opened = readUntil("window.opened")
        assertEquals(992L, opened["w"])
        assertEquals(688L, opened["h"])
        assertEquals(7L, opened["stream"])
        val open = platform.opens.first()
        assertEquals(7, open.stream)
        assertEquals(992, open.w)
        assertEquals(688, open.h)
        assertEquals(160, open.dpi)
        assertTrue(platform.launches.any { it.displayId == open.displayId && it.pkg == "com.android.settings" })

        send(mapOf("t" to "window.resize", "stream" to 7, "w" to 641, "h" to 479, "dpi" to 200))
        await { platform.resizes.any { it == FakePlatform.ResizeCall(7, 640, 464, 200) } }

        send(mapOf("t" to "window.pause", "stream" to 7))
        await { platform.pauses.contains(7) }

        send(mapOf("t" to "window.resume", "stream" to 7))
        await { platform.resumes.contains(7) }

        send(mapOf("t" to "window.keyframe", "stream" to 7))
        await { platform.keyframeRequests.contains(7) }

        send(mapOf("t" to "window.close", "stream" to 7))
        val closed = readUntil("window.closed")
        assertEquals("requested", closed["reason"])
        await { platform.closes.contains(7) }
    }

    @Test
    fun phoneModeLaunchesOwnLauncher() {
        addAndAuthenticate()
        send(mapOf("t" to "window.open", "stream" to 3, "w" to 400, "h" to 800, "dpi" to 160, "mode" to "phone"))
        readUntil("window.opened")
        val open = platform.opens.first()
        assertTrue(
            platform.launches.any {
                it.displayId == open.displayId && it.pkg == Session.OWN_PACKAGE && it.activity == Session.LAUNCHER_ACTIVITY
            },
        )
    }

    @Test
    fun touchMapsToDisplayWithIncreasingTimes() {
        addAndAuthenticate()
        send(mapOf("t" to "window.open", "stream" to 1, "w" to 640, "h" to 480, "dpi" to 160, "pkg" to "com.android.settings"))
        readUntil("window.opened")
        val displayId = platform.opens.first().displayId

        sendFrame(Frames.TYPE_TOUCH, 1, Frames.encodeTouch(TouchPayload(Frames.TOUCH_DOWN, 0, 0.5f, 0.5f)))
        await { platform.touches.size == 1 }
        sendFrame(Frames.TYPE_TOUCH, 1, Frames.encodeTouch(TouchPayload(Frames.TOUCH_MOVE, 0, 0.25f, 0.75f)))
        await { platform.touches.size == 2 }
        sendFrame(Frames.TYPE_TOUCH, 1, Frames.encodeTouch(TouchPayload(Frames.TOUCH_UP, 0, 0.25f, 0.75f)))
        await { platform.touches.size == 3 }

        val down = platform.touches[0]
        val move = platform.touches[1]
        val up = platform.touches[2]
        assertEquals(displayId, down.displayId)
        assertEquals(0.5f, down.nx, 0f)
        assertEquals(down.eventTime, down.downTime)
        assertEquals(down.downTime, move.downTime)
        assertEquals(down.downTime, up.downTime)
        assertTrue(move.eventTime > down.eventTime)
        assertTrue(up.eventTime > move.eventTime)
        assertTrue(platform.inputs.contains(displayId))
    }

    @Test
    fun navBackInjectsBackKeyOnDisplay() {
        addAndAuthenticate()
        send(mapOf("t" to "window.open", "stream" to 1, "w" to 640, "h" to 480, "dpi" to 160, "mode" to "phone"))
        readUntil("window.opened")
        val displayId = platform.opens.first().displayId
        platform.keys.clear()
        send(mapOf("t" to "nav", "stream" to 1, "action" to "back"))
        await { platform.keys.size >= 2 }
        assertEquals(displayId, platform.keys[0].displayId)
        assertEquals(Session.KEYCODE_BACK, platform.keys[0].keycode)
        assertEquals(Frames.ACTION_DOWN, platform.keys[0].action)
        assertEquals(Frames.ACTION_UP, platform.keys[1].action)
    }

    @Test
    fun textGoesToDisplay() {
        addAndAuthenticate()
        send(mapOf("t" to "window.open", "stream" to 1, "w" to 640, "h" to 480, "dpi" to 160, "mode" to "phone"))
        readUntil("window.opened")
        send(mapOf("t" to "text", "stream" to 1, "text" to "hi"))
        await { platform.texts.contains("hi") }
    }

    @Test
    fun windowTitleSentOnChange() {
        addAndAuthenticate()
        topApp = TopApp("com.a", "Alpha")
        send(mapOf("t" to "window.open", "stream" to 1, "w" to 400, "h" to 800, "dpi" to 160, "mode" to "phone"))
        readUntil("window.opened")
        val first = readUntil("window.title")
        assertEquals("com.a", first["pkg"])
        assertEquals("Alpha", first["label"])
        topApp = TopApp("com.b", "Beta")
        val second = readUntil("window.title")
        assertEquals("com.b", second["pkg"])
        assertEquals("Beta", second["label"])
    }

    @Test
    fun stateChangeIsPushed() {
        // Set the changed state before the session starts so the first pushed
        // state (sent when the session becomes active) carries it.
        platform.deviceState = DeviceState(false, 44, true)
        addAndAuthenticate()
        val state = readUntil("state")
        assertEquals(false, state["locked"])
        assertEquals(44L, state["battery"])
        assertEquals(true, state["charging"])
    }

    @Test
    fun stateIsSentOnlyOnChange() {
        addAndAuthenticate()
        readUntil("state")
        // A repeated value from the platform must not produce a second message.
        platform.pushState(platform.deviceState)
        client.soTimeout = 300
        try {
            readJson()
            error("a duplicate state was sent")
        } catch (_: java.net.SocketTimeoutException) {
            // expected: nothing arrived
        }
        client.soTimeout = 5_000
        platform.pushState(DeviceState(false, 43, true))
        assertEquals(43L, readUntil("state")["battery"])
    }

    @Test
    fun stateSubscriptionIsClosedWithTheSession() {
        addAndAuthenticate()
        readUntil("state")
        assertEquals(1, platform.stateSubscriberCount)
        client.close()
        await { platform.stateSubscriberCount == 0 }
    }

    @Test
    fun windowQualityIsForwardedToTheDisplay() {
        addAndAuthenticate()
        send(mapOf("t" to "window.open", "stream" to 1, "w" to 640, "h" to 480, "dpi" to 160, "mode" to "phone"))
        readUntil("window.opened")
        send(mapOf("t" to "window.quality", "stream" to 1, "bitrate" to 1_000_000, "maxFps" to 30))
        await { platform.qualities.isNotEmpty() }
        assertEquals(FakePlatform.QualityCall(1, 1_000_000, 30), platform.qualities.last())
        // One field alone is allowed; both missing is a no-op.
        send(mapOf("t" to "window.quality", "stream" to 1, "bitrate" to 2_000_000))
        await { platform.qualities.size == 2 }
        assertEquals(FakePlatform.QualityCall(1, 2_000_000, null), platform.qualities.last())
        send(mapOf("t" to "window.quality", "stream" to 1))
        send(mapOf("t" to "ping", "ts" to 9))
        assertEquals(9L, readUntil("pong")["ts"])
        assertEquals(2, platform.qualities.size)
    }

    @Test
    fun windowQualityOnAnUnknownStreamReportsNoStream() {
        addAndAuthenticate()
        send(mapOf("t" to "window.quality", "stream" to 7, "bitrate" to 1_000_000))
        assertEquals("no_stream", readUntil("error")["code"])
        assertTrue(platform.qualities.isEmpty())
    }

    @Test
    fun backpressureLowersTheStreamBitrate() {
        addAndAuthenticate()
        send(mapOf("t" to "window.open", "stream" to 1, "w" to 640, "h" to 480, "dpi" to 160, "mode" to "phone"))
        readUntil("window.opened")
        // One frame bigger than the ~250 ms delta budget: the queue drops it and
        // tells the display to lower the stream's bitrate.
        session!!.onFrame(1, 0, false, ByteArray(SendQueue.DEFAULT_MAX_DELTA_BYTES + 1))
        await { platform.backpressures.contains(1) }
        assertTrue(platform.keyframeRequests.contains(1))
    }

    @Test
    fun unknownStreamReportsNoStreamWithoutClosing() {
        addAndAuthenticate()
        send(mapOf("t" to "window.resize", "stream" to 42, "w" to 640, "h" to 480, "dpi" to 160))
        val error = readUntil("error")
        assertEquals("no_stream", error["code"])
        assertEquals(42L, error["stream"])
        // The session must stay open.
        send(mapOf("t" to "ping", "ts" to 7))
        assertEquals(7L, readUntil("pong")["ts"])
    }

    @Test
    fun unknownStreamOnWindowCloseReportsNoStream() {
        addAndAuthenticate()
        send(mapOf("t" to "window.close", "stream" to 99))
        val error = readUntil("error")
        assertEquals("no_stream", error["code"])
        send(mapOf("t" to "ping", "ts" to 1))
        assertEquals(1L, readUntil("pong")["ts"])
    }

    @Test
    fun failedLaunchReportsLaunchFailedWithoutClosing() {
        addAndAuthenticate()
        platform.launchResult = false
        send(mapOf("t" to "window.open", "stream" to 6, "w" to 640, "h" to 480, "dpi" to 160, "pkg" to "com.missing"))
        readUntil("window.opened")
        val error = readUntil("error")
        assertEquals("launch_failed", error["code"])
        assertEquals(6L, error["stream"])
        send(mapOf("t" to "ping", "ts" to 3))
        assertEquals(3L, readUntil("pong")["ts"])
    }

    @Test
    fun appExitClosesWindowWithReason() {
        addAndAuthenticate()
        // The app's task is already there when the window opens, so the watch
        // loop cannot miss it between two polls.
        taskPresent = true
        send(mapOf("t" to "window.open", "stream" to 4, "w" to 640, "h" to 480, "dpi" to 160, "pkg" to "com.android.settings"))
        readUntil("window.opened")
        Thread.sleep(300)
        // …and the user backs out of it.
        taskPresent = false
        val closed = readUntil("window.closed")
        assertEquals("app_exited", closed["reason"])
        assertEquals(4L, closed["stream"])
        await { platform.closes.contains(4) }
    }

    @Test
    fun phoneModeWindowIsNotAutoClosed() {
        addAndAuthenticate()
        taskPresent = true
        send(mapOf("t" to "window.open", "stream" to 5, "w" to 400, "h" to 800, "dpi" to 160, "mode" to "phone"))
        readUntil("window.opened")
        Thread.sleep(200)
        taskPresent = false
        Thread.sleep(200)
        // Still open: the phone-mode window runs our own launcher.
        send(mapOf("t" to "ping", "ts" to 9))
        assertEquals(9L, readUntil("pong")["ts"])
    }
}
