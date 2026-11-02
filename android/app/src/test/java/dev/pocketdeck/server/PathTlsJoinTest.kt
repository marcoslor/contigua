package dev.pocketdeck.server

import dev.pocketdeck.proto.FrameReader
import dev.pocketdeck.proto.Frames
import dev.pocketdeck.proto.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.Closeable
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.util.Collections

/**
 * The real shell server's TLS join (direct-p1 item 7 round 2): the emulator
 * logged `tls handshake failed: Unable to parse TLS packet header` on the join
 * paths, which the fake phone can never show. Here [Server] itself accepts real
 * TLS 1.3 on loopback with the test identities, and the same pair of hellos is
 * driven once directly and once through a byte relay that only copies bytes,
 * the way `tools/pdpathfault/pdpathfault.py` does.
 */
class PathTlsJoinTest {

    private fun readJson(reader: FrameReader): Map<String, Any?> {
        val frame = readPathFrame(reader) ?: error("connection closed")
        return pathJson(frame)
    }

    /** Reads frames until one carries [key], which is what the path layer added. */
    private fun gatherUntil(reader: FrameReader, key: String, value: Any?): Map<String, Any?> {
        while (true) {
            val message = readJson(reader)
            if (message[key] == value) return message
        }
    }

    /** Reads for [ms]; true if a bare `path.ping` arrived (D-1: none on one path). */
    private fun sawPathPing(reader: FrameReader, socket: Socket, ms: Int): Boolean {
        val previous = socket.soTimeout
        socket.soTimeout = ms
        return try {
            var seen = false
            while (true) {
                val frame = reader.readFrame() ?: break
                if (frame.type != Frames.TYPE_JSON) continue
                val obj = runCatching { Json.parseObject(String(frame.payload)) }.getOrNull()
                if (obj?.get("t") == "path.ping") {
                    seen = true
                    break
                }
            }
            seen
        } catch (e: java.net.SocketTimeoutException) {
            false
        } finally {
            socket.soTimeout = previous
        }
    }

    private fun hello(path: String, join: String? = null, pairing: Boolean = false): ByteArray {
        val fields = mutableMapOf<String, Any?>(
            "t" to "hello", "v" to 4, "path" to path,
            "clientId" to "c1", "name" to "MacBook",
        )
        if (join != null) fields["join"] = join
        if (pairing) fields["pair"] = true
        return Frames.encodeJson(0, Json.encode(fields))
    }

    private fun json(fields: Map<String, Any?>): ByteArray =
        Frames.encodeJson(0, Json.encode(fields))

    @Test
    fun aPairedHelloGetsWelcomeSession() {
        harness().use { phone ->
            phone.client().use { first ->
                val reader = FrameReader(first.getInputStream())
                first.getOutputStream().write(hello("a1b2c3d4"))
                first.getOutputStream().flush()
                val welcome = readJson(reader)
                assertEquals("welcome", welcome["t"])
                val session = welcome["session"] as String
                assertEquals(32, session.length)
                assertTrue("session id is not hex: $session", session.all { it in "0123456789abcdef" })
                // The first path is live: the phone answers on it.
                first.getOutputStream().write(Frames.encodeJson(0, Json.encode(mapOf("t" to "ping", "ts" to 11))))
                first.getOutputStream().flush()
                assertEquals(11L, gatherUntil(reader, "ts", 11L)["ts"])
            }
        }
    }

    @Test
    fun thePhoneAnswersTheMacsPathPingRightAfterWelcome() {
        harness().use { phone ->
            phone.client().use { first ->
                val reader = FrameReader(first.getInputStream())
                first.getOutputStream().write(hello("a1b2c3d4"))
                first.getOutputStream().flush()
                val welcome = readJson(reader)
                assertEquals("welcome", welcome["t"])
                first.getOutputStream().write(
                    Frames.encodeJson(0, Json.encode(mapOf(
                        "t" to "path.ping", "path" to "a1b2c3d4", "ts" to 7,
                    ))),
                )
                first.getOutputStream().flush()
                val pong = gatherUntil(reader, "t", "path.pong")
                assertEquals("a1b2c3d4", pong["path"])
                assertEquals(7L, pong["ts"])
            }
        }
    }

