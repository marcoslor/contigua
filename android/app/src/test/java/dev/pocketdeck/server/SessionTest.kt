package dev.pocketdeck.server

import dev.pocketdeck.e2ee.PairingCodeV2
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
import java.util.concurrent.CopyOnWriteArrayList

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

    private fun connect(pairDecisionTimeoutMs: Long, autoApprovePairing: Boolean = false,
                        taskMove: TaskMove? = null) {
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
                clipboard = platform,
                packages = null,
                taskMove = taskMove,
                now = { clock++ },
                log = {},
                handshakeTimeoutMs = 3_000,
                pairDecisionTimeoutMs = pairDecisionTimeoutMs,
                exitPollIntervalMs = 50,
                autoApprovePairing = autoApprovePairing,
                tlsView = TlsV2Fixture.view,
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

    /** A canned task list; records the move calls. */
    private class FakeTaskMove(var list: List<SystemTask>?, var moveResult: Boolean = true) : TaskMove {
        val moves = CopyOnWriteArrayList<Pair<Int, Int>>()
        override fun tasks(): List<SystemTask>? = list
        override fun move(taskId: Int, displayId: Int): Boolean {
            moves.add(taskId to displayId)
            return moveResult
        }
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

    private fun hello(clientId: String, name: String) {
        send(mapOf("t" to "hello", "v" to 2, "clientId" to clientId, "name" to name))
    }

    private fun authenticate(clientId: String, name: String = "MacBook"): Map<String, Any?> {
        hello(clientId, name)
        return readUntil("welcome")
    }
    private fun addAndAuthenticate(): String {
        platform.clients.add(PairedClient("c1", "MacBook", TlsV2Fixture.MAC_FP_HEX))
        addAndAuthenticateCommon()
        return TlsV2Fixture.MAC_FP_HEX
    }

    private fun addAndAuthenticateCommon() {
        authenticate("c1")
        // The session starts the clipboard listener after queuing welcome, so a
        // test that copies right after reading welcome must wait for it.
        await { platform.clipListening }
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
    fun authSuccessSendsWelcome() {
        platform.clients.add(PairedClient("c1", "MacBook", TlsV2Fixture.MAC_FP_HEX))
        val welcome = authenticate("c1")
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
    fun versionOneIsRefusedWithTheVersionError() {
        send(mapOf("t" to "hello", "v" to 1, "clientId" to "cX", "name" to "Old"))
        val error = readUntil("error")
        assertEquals("version", error["code"])
        assertEquals(null, reader.readFrame())
    }

    /**
     * A paired clientId whose TLS fingerprint no longer matches the stored pin
     * cannot welcome (§7: reinstalled Mac → pair again).
     */
    @Test
    fun stalePinOnHelloIsRefusedWithBadPin() {
        platform.clients.add(PairedClient("c1", "MacBook", "9".repeat(64)))
        hello("c1", "Rotated")
        val error = readUntil("error")
        assertEquals("bad_pin", error["code"])
    }

    /**
     * The phone-side §4 machine, end to end: commit → (nonce) → reveal, then the
     * app prompt with the code derived from the exact inputs (vector B fixture).
     */
    @Test
    fun pairingCommitsThenRevealsAndTheCodeMatchesTheInputs() {
        hello("c2", "NewMac")
        send(mapOf("t" to "pair.request"))
        val commit = readUntil("pair.commit")
        send(mapOf("t" to "pair.nonce", "n" to "3fb962da6c0eaaee44a7a16a2bcf9c97")) // vector B Nm
        val reveal = readUntil("pair.reveal")
        val np = TlsV2Fixture.bytesOf(reveal["n"] as String)
        assertEquals(16, np.size)
        // The commitment binds exactly what the design says (§4): Np, phoneFP, macFP.
        val expectedCommit = PairingCodeV2.hex(
            PairingCodeV2.commit(np, TlsV2Fixture.phoneFpBytes, TlsV2Fixture.macFpBytes))
        assertEquals(expectedCommit, commit["c"])
        // The prompt's code: §4 formula over the fixture exporter + both Ns.
        val expectedCode = PairingCodeV2.codeHex(
            PairingCodeV2.code(TlsV2Fixture.exporterBytes, TlsV2Fixture.macFpBytes, TlsV2Fixture.phoneFpBytes,
                               TlsV2Fixture.bytesOf("3fb962da6c0eaaee44a7a16a2bcf9c97"), np))
        await { platform.pairRequests.isNotEmpty() }
        val request = platform.pairRequests.first()
        assertEquals(expectedCode, request.code)
        assertTrue(Regex("\\d{6}").matches(request.code))
    }

    @Test
    fun allowingAfterFiveSecondsPairsAndCarriesThePins() {
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
        readUntil("pair.commit")
        send(mapOf("t" to "pair.nonce", "n" to "0".repeat(32)))
        readUntil("pair.reveal")
        val ok = readUntil("pair.ok")
        assertEquals(TlsV2Fixture.MAC_FP_HEX, ok["macFP"])
        assertEquals(TlsV2Fixture.PHONE_FP_HEX, ok["phoneFP"])
        readUntil("welcome")
        assertEquals(TlsV2Fixture.MAC_FP_HEX, platform.clients.first { it.clientId == "c2" }.macFpHex)
        assertEquals(TlsV2Fixture.MAC_FP_HEX, platform.paired.first { it.clientId == "c2" }.macFpHex)
        send(mapOf("t" to "ping", "ts" to 7))
        assertEquals(7, (readUntil("pong")["ts"] as Number).toInt())
    }

    @Test
    fun denyReportsPairDeniedAndCloses() {
        hello("c3", "Bad")
        send(mapOf("t" to "pair.request"))
        readUntil("pair.commit")
        send(mapOf("t" to "pair.nonce", "n" to "0".repeat(32)))
        readUntil("pair.reveal")
        await { platform.pairRequests.isNotEmpty() }
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
        readUntil("pair.commit")
        send(mapOf("t" to "pair.nonce", "n" to "0".repeat(32)))
        readUntil("pair.reveal")
        assertEquals("pair_timeout", readUntil("error")["code"])
        assertEquals(null, reader.readFrame())
        assertEquals(listOf(platform.pairRequests.first().requestId), platform.pairEnded.toList())
    }

    @Test
    fun macHangingUpDismissesThePhonePrompt() {
        hello("c5", "Cancelling")
        send(mapOf("t" to "pair.request"))
        readUntil("pair.commit")
        send(mapOf("t" to "pair.nonce", "n" to "0".repeat(32)))
        readUntil("pair.reveal")
        await { platform.pairRequests.isNotEmpty() }
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
        readUntil("pair.commit")
        send(mapOf("t" to "pair.nonce", "n" to "0".repeat(32)))
        readUntil("pair.reveal")
        await { platform.pairRequests.isNotEmpty() }
        val id = platform.pairRequests.first().requestId
        session!!.respondPairing(id, true)
        session!!.respondPairing(id, false)
        readUntil("pair.ok")
        readUntil("welcome")
        assertEquals(1, platform.paired.count { it.clientId == "c6" })
    }

    @Test
    fun autoApproveFalseStillWaitsForDecision() {
        runCatching { client.close() }
        runCatching { serverSocket.close() }
        connect(pairDecisionTimeoutMs = 1000, autoApprovePairing = false)
        hello("cAutoFalse", "MacAutoFalse")
        send(mapOf("t" to "pair.request"))
        readUntil("pair.commit")
        send(mapOf("t" to "pair.nonce", "n" to "0".repeat(32)))
        readUntil("pair.reveal")
        await { platform.pairRequests.size == 1 }
        assertEquals("pair_timeout", readUntil("error")["code"])
        assertEquals(0, platform.paired.count { it.clientId == "cAutoFalse" })
    }

    @Test
    fun autoApprovePairsWithoutAskingThePhone() {
        runCatching { client.close() }
        runCatching { serverSocket.close() }
        connect(pairDecisionTimeoutMs = 30_000, autoApprovePairing = true)
        hello("cAuto", "MacAuto")
        send(mapOf("t" to "pair.request"))
        readUntil("pair.commit")
        send(mapOf("t" to "pair.nonce", "n" to "0".repeat(32)))
        readUntil("pair.reveal")
        readUntil("pair.ok")
        readUntil("welcome")
        assertEquals(0, platform.pairRequests.size)
        assertEquals(1, platform.paired.count { it.clientId == "cAuto" })
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
        // A non-adaptive icon sends no layers at all.
        assertEquals(false, icon.containsKey("fg"))
        assertEquals(false, icon.containsKey("bg"))
        assertEquals(false, icon.containsKey("mono"))
    }

    @Test
    fun iconMessageCarriesTheAdaptiveLayersAsOptionalFields() {
        addAndAuthenticate()
        platform.apps = listOf(AppEntry("com.a", "Alpha", "com.a/.Main"))
        platform.iconResult = "AAAA"
        platform.iconLayersResult = IconLayers("fg-b64", "bg-b64", "mono-b64")
        send(mapOf("t" to "apps.icon", "pkg" to "com.a"))
        val icon = readUntil("icon")
        assertEquals("AAAA", icon["png"])
        assertEquals("fg-b64", icon["fg"])
        assertEquals("bg-b64", icon["bg"])
        assertEquals("mono-b64", icon["mono"])
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
    fun phoneModeMirrorsDisplayZeroAtItsAspect() {
        addAndAuthenticate()
        send(mapOf("t" to "window.open", "stream" to 3, "w" to 400, "h" to 800, "dpi" to 160, "mode" to "phone"))
        val opened = readUntil("window.opened")
        assertEquals(0, (opened["displayId"] as Number).toInt())
        // 1080x2340 inside 400x800: height-bound, 16-aligned.
        assertEquals(368, (opened["w"] as Number).toInt())
        assertEquals(800, (opened["h"] as Number).toInt())
        assertEquals(listOf(3), platform.mirrors.toList())
        assertTrue(platform.opens.isEmpty())
        assertTrue(platform.launches.isEmpty())
        // The mirror leaves the phone's power alone.
        assertTrue(platform.activeStreams.all { it.isEmpty() })
    }

    @Test
    fun phoneModeInputGoesToDisplayZeroWithoutPoking() {
        addAndAuthenticate()
        send(mapOf("t" to "window.open", "stream" to 1, "w" to 400, "h" to 800, "dpi" to 160, "mode" to "phone"))
        readUntil("window.opened")
        sendFrame(Frames.TYPE_TOUCH, 1, Frames.encodeTouch(TouchPayload(Frames.TOUCH_DOWN, 0, 0.5f, 0.5f)))
        await { platform.touches.isNotEmpty() }
        assertEquals(0, platform.touches[0].displayId)
        assertTrue(platform.inputs.isEmpty())
    }

    @Test
    fun phoneModeHomeAndRecentsAreKeysOnDisplayZero() {
        addAndAuthenticate()
        send(mapOf("t" to "window.open", "stream" to 1, "w" to 400, "h" to 800, "dpi" to 160, "mode" to "phone"))
        readUntil("window.opened")
        send(mapOf("t" to "nav", "stream" to 1, "action" to "home"))
        send(mapOf("t" to "nav", "stream" to 1, "action" to "recents"))
        await { platform.keys.size >= 4 }
        assertEquals(listOf(Session.KEYCODE_HOME, Session.KEYCODE_HOME, Session.KEYCODE_APP_SWITCH, Session.KEYCODE_APP_SWITCH),
            platform.keys.map { it.keycode })
        assertTrue(platform.keys.all { it.displayId == 0 })
    }

    @Test
    fun phoneModeWithoutMirrorSupportReportsAnError() {
        addAndAuthenticate()
        platform.mirrorFails = true
        send(mapOf("t" to "window.open", "stream" to 1, "w" to 400, "h" to 800, "dpi" to 160, "mode" to "phone"))
        assertEquals("mirror_unavailable", readUntil("error")["code"])
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
        val displayId = 0
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
        // Still open: the phone mirror is not an app window.
        send(mapOf("t" to "ping", "ts" to 9))
        assertEquals(9L, readUntil("pong")["ts"])
    }

    // ------------------------------------------------------------------
    // share phone -> Mac (docs/design/sharein.md)
    // ------------------------------------------------------------------

    @Test
    fun shareBeforeWelcomeIsNoSession() {
        await { session != null }
        assertEquals(ShareStatus.NO_SESSION, session!!.shareText("hi"))
        assertEquals(ShareStatus.NO_SESSION, session!!.shareFile("a.png", "image/png", java.io.ByteArrayInputStream(ByteArray(1))))
    }

    @Test
    fun serverWithoutSessionIsNoSession() {
        val server = Server({ error("no sessions here") })
        assertEquals(ShareStatus.NO_SESSION, server.shareText("hi"))
        assertEquals(ShareStatus.NO_SESSION, server.shareFile("a.png", "image/png", java.io.ByteArrayInputStream(ByteArray(1))))
    }

    @Test
    fun sharedTextAndFileReachTheMac() {
        addAndAuthenticate()
        assertEquals(ShareStatus.OK, session!!.shareText("https://example.com"))
        assertEquals("https://example.com", readUntil("share.text")["text"])
        val data = ByteArray(300_000) { (it % 251).toByte() }
        assertEquals(ShareStatus.OK, session!!.shareFile("a.png", "image/png", java.io.ByteArrayInputStream(data)))
        val begin = readUntil("share.file")
        val id = (begin["id"] as Number).toInt()
        var got = ByteArray(0)
        while (true) {
            val frame = reader.readFrame() ?: error("closed")
            if (frame.type == Frames.TYPE_SHARE_DATA) {
                assertEquals(id, frame.stream)
                got += frame.payload
                continue
            }
            val m = Json.parseObject(String(frame.payload))
            if (m["t"] == "share.end") {
                assertEquals(data.size.toLong(), (m["size"] as Number).toLong())
                break
            }
        }
        assertTrue(data.contentEquals(got))
    }

    // ------------------------------------------------------------------
    // clipboard sync
    // ------------------------------------------------------------------

    @Test
    fun phoneClipboardChangeIsSent() {
        addAndAuthenticate()
        platform.changeClip("from phone")
        assertEquals("from phone", readUntil("clip.set")["text"])
    }

    @Test
    fun repeatedPhoneClipboardTextIsSentOnce() {
        addAndAuthenticate()
        platform.changeClip("same")
        platform.changeClip("same")
        platform.changeClip("next")
        assertEquals("same", readUntil("clip.set")["text"])
        assertEquals("next", readUntil("clip.set")["text"])
    }

    @Test
    fun clipAtOneMiBIsSentAndLargerIsNot() {
        addAndAuthenticate()
        platform.changeClip("x".repeat(CLIP_MAX_BYTES))
        platform.changeClip("x".repeat(CLIP_MAX_BYTES + 1))
        platform.changeClip("small")
        assertEquals(CLIP_MAX_BYTES, (readUntil("clip.set")["text"] as String).length)
        assertEquals("small", readUntil("clip.set")["text"])
    }

    @Test
    fun receivedClipIsWrittenToClipboard() {
        addAndAuthenticate()
        send(mapOf("t" to "clip.set", "text" to "from mac"))
        await { platform.clipWrites.contains("from mac") }
        assertEquals("from mac", platform.clipText)
    }

    @Test
    fun receivedClipIsNotEchoedBack() {
        addAndAuthenticate()
        send(mapOf("t" to "clip.set", "text" to "from mac"))
        await { platform.clipWrites.contains("from mac") }
        // The write notified the clipboard listener; the next clip.set has to be
        // the phone's own copy, not the text that just arrived.
        platform.changeClip("from phone")
        assertEquals("from phone", readUntil("clip.set")["text"])
    }

    @Test
    fun oversizedReceivedClipIsIgnored() {
        addAndAuthenticate()
        send(mapOf("t" to "clip.set", "text" to "x".repeat(CLIP_MAX_BYTES + 1)))
        send(mapOf("t" to "clip.set", "text" to "ok"))
        await { platform.clipWrites.contains("ok") }
        assertEquals(listOf("ok"), platform.clipWrites.toList())
    }

    @Test
    fun linkOpenViewsTheUrlOnANewDisplay() {
        addAndAuthenticate()
        send(mapOf("t" to "link.open", "stream" to 9, "w" to 640, "h" to 480, "dpi" to 160, "url" to " https://example.com/a?b=1 "))
        val opened = readUntil("window.opened")
        assertEquals(9L, opened["stream"])
        val open = platform.opens.first()
        await { platform.views.isNotEmpty() }
        assertEquals(FakePlatform.ViewCall(open.displayId, "https://example.com/a?b=1"), platform.views.first())
        assertTrue(platform.launches.isEmpty())
    }

    @Test
    fun linkOpenRejectsDisallowedSchemesWithoutADisplay() {
        addAndAuthenticate()
        for (url in listOf("intent://x#Intent;component=a/b;end", "file:///sdcard/x", "content://a/b", "javascript:alert(1)", "")) {
            send(mapOf("t" to "link.open", "stream" to 2, "w" to 640, "h" to 480, "dpi" to 160, "url" to url))
            val error = readUntil("error")
            assertEquals("bad_url", error["code"])
            assertEquals(2L, error["stream"])
        }
        send(mapOf("t" to "ping", "ts" to 4))
        assertEquals(4L, readUntil("pong")["ts"])
        assertTrue(platform.opens.isEmpty())
        assertTrue(platform.views.isEmpty())
    }

    @Test
    fun linkWithoutAHandlerReportsLaunchFailed() {
        addAndAuthenticate()
        platform.launchResult = false
        send(mapOf("t" to "link.open", "stream" to 3, "w" to 640, "h" to 480, "dpi" to 160, "url" to "geo:0,0?q=Lisbon"))
        readUntil("window.opened")
        assertEquals("launch_failed", readUntil("error")["code"])
    }

    // ---- task.continue -----------------------------------------------------

    @Test
    fun taskContinueMovesTheForegroundTaskAndGoesHome() {
        val mover = FakeTaskMove(
            listOf(
                SystemTask(21, "com.android.systemui", null, 0, false, true),
                SystemTask(30, "com.example.reader", "com.example.reader.Reader", 0, false, false),
            ),
        )
        reconnectWith(mover)
        send(mapOf("t" to "task.continue", "stream" to 4, "w" to 900, "h" to 600, "dpi" to 160))
        val opened = readUntil("window.opened")
        assertEquals("moved", opened["started"])
        await { mover.moves.isNotEmpty() }
        assertEquals(listOf(30 to platform.opens.first().displayId), mover.moves)
        // The move is the handoff; the fallback launch must not also fire.
        assertTrue(platform.launches.isEmpty())
        // The phone's own screen returns home (KEYCODE_HOME on display 0).
        await { platform.keys.isNotEmpty() }
        assertEquals(0, platform.keys.first().displayId)
        assertEquals(Session.KEYCODE_HOME, platform.keys.first().keycode)
    }

    @Test
    fun taskContinueRelaunchesFreshWhenTheMoveIsRefused() {
        val mover = FakeTaskMove(listOf(SystemTask(31, "com.example.reader", null, 0, false, false)), moveResult = false)
        reconnectWith(mover)
        send(mapOf("t" to "task.continue", "stream" to 5, "w" to 900, "h" to 600, "dpi" to 160))
        val opened = readUntil("window.opened")
        assertEquals("fresh", opened["started"])
        await { platform.launches.isNotEmpty() }
        assertEquals("com.example.reader", platform.launches.first().pkg)
        // Not moved: the phone's own screen still shows the app, no home press.
        assertTrue(platform.keys.none { it.keycode == Session.KEYCODE_HOME })
    }

    @Test
    fun taskContinueWithNothingContinuableAnswersNothingToContinue() {
        val mover = FakeTaskMove(
            listOf(
                SystemTask(21, "com.android.systemui", null, 0, false, true),
                SystemTask(22, Session.OWN_PACKAGE, null, 0, false, false),
                SystemTask(23, "com.android.launcher3", null, 0, true, false),
            ),
        )
        reconnectWith(mover)
        send(mapOf("t" to "task.continue", "stream" to 6, "w" to 900, "h" to 600, "dpi" to 160))
        val error = readUntil("error")
        assertEquals("nothing_to_continue", error["code"])
        assertEquals(6L, error["stream"])
        assertTrue(platform.opens.isEmpty())
        assertTrue(mover.moves.isEmpty())
    }

    @Test
    fun taskContinueWithoutTheSeamAnswersNotAvailable() {
        reconnectWith(null)
        send(mapOf("t" to "task.continue", "stream" to 7, "w" to 900, "h" to 600, "dpi" to 160))
        assertEquals("not_available", readUntil("error")["code"])
    }

    @Test
    fun taskContinueKeepsTheStreamsWatchAliveLikeOtherWindows() {
        val mover = FakeTaskMove(listOf(SystemTask(40, "com.example.reader", null, 0, false, false)))
        reconnectWith(mover)
        send(mapOf("t" to "task.continue", "stream" to 8, "w" to 480, "h" to 320, "dpi" to 160))
        readUntil("window.opened")
        // The window's subject follows the top app on its display, like every window.
        topApp = TopApp("com.example.reader", "Reader")
        val title = readUntil("window.title")
        assertEquals(8L, title["stream"])
        assertEquals("Reader", title["label"])
    }

    /** Tears down the current session, reconnects with [taskMove]. */
    @Suppress("SameParameterValue")
    private fun reconnectWith(taskMove: TaskMove?) {
        runCatching { client.close() }
        runCatching { serverSocket.close() }
        connect(pairDecisionTimeoutMs = 30_000, taskMove = taskMove)
        addAndAuthenticate()
    }

    private companion object {
        const val CLIP_MAX_BYTES = 1_048_576
    }
}
