package dev.pocketdeck.server

import dev.pocketdeck.e2ee.PairingCodeV2
import dev.pocketdeck.proto.Frame
import dev.pocketdeck.proto.FrameReader
import dev.pocketdeck.proto.Frames
import dev.pocketdeck.proto.HoverPayload
import dev.pocketdeck.proto.Json
import dev.pocketdeck.proto.PathCodec
import dev.pocketdeck.proto.TouchPayload
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference

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
    @Volatile private var topTask: TopTask? = null
    @Volatile private var taskPresent = false
    @Volatile private var taskChecks = 0
    private var acceptThread: Thread? = null
    private var clock = 1_000L

    @Before
    fun setUp() {
        platform = FakePlatform()
        connect(pairDecisionTimeoutMs = 30_000)
    }

    private fun connect(pairDecisionTimeoutMs: Long, autoApprovePairing: Boolean = false,
                        taskMove: TaskMove? = null,
                        pairCooldown: PairCooldown? = null,
                        pendingQr: (() -> Map<String, Any?>?)? = null,
                        onQrConsumed: (() -> Unit)? = null,
                        gates: () -> GateSettings? = { GateSettings(true, true) },
                        secureProbe: SecureProbe? = null,
                        strays: Int = 0,
                        waitForPrevious: Boolean = true,
                        tlsView: Session.TlsView = TlsV2Fixture.view) {
        // A test of the fast re-adopt (ISS-13) connects while the old teardown
        // still runs; every other test keeps PAIR-21's one-at-a-time rule.
        if (waitForPrevious) awaitPreviousSessionEnded()
        // This connect's listener and client port: the accept thread must take
        // this connection even when a later connect has replaced the fields.
        val listener = ServerSocket(0, 8, InetAddress.getLoopbackAddress())
        serverSocket = listener
        repeat(strays) { Socket(InetAddress.getLoopbackAddress(), listener.localPort).close() }
        client = Socket(InetAddress.getLoopbackAddress(), listener.localPort)
        client.soTimeout = 5_000
        reader = FrameReader(client.getInputStream())
        val ownPort = client.localPort
        // One seq space per session: a fresh connection starts at 1.
        outSeq = 1L
        // The accept must own this test's socket before connect() returns: a
        // late accept thread would otherwise take the next connection and run
        // it with this call's (stale) parameters.
        val accepted = CountDownLatch(1)
        val accept = Thread {
            val s = acceptOwnClient(listener, ownPort)
            accepted.countDown()
            if (s == null) return@Thread
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
                titleObserver = { topTask },
                taskPresence = { taskPresent.also { taskChecks++ } },
                clipboard = platform,
                packages = null,
                taskMove = taskMove,
                now = { clock++ },
                log = {},
                handshakeTimeoutMs = 3_000,
                pairDecisionTimeoutMs = pairDecisionTimeoutMs,
                exitPollIntervalMs = 50,
                autoApprovePairing = autoApprovePairing,
                pairCooldown = pairCooldown ?: PairCooldown(),
                pendingQrProvider = pendingQr ?: { null },
                pendingQrConsumer = onQrConsumed ?: {},
                tlsView = tlsView,
                gateProvider = gates,
                secureProbe = secureProbe,
            )
            session = sess
            sess.run()
        }
        accept.isDaemon = true
        accept.start()
        acceptThread = accept
        check(accepted.await(5, TimeUnit.SECONDS)) { "connect was not accepted" }
    }

    /**
     * PAIR-21: the phone serves one session at a time, and the next one is only
     * created after the previous teardown has finished. The helper mirrors that
     * order for the JVM harness. The clipboard's own listener is owner-scoped
     * (ISS-13), so a teardown that outlives the slot cannot silence the next
     * session either.
     */
    private fun awaitPreviousSessionEnded() {
        val previous = acceptThread ?: return
        previous.join(TEARDOWN_WAIT_MS)
        assertTrue("the previous session's teardown never ended", !previous.isAlive)
    }

    /**
     * The connection this test's client opened on [listener]; anything else
     * that reached the port first is closed. A stray local connection taken
     * for the Mac would make the test read that peer's bytes as protocol
     * frames (a full K1 run is not alone on the machine). Both the listener
     * and the port are this connect's own: a thread left over from an earlier
     * connect must not take a later one's client.
     */
    private fun acceptOwnClient(listener: ServerSocket, clientPort: Int): Socket? {
        while (true) {
            val socket = try {
                listener.accept()
            } catch (_: java.io.IOException) {
                // A later connect or the teardown closed this listener.
                return null
            }
            if (socket.port == clientPort) {
                socket.tcpNoDelay = true
                return socket
            }
            runCatching { socket.close() }
        }
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

    private var outSeq = 1L

    private fun send(obj: Map<String, Any?>) {
        val out = client.getOutputStream()
        val bytes = Frames.encodeJson(0, Json.encode(obj))
        val t = obj["t"] as? String
        val bare = t == "hello" || t == "pair.request" || t == "pair.nonce" || t == "pair.ok"
        out.write(if (bare) bytes else PathCodec.encodeReliable(outSeq++, frameOf(bytes)))
        out.flush()
    }

    private fun frameOf(encoded: ByteArray): Frame =
        Frame(encoded[4].toInt() and 0xFF, PathCodec.readInt(encoded, 5), encoded.copyOfRange(9, encoded.size))

    /** Sends a reliable JSON frame with an explicit seq (the reorder vectors). */
    private fun sendJsonAt(seq: Long, obj: Map<String, Any?>) {
        val bytes = Frames.encodeJson(0, Json.encode(obj))
        val out = client.getOutputStream()
        out.write(PathCodec.encodeReliable(seq, frameOf(bytes)))
        out.flush()
    }

    /** Best-effort: a peer that answered and closed may reset before the ACK. */
    private fun sendAck(ack: Long) = runCatching {
        val out = client.getOutputStream()
        out.write(PathCodec.encodeAck(ack))
        out.flush()
    }

    private fun sendFrame(type: Int, stream: Int, payload: ByteArray) {
        val out = client.getOutputStream()
        val frame = Frame(type, stream, payload)
        out.write(if (PathCodec.isReliable(type)) PathCodec.encodeReliable(outSeq++, frame)
                  else Frames.encode(type, stream, payload))
        out.flush()
    }

    private fun readJson(): Map<String, Any?> {
        while (true) {
            val frame = reader.readFrame() ?: error("connection closed")
            when (frame.type) {
                PathCodec.TYPE_ACK -> continue
                PathCodec.TYPE_RELIABLE -> {
                    val inner = PathCodec.decodeReliable(frame)
                    sendAck(inner.seq + 1)
                    return Json.parseObject(String(inner.inner.payload))
                }
                else -> return Json.parseObject(String(frame.payload))
            }
        }
    }

    private fun readUntil(t: String): Map<String, Any?> {
        repeat(30) {
            val m = readJson()
            if (m["t"] == t) return m
        }
        error("never received '$t'")
    }

    /**
     * Stats messages queued before the next pong. A ping goes out after the
     * caller's wait, so the phone's queue order says whether a tick sent one;
     * no socket timeout is involved (a timeout can cut a frame in half).
     */
    private fun statsBeforePong(): Int {
        send(mapOf("t" to "ping", "ts" to System.nanoTime()))
        var count = 0
        repeat(64) {
            val message = readJson()
            when (message["t"]) {
                "stream.stats" -> count++
                "pong" -> return count
            }
        }
        error("never received the pong")
    }

    /**
     * The Mac's hello. [pairing] is the user-driven pairing's own field
     * (PAIR-23): without it the phone reads the Mac as one that believes it is
     * paired and answers `not_paired`.
     */
    private fun hello(clientId: String, name: String, pairing: Boolean = false,
                      media: Boolean = false) {
        val fields = mutableMapOf<String, Any?>(
            "t" to "hello", "v" to 4, "path" to "a1b2c3d4", "clientId" to clientId, "name" to name,
        )
        if (pairing) fields["pair"] = true
        // The planned UDP capability: a hello may offer it, but this merge has
        // no UDP plane, so the welcome must not answer with a media field.
        if (media) fields["media"] = listOf("udp")
        send(fields)
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
        // The phone starts with the gate off; this Mac has the switch on, as a
        // real Mac sends right after welcome (SHARE-13). Wait for it to apply
        // before a test copies anything; no frame is consumed doing so.
        send(mapOf("t" to "clip.enable", "on" to true))
        await { session?.clipboardGateOn == true }
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

    /** PATH-1: a v3 Mac (or one that sends no v) is refused with this phone's
     *  own version and closed before any `welcome` or session state exists. */
    @Test
    fun aV3MacIsRefusedWithThisPhonesVersion() {
        send(mapOf("t" to "hello", "v" to 3, "path" to "a1b2c3d4", "clientId" to "cV3", "name" to "OldMac"))
        val error = readUntil("error")
        assertEquals("version", error["code"])
        assertEquals(4L, (error["v"] as Number).toLong())
        assertEquals(listOf(3), platform.versionRefusals)
        assertEquals(null, reader.readFrame())
    }

    @Test
    fun aHelloWithNoVersionIsRefusedLikeAV3Mac() {
        send(mapOf("t" to "hello", "path" to "a1b2c3d4", "clientId" to "cNone", "name" to "OldMac"))
        val error = readUntil("error")
        assertEquals("version", error["code"])
        assertEquals(4L, (error["v"] as Number).toLong())
        assertEquals(null, reader.readFrame())
    }

    @Test
    fun aFutureMacIsRefusedWithThisPhonesVersion() {
        send(mapOf("t" to "hello", "v" to 5, "path" to "a1b2c3d4", "clientId" to "cV5", "name" to "NewMac"))
        val error = readUntil("error")
        assertEquals("version", error["code"])
        assertEquals(4L, (error["v"] as Number).toLong())
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
        hello("c2", "NewMac", pairing = true)
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
    fun aPairingWithoutAnExporterFailsClosed() {
        connect(
            pairDecisionTimeoutMs = 30_000,
            tlsView = Session.TlsView(
                peerFingerprint = { TlsV2Fixture.macFpBytes },
                exporter = { null },
            ),
        )
        hello("c2", "NewMac", pairing = true)
        send(mapOf("t" to "pair.request"))
        readUntil("pair.commit")
        send(mapOf("t" to "pair.nonce", "n" to "3fb962da6c0eaaee44a7a16a2bcf9c97"))
        val error = readUntil("error")
        assertEquals("pair_exporter", error["code"])
        assertTrue("no code may be shown", platform.pairRequests.isEmpty())
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
        hello("c2", "NewMac", pairing = true)
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
    fun aSessionInPairingSendsNothingButThePairingMachine() {
        // SECURITY (the rig caught it): a session that has not authenticated
        // must say nothing but the handshake and pairing machine. The app can
        // push a notify toggle and the person's own panel can change at any
        // time; both are post-welcome state. Before the fix, `notify.state`
        // landed where the Mac expected `pair.reveal` (boot 1 of the rig).
        hello("c9", "NewMac", pairing = true)
        send(mapOf("t" to "pair.request"))
        readUntil("pair.commit")

        session!!.reconcileNotify()   // the app's notification toggle changed
        platform.endPanelHold()       // the person's own panel state changed

        val preReady = setOf("welcome", "pair.commit", "pair.reveal", "pair.ok", "pair.qr", "error")
        val unexpected = ArrayList<String>()
        client.soTimeout = 400
        try {
            while (true) {
                val frame = reader.readFrame() ?: break
                val t = Json.parseObject(String(frame.payload))["t"] as? String ?: ""
                if (t !in preReady) unexpected.add(t)
            }
        } catch (_: java.net.SocketTimeoutException) {
            // Nothing else arrived: the quiet the test wants.
        } finally {
            client.soTimeout = 5_000
        }
        assertTrue("a session in pairing sent $unexpected", unexpected.isEmpty())
    }

    @Test
    fun denyReportsPairDeniedAndCloses() {        hello("c3", "Bad", pairing = true)
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
        val cooldown = PairCooldown()
        connect(pairDecisionTimeoutMs = 500, pairCooldown = cooldown)
        hello("c4", "Slow", pairing = true)
        send(mapOf("t" to "pair.request"))
        readUntil("pair.commit")
        send(mapOf("t" to "pair.nonce", "n" to "0".repeat(32)))
        readUntil("pair.reveal")
        assertEquals("pair_timeout", readUntil("error")["code"])
        assertEquals(null, reader.readFrame())
        assertEquals(listOf(platform.pairRequests.first().requestId), platform.pairEnded.toList())
        // M-1: the timeout also opens the quiet window.
        assertEquals(true, cooldown.active())
    }

    /**
     * M-1: after a Deny, a reconnect's `pair.request` is refused with the
     * existing pair_denied code for 30 s (one process-wide window, not one per
     * session) and prompts again after it.
     */
    @Test
    fun aNewPairRequestIsRefusedWhileTheDenyWindowIsOpen() {
        var ms = 1_000L
        val cooldown = PairCooldown(now = { ms })
        connect(pairDecisionTimeoutMs = 5_000, pairCooldown = cooldown)
        hello("c7", "Spam", pairing = true)
        send(mapOf("t" to "pair.request"))
        readUntil("pair.commit")
        send(mapOf("t" to "pair.nonce", "n" to "0".repeat(32)))
        readUntil("pair.reveal")
        await { platform.pairRequests.isNotEmpty() }
        session!!.respondPairing(platform.pairRequests.first().requestId, false)
        assertEquals("pair_denied", readUntil("error")["code"])

        runCatching { client.close() }
        runCatching { serverSocket.close() }
        connect(pairDecisionTimeoutMs = 5_000, pairCooldown = cooldown)
        hello("c8", "SpamAgain", pairing = true)
        send(mapOf("t" to "pair.request"))
        // PAIR-5: the cooldown has its own code, so the Mac can say "wait a
        // moment" instead of repeating a denial the person already saw.
        assertEquals("pair_cooldown", readUntil("error")["code"])
        assertEquals(1, platform.pairRequests.size)

        ms += PairCooldown.WINDOW_MS
        runCatching { client.close() }
        runCatching { serverSocket.close() }
        connect(pairDecisionTimeoutMs = 5_000, pairCooldown = cooldown)
        hello("c9", "Later", pairing = true)
        send(mapOf("t" to "pair.request"))
        readUntil("pair.commit")
    }

    @Test
    fun macHangingUpDismissesThePhonePrompt() {
        hello("c5", "Cancelling", pairing = true)
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
        hello("c6", "Twice", pairing = true)
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
        hello("cAutoFalse", "MacAutoFalse", pairing = true)
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
        hello("cAuto", "MacAuto", pairing = true)
        send(mapOf("t" to "pair.request"))
        readUntil("pair.commit")
        send(mapOf("t" to "pair.nonce", "n" to "0".repeat(32)))
        readUntil("pair.reveal")
        readUntil("pair.ok")
        readUntil("welcome")
        assertEquals(0, platform.pairRequests.size)
        assertEquals(1, platform.paired.count { it.clientId == "cAuto" })
    }

    /**
     * L-3: the scanned QR secret is one-time — serving `pair.qr` clears it, so
     * a second hello with the same secret gets no answer at all.
     */
    @Test
    fun aServedQrSecretIsConsumed() {
        runCatching { client.close() }
        runCatching { serverSocket.close() }
        var qr: Map<String, Any?>? = mapOf(
            "clientId" to "qc1",
            "name" to "Mac",
            "macFp" to TlsV2Fixture.MAC_FP_HEX,
            "secret" to "0".repeat(32),
            "at" to System.currentTimeMillis(),
        )
        connect(pairDecisionTimeoutMs = 5_000, pendingQr = { qr },
            onQrConsumed = { qr = null })
        hello("qc1", "Mac")
        val served = readUntil("pair.qr")
        assertEquals(64, (served["m"] as String).length)
        assertEquals(null, qr)
        client.soTimeout = 400
        hello("qc1", "Mac")
        try {
            val frame = reader.readFrame()
            throw AssertionError("second hello answered again: $frame")
        } catch (expected: java.net.SocketTimeoutException) {
            // Nothing arrived: the one-time secret is gone.
        }
    }

    /**
     * A full K1 run is not alone on the machine: a local scanner can connect to
     * the test's port before this test's client does. That connection must not
     * become the session's peer — it used to be accepted as the Mac, and the
     * test then read its bytes as frames.
     */
    @Test
    fun aStrayLoopbackConnectionIsNotTheSessionPeer() {
        closeCurrent()
        connect(pairDecisionTimeoutMs = 30_000, strays = 2)
        addAndAuthenticate()
        send(mapOf("t" to "ping", "ts" to 12))
        assertEquals(12L, readUntil("pong")["ts"])
    }

    /**
     * PAIR-21: the phone serves one session at a time, and the next one is only
     * created after the previous teardown has finished. A full K1 run once lost
     * `taskContinueRelaunchesFreshWhenTheMoveIsRefused` because this helper did
     * not; the clipboard's owner-scoped listener (ISS-13) now covers the case
     * the helper cannot order.
     */
    @Test(timeout = 120_000)
    fun aReconnectStartsOnlyAfterThePreviousTeardownEnded() {
        // A listening session: its shutdown reaches the clipboard stop.
        addAndAuthenticate()
        val teardownStarted = CountDownLatch(1)
        val teardownMayEnd = CountDownLatch(1)
        platform.onClipStop = {
            teardownStarted.countDown()
            // Bounded: if the test fails before it releases this, the session
            // thread must still leave the teardown, or the whole K1 hangs on a
            // parked non-daemon thread.
            teardownMayEnd.await(10, TimeUnit.SECONDS)
        }
        session!!.close()
        assertTrue("the old session never started its teardown",
            teardownStarted.await(5, TimeUnit.SECONDS))

        val reconnected = CountDownLatch(1)
        val reconnect = Thread {
            connect(pairDecisionTimeoutMs = 30_000)
            reconnected.countDown()
        }
        reconnect.isDaemon = true
        reconnect.start()
        // The next session must not be created over the old teardown.
        assertFalse("a session was created while the previous teardown ran",
            reconnected.await(1, TimeUnit.SECONDS))

        teardownMayEnd.countDown()
        assertTrue("the reconnect never started after the teardown",
            reconnected.await(5, TimeUnit.SECONDS))
        reconnect.join(5_000)
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
        // ISS-40: `now` is the phone's CLOCK_MONOTONIC µs, VIDEO_FRAME's clock.
        val now = (pong["now"] as Number).toLong()
        assertTrue("pong has no positive now: $now", now > 0)
    }

    @Test
    fun streamStatsAreOffUntilAskedAndCarryTheCounters() {
        addAndAuthenticate()
        send(mapOf("t" to "window.open", "stream" to 7, "w" to 1000, "h" to 700,
                   "dpi" to 160, "pkg" to "com.android.settings"))
        readUntil("window.opened")
        Thread.sleep(300) // real-time: prove no tick sent stats in the first interval
        assertEquals("a default session sent stats", 0, statsBeforePong())

        send(mapOf("t" to "stream.stats", "on" to true))
        await { platform.statsSettings.lastOrNull() == true }
        val stats = readUntil("stream.stats")
        assertEquals(7L, stats["stream"])
        assertEquals(2_000L, stats["windowMs"])
        assertEquals(120L, stats["frames"])
        assertEquals(2L, stats["kf"])
        assertEquals(1L, stats["kfReq"])
        assertEquals(250_000L, stats["bytes"])
        assertEquals(8_000_000L, stats["targetBps"])
        assertEquals(12_000L, stats["encP50"])
        // The fake encoder has no encoding statistics: no QP keys at all.
        assertFalse(stats.containsKey("qpP50"))
        assertFalse(stats.containsKey("qpP95"))

        send(mapOf("t" to "stream.stats", "on" to false))
        await { platform.statsSettings.lastOrNull() == false }
        Thread.sleep(2_300) // real-time: span one 2 s stats interval
        assertEquals("stats still arrived after off", 0, statsBeforePong())
    }

    @Test
    fun aPausedWindowSendsNoStats() {
        addAndAuthenticate()
        send(mapOf("t" to "window.open", "stream" to 7, "w" to 1000, "h" to 700,
                   "dpi" to 160, "pkg" to "com.android.settings"))
        readUntil("window.opened")
        send(mapOf("t" to "stream.stats", "on" to true))
        readUntil("stream.stats")

        send(mapOf("t" to "window.pause", "stream" to 7))
        await { platform.pauses.contains(7) }
        Thread.sleep(2_300) // real-time: span one 2 s stats interval while paused
        assertEquals("a paused window sent stats", 0, statsBeforePong())

        send(mapOf("t" to "window.resume", "stream" to 7))
        await { platform.resumes.contains(7) }
        Thread.sleep(2_300) // real-time: span one 2 s stats interval after resume
        assertTrue("stats did not return after resume", statsBeforePong() >= 1)
    }

    @Test
    fun appsListAndIcon() {
        addAndAuthenticate()
        platform.apps = listOf(
            AppEntry("com.a", "Alpha", "com.a/.Main", multi = true),
            AppEntry("com.b", "Beta", "com.b/.Main", multi = false),
        )
        platform.iconResult = "AAAA"
        send(mapOf("t" to "apps.list"))
        val apps = readUntil("apps")["apps"] as List<*>
        assertEquals(2, apps.size)
        // WIN-24: the Mac's New Window items follow each app's own answer.
        assertEquals(true, (apps[0] as Map<*, *>)["multi"])
        assertEquals(false, (apps[1] as Map<*, *>)["multi"])
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
    fun iconRequestsForwardTheOptionalPx() {
        addAndAuthenticate()
        platform.iconResult = "AAAA"
        send(mapOf("t" to "apps.icon", "pkg" to "com.a"))
        readUntil("icon")
        send(mapOf("t" to "apps.icon", "pkg" to "com.a", "px" to 1296))
        readUntil("icon")
        assertEquals(listOf(null, 1296), platform.iconPngPx)
        assertEquals(listOf(null, 1296), platform.iconLayersPx)
    }

    @Test
    fun iconMessageCarriesTheAdaptiveLayersAsOptionalFields() {
        addAndAuthenticate()
        platform.apps = listOf(AppEntry("com.a", "Alpha", "com.a/.Main", multi = false))
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
    fun aResizeIsAnsweredWithTheRequestedValues() {
        addAndAuthenticate()
        send(mapOf("t" to "window.open", "stream" to 7, "w" to 1000, "h" to 700, "dpi" to 160, "pkg" to "com.android.settings"))
        readUntil("window.opened")
        send(mapOf("t" to "window.resize", "stream" to 7, "w" to 641, "h" to 479, "dpi" to 200))
        val ack = readUntil("window.resize.ack")
        // The echo is the request as the Mac sent it, not the display's floored
        // size: the Mac matches it against the resize it has in flight.
        assertEquals(7L, ack["stream"])
        assertEquals(641L, ack["w"])
        assertEquals(479L, ack["h"])
        assertEquals(200L, ack["dpi"])
        assertEquals("resized", ack["outcome"])
    }

    @Test
    fun aLinkWindowOpensAtTheMacsExactSize() {
        addAndAuthenticate()
        send(mapOf("t" to "link.open", "stream" to 9, "w" to 646, "h" to 486, "dpi" to 160, "url" to "https://example.com/a"))
        readUntil("window.opened")
        assertEquals(FakePlatform.OpenCall(9, 646, 486, 160, platform.opens.last().displayId), platform.opens.last())
    }

    @Test
    fun aResizeWithNoSizeIsRefusedButStillAnswered() {
        addAndAuthenticate()
        send(mapOf("t" to "window.open", "stream" to 7, "w" to 1000, "h" to 700, "dpi" to 160, "pkg" to "com.android.settings"))
        readUntil("window.opened")
        // An early return with no answer used to leave the Mac's request in
        // flight for good (docs/PROTOCOL.md `window.resize.ack`).
        send(mapOf("t" to "window.resize", "stream" to 7, "w" to 0, "h" to 479, "dpi" to 200))
        val ack = readUntil("window.resize.ack")
        assertEquals(7L, ack["stream"])
        assertEquals(0L, ack["w"])
        assertEquals("refused", ack["outcome"])
        assertTrue(platform.resizes.isEmpty())
    }

    @Test
    fun aResizeForAnUnknownStreamIsRefusedAndStillAnswered() {
        addAndAuthenticate()
        send(mapOf("t" to "window.resize", "stream" to 42, "w" to 640, "h" to 480, "dpi" to 160))
        assertEquals("no_stream", readUntil("error")["code"])
        val ack = readUntil("window.resize.ack")
        assertEquals(42L, ack["stream"])
        assertEquals(640L, ack["w"])
        assertEquals(160L, ack["dpi"])
        assertEquals("refused", ack["outcome"])
    }

    @Test
    fun windowLifecycleUsesTheMacsExactSizes() {
        // ISS-39: the Mac asks for the window's exact pixels at the encoder's
        // own alignment; the stream fits them to the codec. A 16 px floor here
        // made the phone's frame up to 15 px short of the window, which the
        // Mac then had to letterbox.
        addAndAuthenticate()
        send(mapOf("t" to "window.open", "stream" to 7, "w" to 1006, "h" to 698, "dpi" to 160, "pkg" to "com.android.settings"))
        val opened = readUntil("window.opened")
        assertEquals(1006L, opened["w"])
        assertEquals(698L, opened["h"])
        assertEquals(7L, opened["stream"])
        val open = platform.opens.first()
        assertEquals(7, open.stream)
        assertEquals(1006, open.w)
        assertEquals(698, open.h)
        assertEquals(160, open.dpi)
        assertTrue(platform.launches.any { it.displayId == open.displayId && it.pkg == "com.android.settings" })

        send(mapOf("t" to "window.resize", "stream" to 7, "w" to 3360, "h" to 2044, "dpi" to 200))
        await { platform.resizes.any { it == FakePlatform.ResizeCall(7, 3360, 2044, 200) } }

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
    fun hoverMapsToTheDisplayAndKeepsOnlyTheNewestMove() {
        addAndAuthenticate()
        send(mapOf("t" to "window.open", "stream" to 1, "w" to 640, "h" to 480, "dpi" to 160, "pkg" to "com.android.settings"))
        readUntil("window.opened")
        val displayId = platform.opens.first().displayId

        sendFrame(Frames.TYPE_HOVER, 1, Frames.encodeHover(HoverPayload(Frames.HOVER_ENTER, 0.5f, 0.5f)))
        // More moves than the injector can take one by one: stale ones are
        // dropped rather than queued, and none may land after the exit.
        for (i in 1..50) {
            sendFrame(Frames.TYPE_HOVER, 1,
                Frames.encodeHover(HoverPayload(Frames.HOVER_MOVE, i / 100f, 0.5f)))
        }
        await { platform.hovers.any { it.action == Frames.HOVER_MOVE } }
        sendFrame(Frames.TYPE_HOVER, 1, Frames.encodeHover(HoverPayload(Frames.HOVER_EXIT, 0.5f, 0.5f)))
        await { platform.hovers.any { it.action == Frames.HOVER_EXIT } }

        val enter = platform.hovers.first()
        assertEquals(Frames.HOVER_ENTER, enter.action)
        assertEquals(displayId, enter.displayId)
        assertEquals(0.5f, enter.nx, 0f)
        val exit = platform.hovers.last()
        assertEquals(Frames.HOVER_EXIT, exit.action)
        assertEquals(displayId, exit.displayId)
        assertTrue("no move was injected", platform.hovers.any { it.action == Frames.HOVER_MOVE })
        assertTrue("an exit landed before the end", platform.hovers.dropLast(1).none { it.action == Frames.HOVER_EXIT })
    }

    @Test
    fun unknownFrameTypeIsIgnoredAndTheSessionLives() {
        addAndAuthenticate()
        sendFrame(0x7e, 1, byteArrayOf(1, 2, 3))
        send(mapOf("t" to "ping", "ts" to 9))
        assertEquals(9, (readUntil("pong")["ts"] as Number).toInt())
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
        topTask = TopTask("com.a", "Alpha", taskId = 11)
        send(mapOf("t" to "window.open", "stream" to 1, "w" to 400, "h" to 800, "dpi" to 160, "mode" to "phone"))
        readUntil("window.opened")
        val first = readUntil("window.title")
        assertEquals("com.a", first["pkg"])
        assertEquals("Alpha", first["label"])
        topTask = TopTask("com.b", "Beta", taskId = 12)
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
    fun secureStateIsSentOnlyWhileTheMirrorIsOpen() {
        val secure = java.util.concurrent.atomic.AtomicBoolean(false)
        // setUp() opened the default connection; use a fresh session with a probe.
        tearDown()
        connect(pairDecisionTimeoutMs = 30_000, secureProbe = SecureProbe { secure.get() })
        addAndAuthenticate()
        // No phone window is open: the phone has not read display 0 yet.
        assertEquals(null, readUntil("state")["secure"])
        // The bouncer is up before the stream opens: the first poll reports it.
        secure.set(true)
        send(mapOf("t" to "window.open", "stream" to 1, "w" to 400, "h" to 800, "dpi" to 160, "mode" to "phone"))
        readUntil("window.opened")
        assertEquals(true, readUntil("state")["secure"])
        secure.set(false)
        assertEquals(false, readUntil("state")["secure"])
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
        // PATH-6: the session waits 30 s for a join, so the subscription lives
        // until the session itself ends (a person's close here).
        await { platform.stateSubscriberCount == 1 }
        session?.close()
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
        // The drop's own request says so: the duplicate-IDR gate must not
        // answer it with an IDR that went out before the dropped deltas.
        assertTrue(platform.keyframesAfterDrop.contains(1))
    }

    @Test
    fun handlerFailureAnswersInternalErrorAndTheSessionLives() {
        addAndAuthenticate()
        platform.openFails = true
        send(mapOf("t" to "window.open", "stream" to 11, "w" to 640, "h" to 480, "dpi" to 160, "pkg" to "com.android.settings"))
        val error = readUntil("error")
        assertEquals("internal", error["code"])
        assertEquals(11L, error["stream"])
        // The failure belonged to that message; the session keeps answering.
        send(mapOf("t" to "ping", "ts" to 7))
        assertEquals(7L, readUntil("pong")["ts"])
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
    fun aDefaultSessionOffersNoMediaField() {
        // PATH-25: the shipped default is TCP and a default session offers no
        // media field. A hello that offers udp still gets no capability back
        // in this merge: the UDP plane is planned (ISS-50), not implemented.
        platform.clients.add(PairedClient("c1", "MacBook", TlsV2Fixture.MAC_FP_HEX))
        hello("c1", "MacBook", media = true)
        val welcome = readUntil("welcome")
        assertFalse("no media field in this merge", welcome.containsKey("media"))
        assertTrue(welcome.containsKey("session"))
    }

    @Test
    fun appExitClosesWindowWithReason() {
        addAndAuthenticate()
        // The app's task is already there when the window opens, so the watch
        // loop cannot miss it between two polls.
        taskPresent = true
        send(mapOf("t" to "window.open", "stream" to 4, "w" to 640, "h" to 480, "dpi" to 160, "pkg" to "com.android.settings"))
        readUntil("window.opened")
        // Wait for the watch loop's first look, so hadTask is true before the
        // task goes away (a fixed sleep raced the poll on a slow host).
        await { taskChecks > 0 }
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
        val server = Server({ _, _, _ -> error("no sessions here") })
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
            val raw = readPathFrame(reader) ?: error("closed")
            val frame = if (raw.type == PathCodec.TYPE_RELIABLE) PathCodec.decodeReliable(raw).inner else raw
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

    /**
     * ISS-13: the slot is freed as soon as a drop happens, so the next session
     * can listen while the old one's teardown still runs. The old stop must not
     * silence the new session's listener.
     */
    @Test
    fun anOldSessionsLateClipboardStopDoesNotSilenceTheNewSession() {
        val oldStop = handOverWhileTheOldClipboardStopRuns()
        oldStop.release.countDown()
        await { platform.clipStopsDone.get() == 1 }
        assertEquals("the old session's stop was not stale", 1, platform.staleClipStops.get())

        platform.changeClip("after the hand-over")

        assertEquals("after the hand-over", readUntil("clip.set")["text"])
    }

    /** ISS-13: the session that installed the listener still stops it. */
    @Test
    fun theNewSessionsOwnStopEndsTheClipboardSync() {
        val oldStop = handOverWhileTheOldClipboardStopRuns()
        oldStop.release.countDown()
        await { platform.clipStopsDone.get() == 1 }
        assertTrue("the old stop silenced the new session's listener", platform.clipListening)

        session!!.close()
        await { platform.clipStopsDone.get() == 2 }

        assertFalse("the new session's own stop did not end delivery", platform.clipListening)
        assertEquals("the new session's own stop was stale", 1, platform.staleClipStops.get())
    }

    /** A stands listening; its teardown parks in `stop`; B connects and listens. */
    private fun handOverWhileTheOldClipboardStopRuns(): OldClipboardStop {
        addAndAuthenticate()
        val entered = CountDownLatch(1)
        val release = CountDownLatch(1)
        platform.onClipStop = {
            entered.countDown()
            release.await(5, TimeUnit.SECONDS)
        }
        // The drop path: the old session is cut at once, its teardown still runs.
        session!!.close()
        assertTrue("the old session never reached its clipboard stop",
            entered.await(5, TimeUnit.SECONDS))
        closeCurrent()
        connect(pairDecisionTimeoutMs = 30_000, waitForPrevious = false)
        addAndAuthenticateCommon()
        await { platform.clipListenCalls.get() == 2 }
        return OldClipboardStop(release)
    }

    private class OldClipboardStop(val release: CountDownLatch)

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

    /**
     * `clip.enable` is the Mac's own switch, over the wire (SHARE share Q2): off
     * stops the phone's sends and its applies at once, on starts them again.
     */
    @Test
    fun thePhoneStopsSendingAfterTheMacTurnsTheGateOff() {
        addAndAuthenticate()
        send(mapOf("t" to "clip.enable", "on" to false))
        // Messages are handled in order, so the pong proves the gate was applied.
        send(mapOf("t" to "ping", "ts" to 91))
        assertEquals("pong", readUntil("pong")["t"])

        platform.changeClip("after the gate went off")
        send(mapOf("t" to "ping", "ts" to 92))
        // Nothing may precede the pong: a clip.set here is the gate failing.
        assertEquals("pong", readJson()["t"])

        send(mapOf("t" to "clip.enable", "on" to true))
        send(mapOf("t" to "ping", "ts" to 93))
        assertEquals("pong", readUntil("pong")["t"])
        platform.changeClip("after the gate came back")
        assertEquals("after the gate came back", readUntil("clip.set")["text"])
    }

    /** While the gate is off the phone also applies nothing the Mac sends. */
    @Test
    fun aClipFromTheMacIsNotAppliedWhileTheGateIsOff() {
        addAndAuthenticate()
        send(mapOf("t" to "clip.enable", "on" to false))
        send(mapOf("t" to "ping", "ts" to 94))
        assertEquals("pong", readUntil("pong")["t"])

        send(mapOf("t" to "clip.set", "text" to "must not land"))
        send(mapOf("t" to "ping", "ts" to 95))
        assertEquals("pong", readUntil("pong")["t"])

        assertEquals(emptyList<String>(), platform.clipWrites.toList())
    }

    /**
     * A password manager's clip is flagged by Android itself; the phone must not
     * send it (SHARE share Q3), and the flag never reaches a log.
     */
    @Test
    fun aSensitiveClipIsNeverSent() {
        addAndAuthenticate()
        platform.changeClip("hunter2-secret", sensitive = true)
        platform.changeClip("ordinary")
        assertEquals("ordinary", readUntil("clip.set")["text"])
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
        send(mapOf("t" to "task.continue", "stream" to 4, "w" to 906, "h" to 606, "dpi" to 160))
        val opened = readUntil("window.opened")
        // The handoff's display is the Mac's exact size (ISS-39), not floored to 16.
        assertEquals(906, platform.opens.first().w)
        assertEquals(606, platform.opens.first().h)
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
        // The window's subject follows the top task on its display, like every window.
        topTask = TopTask("com.example.reader", "Reader", taskId = 40)
        val title = readUntil("window.title")
        assertEquals(8L, title["stream"])
        assertEquals("an app stream names its task, with the app's label as the fallback", "Reader", title["title"])
    }

    // ---- task.front --------------------------------------------------------

    @Test
    fun taskFrontReportsTheForegroundPackageWithoutOpeningAnything() {
        val mover = FakeTaskMove(
            listOf(
                SystemTask(21, "com.android.systemui", null, 0, false, true),
                SystemTask(30, "com.example.reader", "com.example.reader.Reader", 0, false, false),
            ),
        )
        reconnectWith(mover)
        send(mapOf("t" to "task.front", "seq" to 7))
        val reply = readUntil("task.front")
        assertEquals(7L, reply["seq"])
        assertEquals("com.example.reader", reply["pkg"])
        // A read: no display, no move, no HOME key, no stream.
        assertTrue(platform.opens.isEmpty())
        assertTrue(mover.moves.isEmpty())
        assertTrue(platform.keys.isEmpty())
    }

    @Test
    fun taskFrontAnswersNullWhenNothingIsContinuable() {
        val mover = FakeTaskMove(
            listOf(
                SystemTask(21, "com.android.systemui", null, 0, false, true),
                SystemTask(22, Session.OWN_PACKAGE, null, 0, false, false),
                SystemTask(23, "com.android.launcher3", null, 0, true, false),
            ),
        )
        reconnectWith(mover)
        send(mapOf("t" to "task.front", "seq" to 9))
        val reply = readUntil("task.front")
        assertEquals(9L, reply["seq"])
        assertTrue(reply.containsKey("pkg"))
        assertEquals(null, reply["pkg"])
        assertTrue(platform.keys.isEmpty())
    }

    @Test
    fun taskFrontWithoutTheSeamAnswersNotAvailable() {
        reconnectWith(null)
        send(mapOf("t" to "task.front", "seq" to 3))
        val error = readUntil("error")
        assertEquals("not_available", error["code"])
    }

    // ------------------------------------------------------------------
    // connection gates
    // ------------------------------------------------------------------

    @Test
    fun connectionsOffRefusesAnUnknownMacAtHello() {
        closeCurrent()
        connect(pairDecisionTimeoutMs = 30_000, gates = { GateSettings(false, true) })
        hello("unknown", "Mac")
        val error = readUntil("error")
        assertEquals("connections_off", error["code"])
    }

    @Test
    fun connectionsOffRefusesAPairedMacToo() {
        closeCurrent()
        connect(pairDecisionTimeoutMs = 30_000, gates = { GateSettings(false, true) })
        platform.clients.add(PairedClient("c1", "MacBook", TlsV2Fixture.MAC_FP_HEX))
        hello("c1", "MacBook")
        val error = readUntil("error")
        assertEquals("connections_off", error["code"])
    }

    @Test
    fun missingGateSettingsFailClosed() {
        closeCurrent()
        connect(pairDecisionTimeoutMs = 30_000, gates = { null })
        hello("c1", "MacBook")
        assertEquals("connections_off", readUntil("error")["code"])
    }

    @Test
    fun pairingsOffRefusesAnUnknownMacBeforeAnyCode() {
        closeCurrent()
        connect(pairDecisionTimeoutMs = 30_000, gates = { GateSettings(true, false) })
        hello("unknown", "Mac", pairing = true)
        // The refusal is the first frame: no pair.commit (the code) ever went out.
        val first = readJson()
        assertEquals("error", first["t"])
        assertEquals("pairing_off", first["code"])
    }

    /**
     * PAIR-23 (bug 2): a Mac that still holds this phone's pin but was forgotten
     * here is told at once. Left in the pairing phase it waits for a
     * `pair.request` that a Mac which believes it is paired never sends, and
     * its 15 s handshake timeout is the only thing that ever ends it.
     */
    @Test
    fun anUnpinnedHelloIsAnsweredNotPairedAtOnce() {
        closeCurrent()
        connect(pairDecisionTimeoutMs = 30_000)
        client.soTimeout = 1_000
        val started = System.currentTimeMillis()
        hello("forgotten", "Mac")
        val error = readUntil("error")
        val elapsedMs = System.currentTimeMillis() - started
        assertEquals("not_paired", error["code"])
        assertTrue("the answer took ${elapsedMs}ms", elapsedMs < 1_000)
    }

    /**
     * PAIR-23 with "Allow new pairings" off: PAIR-12 stands — a peer the phone
     * pins nothing for is closed at once without a reply, not left hanging
     * until the handshake timeout.
     */
    @Test
    fun aForgottenMacIsClosedAtOnceWithPairingsOff() {
        closeCurrent()
        connect(pairDecisionTimeoutMs = 30_000, gates = { GateSettings(true, false) })
        client.soTimeout = 1_500
        val started = System.currentTimeMillis()
        hello("forgotten", "Mac")
        val outcome = runCatching { client.getInputStream().read() }
        val elapsedMs = System.currentTimeMillis() - started
        assertTrue(
            "a forgotten Mac was still waiting after ${elapsedMs}ms: $outcome",
            outcome.isSuccess,
        )
        assertEquals("a forgotten Mac got a reply", -1, outcome.getOrNull())
        assertTrue("the close took ${elapsedMs}ms", elapsedMs < 1_000)
    }

    @Test
    fun pairingsOffStillAcceptsAPairedMac() {
        closeCurrent()
        connect(pairDecisionTimeoutMs = 30_000, gates = { GateSettings(true, false) })
        platform.clients.add(PairedClient("c1", "MacBook", TlsV2Fixture.MAC_FP_HEX))
        authenticate("c1")
    }

    @Test
    fun masterSwitchOffDropsTheLiveSession() {
        closeCurrent()
        val gates = AtomicReference(GateSettings(true, true))
        connect(pairDecisionTimeoutMs = 30_000, gates = { gates.get() })
        platform.clients.add(PairedClient("c1", "MacBook", TlsV2Fixture.MAC_FP_HEX))
        authenticate("c1")
        gates.set(GateSettings(false, true))
        session!!.applyGates()
        assertEquals("connections_off", readUntil("error")["code"])
        // The writer drains the error before the socket closes (a clean EOF,
        // never a reset that could eat the frame).
        val eof = runCatching { client.getInputStream().read() }.getOrNull()
        assertTrue(eof == null || eof == -1)
    }

    @Test
    fun pairingsOffDropsAnOpenPairingPrompt() {
        closeCurrent()
        val gates = AtomicReference(GateSettings(true, true))
        connect(pairDecisionTimeoutMs = 30_000, gates = { gates.get() })
        hello("unknown", "Mac", pairing = true)
        send(mapOf("t" to "pair.request"))
        readUntil("pair.commit")
        gates.set(GateSettings(true, false))
        session!!.applyGates()
        assertEquals("pairing_off", readUntil("error")["code"])
    }

    /**
     * R-1: the hub has already acked a reliable frame by the time it reaches
     * the session's inbound queue. A handler that blocks (a 2 s window.open, a
     * slow drop write) must push back on the reader; a full queue must never
     * lose a frame the Mac has been told was received.
     */
    @Test
    fun everyAckedReliableFrameIsDeliveredWhileTheHandlerBlocks() {
        addAndAuthenticate()
        val entered = CountDownLatch(1)
        val release = CountDownLatch(1)
        platform.onOpen = {
            entered.countDown()
            release.await(5, TimeUnit.SECONDS)
        }
        send(mapOf("t" to "window.open", "stream" to 7, "w" to 640, "h" to 480, "dpi" to 160, "pkg" to "com.android.settings"))
        assertTrue("the handler never started", entered.await(2, TimeUnit.SECONDS))
        repeat(300) { i -> send(mapOf("t" to "ping", "ts" to i)) }
        release.countDown()
        val seen = mutableListOf<Long>()
        val deadline = System.currentTimeMillis() + 10_000
        while (seen.size < 300 && System.currentTimeMillis() < deadline) {
            val message = readJson()
            if (message["t"] == "pong") seen.add((message["ts"] as Number).toLong())
        }
        assertEquals((0L until 300L).toList(), seen)
    }

    /**
     * RR-8: the phone acked every frame its reader handled, so the Mac's ACKs,
     * pings and lossy input each earned a redundant one back (pure airtime and
     * wake-ups). Only a delivered RELIABLE frame advances our ACK.
     */
    @Test
    fun onlyDeliveredReliableFramesEarnAnAck() {
        addAndAuthenticate()
        // Drain what the session already queued: the ACK for clip.enable is fine.
        framesFor(200)
        // Past the 10 ms coalescing window: a handled frame acks at once.
        clock += 1_000
        repeat(3) { i ->
            client.getOutputStream().write(
                Frames.encodeJson(
                    0,
                    Json.encode(mapOf("t" to "path.ping", "path" to "a1b2c3d4", "ts" to i)),
                ),
            )
        }
        client.getOutputStream().flush()
        val types = framesFor(500)
        assertTrue("the phone did not answer the three pings: $types", types.count { it == Frames.TYPE_JSON } >= 3)
        assertTrue("a bare ping earned an ACK: $types", types.none { it == PathCodec.TYPE_ACK })

        // A delivered RELIABLE frame still earns one.
        send(mapOf("t" to "ping", "ts" to 99))
        assertTrue(
            "a reliable frame earned no ACK",
            framesFor(1_000).contains(PathCodec.TYPE_ACK),
        )
    }

    /**
     * RR-10: the frames held ahead of a same-path gap were bounded by a count
     * (64 frames, up to 64 x 8 MiB). PATH-15 promises one window: the held
     * deque is bounded by bytes now, and a peer past that ends the session.
     */
    @Test
    fun theHeldReorderFramesAreBoundedByBytes() {
        platform.clients.add(PairedClient("c1", "MacBook", TlsV2Fixture.MAC_FP_HEX))
        authenticate("c1")
        // 2..65 fill the 64-frame window; 66.. are ahead of the same path's gap.
        for (seq in 2L..65L) sendJsonAt(seq, mapOf("t" to "ping", "ts" to seq))
        // The bound trips inside these writes (4 MiB); a write after the session
        // closed is expected evidence, not a failure.
        var sentPads = 0
        for (seq in 66L..72L) {
            if (runCatching { sendJsonAtWithPad(seq, 1024 * 1024) }.isFailure) break
            sentPads++
        }
        assertTrue("the session ended before the held window passed its bytes: $sentPads", sentPads >= 3)
        var closed = false
        val deadline = System.currentTimeMillis() + 10_000
        while (System.currentTimeMillis() < deadline) {
            try {
                if (reader.readFrame() == null) {
                    closed = true
                    break
                }
            } catch (e: java.net.SocketTimeoutException) {
                break
            }
        }
        assertTrue("the session stayed open with more than one window held", closed)
    }

    private fun sendJsonAtWithPad(seq: Long, pad: Int) {
        val bytes = Frames.encodeJson(
            0,
            Json.encode(mapOf("t" to "ping", "ts" to seq, "pad" to "x".repeat(pad))),
        )
        val out = client.getOutputStream()
        out.write(PathCodec.encodeReliable(seq, frameOf(bytes)))
        out.flush()
    }

    /** Every frame type the session puts out within [ms]; stops at the timeout. */
    private fun framesFor(ms: Int): List<Int> {
        val types = mutableListOf<Int>()
        client.soTimeout = ms.toInt()
        try {
            while (true) {
                val frame = reader.readFrame() ?: break
                types.add(frame.type)
            }
        } catch (_: java.net.SocketTimeoutException) {
        } finally {
            client.soTimeout = 5_000
        }
        return types
    }

    /**
     * R-11: a full reorder window whose missing seq is earlier in the same
     * path's stream must not pause that reader: the gap could never arrive.
     */
    @Test
    fun aFullReorderWindowOnOnePathNeverDeadlocks() {
        platform.clients.add(PairedClient("c1", "MacBook", TlsV2Fixture.MAC_FP_HEX))
        authenticate("c1")
        // 2..65 fill the 64-frame window; 66 is the frame that does not fit.
        for (seq in 2L..66L) sendJsonAt(seq, mapOf("t" to "ping", "ts" to seq))
        sendJsonAt(1L, mapOf("t" to "ping", "ts" to 1L))
        sendJsonAt(67L, mapOf("t" to "ping", "ts" to 67L))
        val seen = mutableListOf<Long>()
        val deadline = System.currentTimeMillis() + 10_000
        while (seen.size < 67 && System.currentTimeMillis() < deadline) {
            val message = readJson()
            if (message["t"] == "pong") seen.add((message["ts"] as Number).toLong())
        }
        assertEquals((1L..67L).toList(), seen)
    }

    /** R-16: the RELIABLE wrapper's stream is routing only; a mismatch is a
     * protocol error that ends the session, not one path. */
    @Test
    fun aReliableFrameWithAMismatchedOuterStreamEndsTheSession() {
        platform.clients.add(PairedClient("c1", "MacBook", TlsV2Fixture.MAC_FP_HEX))
        authenticate("c1")
        val inner = Frame(Frames.TYPE_JSON, 0, Json.encode(mapOf("t" to "ping", "ts" to 1)).toByteArray())
        val wrapped = PathCodec.encodeReliable(1, inner)
        client.getOutputStream().write(Frames.encode(PathCodec.TYPE_RELIABLE, 9, wrapped.copyOfRange(9, wrapped.size)))
        client.getOutputStream().flush()
        var closed = false
        val deadline = System.currentTimeMillis() + 5_000
        while (System.currentTimeMillis() < deadline) {
            try {
                if (reader.readFrame() == null) {
                    closed = true
                    break
                }
            } catch (e: java.net.SocketTimeoutException) {
                break
            }
        }
        assertTrue("the session stayed open after the protocol error", closed)
    }

    private fun closeCurrent() {
        runCatching { client.close() }
        runCatching { serverSocket.close() }
    }

    /** Tears down the current session, reconnects with [taskMove]. */
    @Suppress("SameParameterValue")
    private fun reconnectWith(taskMove: TaskMove?) {
        closeCurrent()
        connect(pairDecisionTimeoutMs = 30_000, taskMove = taskMove)
        addAndAuthenticate()
    }

    private companion object {
        const val CLIP_MAX_BYTES = 1_048_576

        /** PAIR-21's bound on a hand-over wait for the old teardown. */
        const val TEARDOWN_WAIT_MS = 5_000L
    }
}