    /** D-1/PATH-21: one path is never pinged, so no lost pong can fail it; the
     * session stays live on TCP keepalive plus the 15 s app keepalive. */
    @Test
    fun oneLostPongOnTheOnlyPathDoesNotReconnect() {
        val clock = { System.nanoTime() / 1_000_000 }
        harness(clock = clock).use { phone ->
            phone.client().use { socket ->
                socket.soTimeout = 10_000
                val reader = FrameReader(socket.getInputStream())
                val out = socket.getOutputStream()
                out.write(hello("a1b2c3d4"))
                out.flush()
                val welcome = readJson(reader)
                assertEquals("welcome", welcome["t"])
                // D-1: no path.ping at all on a single path.
                assertFalse(
                    "a one-path session was pinged: ${phone.logs}",
                    sawPathPing(reader, socket, ms = 2_400),
                )
                assertFalse(
                    "one lost pong failed the only path: ${phone.logs}",
                    phone.logs.any { it == "paths: reconnecting" },
                )
                // Still live: the session answers an app ping.
                out.write(json(mapOf("t" to "ping", "ts" to 31)))
                out.flush()
                assertEquals(31L, gatherUntil(reader, "ts", 31L)["ts"])
            }
        }
    }

    /** R-14/AGENTS: every session-machine transition is one `<from> --event--> <to>`
     * line with closed tokens. */
    @Test
    fun theSessionMachineLogsEachTransition() {
        harness().use { phone ->
            phone.client().use { first ->
                val reader = FrameReader(first.getInputStream())
                first.getOutputStream().write(hello("a1b2c3d4"))
                first.getOutputStream().flush()
                assertEquals("welcome", readJson(reader)["t"])
                first.close()
                val deadline = System.currentTimeMillis() + 3_000
                while (System.currentTimeMillis() < deadline &&
                    phone.logs.none { it.startsWith("paths: live a1b2c3d4 --") }
                ) {
                    Thread.sleep(20) // real-time: the transition runs on the session's reader thread
                }
                assertTrue(
                    "no transition line: ${phone.logs}",
                    phone.logs.contains("paths: live a1b2c3d4 --down--> orphaned"),
                )
            }
        }
    }

    @Test
    fun aJoinOverASecondTlsConnectionAttachesWithoutSuperseding() {
        harness().use { phone ->
            phone.client().use { first ->
                val firstReader = FrameReader(first.getInputStream())
                first.getOutputStream().write(hello("a1b2c3d4"))
                first.getOutputStream().flush()
                val welcome = readJson(firstReader)
                assertEquals("welcome", welcome["t"])
                val session = welcome["session"] as String
                assertEquals(32, session.length)

                phone.client().use { second ->
                    val secondReader = FrameReader(second.getInputStream())
                    second.getOutputStream().write(hello("b2c3d4e5", join = session))
                    second.getOutputStream().flush()
                    val joined = readJson(secondReader)
                    assertEquals("welcome", joined["t"])
                    assertEquals(session, joined["session"])

                    // The first path is still the same session's: the join did
                    // not supersede it (PATH-3).
                    first.getOutputStream().write(Frames.encodeJson(0, Json.encode(mapOf("t" to "ping", "ts" to 12))))
                    first.getOutputStream().flush()
                    assertEquals(12L, gatherUntil(firstReader, "ts", 12L)["ts"])

                    // The phone's path machine logged the attach, not an end.
                    assertTrue(
                        "no join line: ${phone.logs}",
                        phone.logs.any { it == "paths: joined b2c3d4e5 (paths 2)" },
                    )
                    assertFalse(
                        "the join superseded the live session: ${phone.logs}",
                        phone.logs.any { it.contains("superseded") },
                    )
                }
                assertEquals(
                    "the second TLS connection founded a second session",
                    1, phone.platform.sessionChanges.count { it.connected },
                )
            }
        }
    }

    @Test
    fun aPairedHelloAndAJoinAcrossAByteRelayGetOneSession() {
        harness().use { phone ->
            ByteRelay(phone.port).use { relay ->
                phone.client(relay.port).use { first ->
                    val firstReader = FrameReader(first.getInputStream())
                    first.getOutputStream().write(hello("a1b2c3d4"))
                    first.getOutputStream().flush()
                    val welcome = readJson(firstReader)
                    assertEquals("welcome", welcome["t"])
                    val session = welcome["session"] as String

                    phone.client(relay.port).use { second ->
                        val secondReader = FrameReader(second.getInputStream())
                        second.getOutputStream().write(hello("b2c3d4e5", join = session))
                        second.getOutputStream().flush()
                        val joined = readJson(secondReader)
                        assertEquals("welcome", joined["t"])
                        assertEquals(session, joined["session"])

                        first.getOutputStream().write(
                            Frames.encodeJson(0, Json.encode(mapOf("t" to "ping", "ts" to 13))),
                        )
                        first.getOutputStream().flush()
                        assertEquals(13L, gatherUntil(firstReader, "ts", 13L)["ts"])
                        assertTrue(
                            "no join line through the relay: ${phone.logs}",
                            phone.logs.any { it == "paths: joined b2c3d4e5 (paths 2)" },
                        )
                    }
                }
                assertEquals(
                    "the relay produced a second session",
                    1, phone.platform.sessionChanges.count { it.connected },
                )
            }
        }
    }

    /**
     * The emulator's `tls handshake failed: Unable to parse TLS packet header`
     * is what [Server] logs for *any* connection whose first bytes are not a
     * TLS record (Conscrypt's wording on Android; the JVM provider names it
     * differently). It is a per-connection line, not a broken TLS stack: the
     * same listener must still serve the TLS pair and the join right after it.
     */
    @Test
    fun aNonTlsProbeLogsAHandshakeFailureAndTheNextPairAndJoinStillWork() {
        harness().use { phone ->
            Socket("127.0.0.1", phone.port).use { probe ->
                probe.getOutputStream().write("GET / HTTP/1.0\r\n\r\n".toByteArray())
                probe.getOutputStream().flush()
                probe.soTimeout = 3_000
                runCatching { probe.getInputStream().read() }
            }
            val deadline = System.nanoTime() + 3_000_000_000L
            while (System.nanoTime() < deadline &&
                !phone.logs.any { it.startsWith("tls handshake failed") }
            ) {
                Thread.sleep(20) // real-time: polls the real server's line
            }
            assertTrue(
                "a non-TLS byte on the listener left no handshake line: ${phone.logs}",
                phone.logs.any { it.startsWith("tls handshake failed") },
            )

            phone.client().use { first ->
                val firstReader = FrameReader(first.getInputStream())
                first.getOutputStream().write(hello("a1b2c3d4"))
                first.getOutputStream().flush()
                val welcome = readJson(firstReader)
                assertEquals("welcome", welcome["t"])
                val session = welcome["session"] as String

                phone.client().use { second ->
                    val secondReader = FrameReader(second.getInputStream())
                    second.getOutputStream().write(hello("b2c3d4e5", join = session))
                    second.getOutputStream().flush()
                    val joined = readJson(secondReader)
                    assertEquals("welcome", joined["t"])
                    assertEquals(session, joined["session"])
                }
            }
        }
    }

    /**
     * The emulator's boot-4 sequence: a person reads the code for a few seconds
     * (the reader polls the TLS socket at 250 ms the whole time) and only then
     * taps Allow, which completes the pairing from another thread. The phone
     * must put `pair.ok` and `welcome` on the wire and keep the session live.
     */
    @Test
    fun anInteractiveApprovalOverTlsPairsAndWelcomes() = interactiveApproval()

    /**
     * Boot 5's shape, with the server on Conscrypt's FD socket — the socket
     * Android uses by default. SunJSSE tolerates a second thread writing while
     * the reader polls; Android's provider throws, which is the boot-5 fault.
     */
    @Test
    fun anInteractiveApprovalOnTheConscryptFdSocketPairsAndWelcomes() =
        interactiveApproval(ServerTls(org.conscrypt.Conscrypt.newProvider(), useEngineSocket = false))

    /** The same sequence on Conscrypt's engine socket. */
    @Test
    fun anInteractiveApprovalOnTheConscryptEngineSocketPairsAndWelcomes() =
        interactiveApproval(ServerTls(org.conscrypt.Conscrypt.newProvider(), useEngineSocket = true))

    private data class ServerTls(val provider: java.security.Provider, val useEngineSocket: Boolean) {
        val label: String get() = if (useEngineSocket) "Conscrypt engine socket" else "Conscrypt FD socket"
    }

    private fun interactiveApproval(tls: ServerTls? = null) {
        harness(clients = emptyList(), serverTls = tls).use { phone ->
            try {
                phone.client().use { socket ->
                    socket.soTimeout = 10_000
                    val reader = FrameReader(socket.getInputStream())
                    val out = socket.getOutputStream()
                    out.write(hello("a1b2c3d4", pairing = true))
                    out.flush()
                    out.write(json(mapOf("t" to "pair.request")))
                    out.flush()
                    val commit = readJson(reader)
                    assertEquals("pair.commit", commit["t"])
                    out.write(json(mapOf("t" to "pair.nonce", "n" to "3fb962da6c0eaaee44a7a16a2bcf9c97")))
                    out.flush()
                    val reveal = readJson(reader)
                    assertEquals("pair.reveal", reveal["t"])

                    val deadline = System.nanoTime() + 3_000_000_000L
                    while (System.nanoTime() < deadline && phone.platform.pairRequests.isEmpty()) {
                        Thread.sleep(20) // real-time: polls the real server's state
                    }
                    val request = phone.platform.pairRequests.firstOrNull()
                        ?: error("the phone never asked its person: ${phone.logs}")
                    // Longer than the 250 ms pairing poll: the reader timed out and
                    // resumed many times before the decision, as boot 4 did.
                    Thread.sleep(1_500) // real-time: a real reader timeout on the pairing poll
                    phone.server.respondPairing(request.requestId, true)

                    val ok = readJson(reader)
                    assertEquals("pair.ok", ok["t"])
                    assertEquals(TlsV2Fixture.MAC_FP_HEX, ok["macFP"])
                    val welcome = readJson(reader)
                    assertEquals("welcome", welcome["t"])
                    assertEquals(32, (welcome["session"] as String).length)

                    // The session is READY on the same socket: a bare ping is served.
                    out.write(json(mapOf("t" to "ping", "ts" to 21)))
                    out.flush()
                    assertEquals(21L, gatherUntil(reader, "ts", 21L)["ts"])
                    assertTrue(
                        "no welcome line: ${phone.logs}",
                        phone.logs.any { it.contains(": welcome (protocol 4)") },
                    )
                }
            } catch (e: Throwable) {
                // The exception behind boot 5 is the deliverable when this fails.
                throw AssertionError(
                    "interactive approval on ${tls?.label ?: "SunJSSE"} failed: ${e.message}; " +
                        "phone log: ${phone.logs}",
                    e,
                )
            }
        }
    }

    /** One real [Server] with TLS on loopback and a paired Mac. */
    private fun harness(
        clients: List<PairedClient> = listOf(PairedClient("c1", "MacBook", TlsV2Fixture.MAC_FP_HEX)),
        serverTls: ServerTls? = null,
        clock: () -> Long = { 1_000 },
    ): Harness {
        val platform = FakePlatform()
        platform.clients.addAll(clients)
        val phoneIdentity = TestTls.generate("PocketDeck Phone (join paranoia)")
        val macIdentity = TestTls.generate("PocketDeck Mac (join paranoia)")
        val logs = Collections.synchronizedList(mutableListOf<String>())
        val server = Server(
            { socket, plain, hello -> sessionFor(platform, socket, plain, hello, logs, clock) },
            log = { logs.add(it) },
            { phoneIdentity.certPem }, { phoneIdentity.keyP8 }, { GateSettings(true, true) },
            { listOf(fingerprintHex(macIdentity)) },
            tlsContextBuilder = serverTls?.let { tls ->
                { _, _ -> TestTls.serverContext(phoneIdentity, tls.provider, tls.useEngineSocket) }
            },
        )
        return Harness(server.start(), macIdentity, phoneIdentity, platform, logs, server)
    }

    private class Harness(
        val port: Int,
        private val macIdentity: TestTls.Identity,
        private val phoneIdentity: TestTls.Identity,
        val platform: FakePlatform,
        val logs: MutableList<String>,
        val server: Server,
    ) : Closeable {
        fun client(port: Int = this.port): Socket =
            TestTls.clientSocket(macIdentity, phoneIdentity.certPem, "127.0.0.1", port)

        override fun close() = server.stop()
    }

    private fun sessionFor(
        platform: FakePlatform,
        socket: Socket,
        plain: Socket,
        hello: Map<String, Any?>?,
        logs: MutableList<String>,
        clock: () -> Long = { 1_000 },
    ): Session = Session(
        socket = socket,
        plainSocket = plain,
        display = platform,
        catalog = platform,
        launcher = platform,
        injector = platform,
        power = platform,
        device = platform,
        store = platform,
        callback = platform,
        now = clock,
        log = { logs.add(it) },
        handshakeTimeoutMs = 3_000,
        tlsView = TlsV2Fixture.view,
        gateProvider = { GateSettings(true, true) },
        preReadHello = hello,
    )

    private fun fingerprintHex(identity: TestTls.Identity): String = dev.pocketdeck.e2ee.KeyPin.toHex(
        dev.pocketdeck.e2ee.KeyPin.fingerprint(identity.cert.publicKey as java.security.interfaces.ECPublicKey),
    )

    /**
     * A process-local TCP relay: accepts any number of connections on one
     * loopback port and copies every byte to the phone listener and back,
     * unmodified — `pdpathfault --mode pass` in a JVM test.
     */
    private class ByteRelay(private val targetPort: Int) : Closeable {
        private val lock = Any()
        private val listener = ServerSocket(0, 50, InetAddress.getLoopbackAddress())
        private val sockets = mutableListOf<Socket>()

        val port: Int get() = listener.localPort

        init {
            Thread({
                while (!listener.isClosed) {
                    val client = runCatching { listener.accept() }.getOrNull() ?: continue
                    val upstream = runCatching { Socket("127.0.0.1", targetPort) }.getOrNull()
                    if (upstream == null) {
                        runCatching { client.close() }
                        continue
                    }
                    synchronized(lock) {
                        sockets += client
                        sockets += upstream
                    }
                    pump(client, upstream)
                    pump(upstream, client)
                }
            }, "tls-relay-accept").apply { isDaemon = true }.start()
        }

        private fun pump(from: Socket, to: Socket) {
            Thread({
                val buffer = ByteArray(64 * 1024)
                try {
                    val input = from.getInputStream()
                    val output = to.getOutputStream()
                    while (true) {
                        val read = input.read(buffer)
                        if (read < 0) break
                        output.write(buffer, 0, read)
                        output.flush()
                    }
                } catch (_: Exception) {
                } finally {
                    runCatching { from.close() }
                    runCatching { to.close() }
                }
            }, "tls-relay-pump").apply { isDaemon = true }.start()
        }

        override fun close() {
            runCatching { listener.close() }
            synchronized(lock) {
                for (socket in sockets) runCatching { socket.close() }
                sockets.clear()
            }
        }
    }
}
