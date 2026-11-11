package app.contigua.server

import app.contigua.proto.FrameReader
import app.contigua.proto.Frames
import app.contigua.proto.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.net.Socket

/**
 * The TLS acceptor of [Server] (docs/design/e2ee.md §2): one listener answer
 * with busy + TLS-strict refusals — no plaintext session ever opens.
 */
class ServerTest {

    private fun readJson(reader: FrameReader): Map<String, Any?> {
        val frame = readPathFrame(reader) ?: error("connection closed")
        return pathJson(frame)
    }

    private fun gather(sink: MutableList<Map<String, Any?>>, reader: FrameReader): Map<String, Any?> {
        while (true) {
            val m = readJson(reader)
            sink.add(m)
            if (m.containsKey("ts")) return m
        }
    }

    @Test
    fun secondSessionIsRejectedWithBusy() {
        val platform = FakePlatform()
        platform.clients.add(PairedClient("c1", "MacBook", TlsV2Fixture.MAC_FP_HEX))

        val phoneIdentity = TestTls.generate("Contigua Phone (test)")
        val macIdentity = TestTls.generate("Contigua Mac (test)")

        val server = Server(
            { socket, plain, hello ->
                Session(
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
                    now = { 1_000 },
                    log = {},
                    handshakeTimeoutMs = 3_000,
                    preReadHello = hello,
                    tlsView = TlsV2Fixture.view,
                    gateProvider = { GateSettings(true, true) },
                )
            },
            log = {},
            { phoneIdentity.certPem },
            { phoneIdentity.keyP8 },
            { GateSettings(true, true) },
        )
        val port = server.start()
        try {
            client(port, macIdentity, phoneIdentity).use { first ->
                val firstReader = FrameReader(first.getInputStream())
                val out = first.getOutputStream()
                out.write(Frames.encodeJson(0, Json.encode(mapOf("t" to "hello", "v" to 4, "path" to "a1b2c3d4", "clientId" to "c1", "name" to "MacBook"))))
                out.flush()
                val welcome = readJson(firstReader)
                assertEquals("welcome", welcome["t"])

                client(port, macIdentity, phoneIdentity).use { second ->
                    val secondReader = FrameReader(second.getInputStream())
                    val secondOut = second.getOutputStream()
                    secondOut.write(Frames.encodeJson(0, Json.encode(mapOf("t" to "hello", "v" to 4, "path" to "a1b2c3d4", "clientId" to "c2", "name" to "Other"))))
                    secondOut.flush()
                    val error = readJson(secondReader)
                    assertEquals("error", error["t"])
                    assertEquals("busy", error["code"])
                }

                // The first session survives the rejected second one.
                first.getOutputStream().write(Frames.encodeJson(0, Json.encode(mapOf("t" to "ping", "ts" to 9))))
                first.getOutputStream().flush()
                val frames = mutableListOf<Map<String, Any?>>()
                assertEquals(9L, frames.let { gather(it, firstReader) } ["ts"])
            }
        } finally {
            server.stop()
        }
    }

    /**
     * `tls` check case 1 (docs/design/e2ee.md §6): a plaintext client gets a
     * closed connection and never a `welcome` — no plaintext fallback.
     */
    @Test
    fun plainTextClientIsRefusedWithoutAWelcome() {
        val platform = FakePlatform()
        val phoneIdentity = TestTls.generate("Contigua Phone (plaintext test)")
        val server = Server({ socket, plain, hello -> sessionFor(platform, socket, plain, hello) }, log = {},
            { phoneIdentity.certPem }, { phoneIdentity.keyP8 }, { GateSettings(true, true) })
        val port = server.start()
        try {
            val plain = Socket("127.0.0.1", port)
            plain.tcpNoDelay = true
            plain.soTimeout = 3_000
            val out = plain.getOutputStream()
            out.write(Frames.encodeJson(0, Json.encode(mapOf("t" to "hello", "v" to 4, "path" to "a1b2c3d4", "clientId" to "c1", "name" to "Plaintext"))))
            out.flush()
            out.write(Frames.encodeJson(0, Json.encode(mapOf("t" to "hello", "v" to 4, "path" to "a1b2c3d4", "clientId" to "c1", "name" to "Plaintext"))))
            out.flush()
            // The server answers a plaintext client with a TLS alert and a
            // hangup; whatever comes back never contains a framed `welcome`
            // (`tls` check case 1). Read until the socket is done.
            val echoed = ByteArray(1024)
            var sawWelcome = false
            runCatching {
                val n = plain.getInputStream().read(echoed)
                val text = String(echoed, 0, maxOf(n, 0), Charsets.ISO_8859_1)
                sawWelcome = text.contains("welcome")
            }
            assertEquals(false, sawWelcome)
            assertEquals(false, platform.sessionChanges.any { it.connected })
        } finally {
            server.stop()
        }
    }

    /**
     * Review R4-b: a client that connects and closes without a byte (the Mac's
     * Bonjour resolve) is quiet — no log line, no session — and the next real
     * session still works.
     */
    @Test
    fun emptyConnectionIsQuietAndTheNextSessionWorks() {
        val platform = FakePlatform()
        platform.clients.add(PairedClient("c1", "MacBook", TlsV2Fixture.MAC_FP_HEX))
        val phoneIdentity = TestTls.generate("Contigua Phone (empty test)")
        val macIdentity = TestTls.generate("Contigua Mac (empty test)")
        val logs = java.util.concurrent.CopyOnWriteArrayList<String>()
        val server = Server({ socket, plain, hello -> sessionFor(platform, socket, plain, hello) }, log = { logs.add(it) },
            { phoneIdentity.certPem }, { phoneIdentity.keyP8 }, { GateSettings(true, true) })
        val port = server.start()
        try {
            repeat(3) { Socket("127.0.0.1", port).close() }
            // An empty connection frees its handshake slot as soon as TLS sees
            // the EOF; give the two workers a moment before the real client so
            // this asserts quietness, not the busy-slot rejection. The Docker
            // K1 runs under Rosetta, where a starved worker can need well over
            // 300 ms to see the EOF and free its slot.
            Thread.sleep(1_000)
            client(port, macIdentity, phoneIdentity).use { tls ->
                tls.soTimeout = 3_000
                val ssl = tls as javax.net.ssl.SSLSocket
                ssl.startHandshake()
                assertEquals("TLSv1.3", ssl.session.protocol)
            }
            assertEquals(emptyList<String>(), logs.filter { it.startsWith("tls handshake failed") })
            assertEquals(false, platform.sessionChanges.any { it.connected })
        } finally {
            server.stop()
        }
    }

    /**
     * AppLink's DROP_SESSIONS action (docs/design/e2ee.md §10): the shell closes
     * the live session at once, not at the Mac's next reconnect, and serves the
     * next Mac again once the app has vouched for its state.
     */
    @Test
    fun droppingSessionsClosesTheLiveSessionAtOnce() {
        val platform = FakePlatform()
        platform.clients.add(PairedClient("c1", "MacBook", TlsV2Fixture.MAC_FP_HEX))
        val phoneIdentity = TestTls.generate("Contigua Phone (drop test)")
        val macIdentity = TestTls.generate("Contigua Mac (drop test)")
        val server = Server({ socket, plain, hello -> sessionFor(platform, socket, plain, hello) }, log = {},
            { phoneIdentity.certPem }, { phoneIdentity.keyP8 }, { GateSettings(true, true) })
        val port = server.start()
        try {
            client(port, macIdentity, phoneIdentity).use { first ->
                val reader = FrameReader(first.getInputStream())
                val out = first.getOutputStream()
                out.write(Frames.encodeJson(0, Json.encode(mapOf("t" to "hello", "v" to 4, "path" to "a1b2c3d4", "clientId" to "c1", "name" to "MacBook"))))
                out.flush()
                assertEquals("welcome", readJson(reader)["t"])

                server.dropSessions()
                first.soTimeout = 3_000
                var closed = false
                repeat(6) { if (!closed) closed = runCatching { reader.readFrame() }.getOrNull() == null }
                assertTrue("the live session survived dropSessions", closed)
            }
            // The listener stays useful: the same app state serves again.
            client(port, macIdentity, phoneIdentity).use { again ->
                val reader = FrameReader(again.getInputStream())
                val out = again.getOutputStream()
                out.write(Frames.encodeJson(0, Json.encode(mapOf("t" to "hello", "v" to 4, "path" to "a1b2c3d4", "clientId" to "c1", "name" to "MacBook"))))
                out.flush()
                assertEquals("welcome", readJson(reader)["t"])
            }
        } finally {
            server.stop()
        }
    }

    /**
     * AppLink's FORGET_CACHE action: the TLS material of an identity the app no
     * longer holds is never presented again — the next handshake is refused
     * before TLS completes (PAIR-20).
     */
    @Test
    fun aForgottenIdentityRefusesTheNextHandshake() {
        val platform = FakePlatform()
        platform.clients.add(PairedClient("c1", "MacBook", TlsV2Fixture.MAC_FP_HEX))
        val phoneIdentity = TestTls.generate("Contigua Phone (forget test)")
        val macIdentity = TestTls.generate("Contigua Mac (forget test)")
        var cert = phoneIdentity.certPem
        var key = phoneIdentity.keyP8
        val server = Server({ socket, plain, hello -> sessionFor(platform, socket, plain, hello) }, log = {},
            { cert }, { key }, { GateSettings(true, true) })
        val port = server.start()
        try {
            client(port, macIdentity, phoneIdentity).use { first ->
                val reader = FrameReader(first.getInputStream())
                first.getOutputStream().write(
                    Frames.encodeJson(0, Json.encode(mapOf("t" to "hello", "v" to 4, "path" to "a1b2c3d4", "clientId" to "c1", "name" to "MacBook"))),
                )
                first.getOutputStream().flush()
                assertEquals("welcome", readJson(reader)["t"])
            }
            cert = ""
            key = ""
            server.forgetCachedIdentity()
            server.dropSessions()
            val refused = runCatching {
                client(port, macIdentity, phoneIdentity).use { socket ->
                    (socket as javax.net.ssl.SSLSocket).soTimeout = 3_000
                    socket.startHandshake()
                }
            }.isFailure
            assertTrue("a forgotten identity still completed a TLS handshake", refused)
        } finally {
            server.stop()
        }
    }

    /**
     * PAIR-20's drop rule, measured where it is decided: the app's push runs on
     * a binder thread the app may itself be waiting on (its UI thread for Forget
     * All), so `dropSessions()` hands a slow close over and gives the slot up at
     * once. A real session's close takes as long as the peer does.
     */
    @Test
    fun droppingSessionsNeverWaitsForASlowClose() {
        val session = FakeLiveSession(java.util.concurrent.CountDownLatch(1))
        val dropper = SessionDropper(log = {})
        dropper.adopt(null, false) { session }
        val server = Server(
            { _, _, _ -> error("this test accepts no socket") },
            log = {},
            { "" },
            { "" },
            { GateSettings(true, true) },
            sessions = dropper,
        )

        val started = System.nanoTime()
        server.dropSessions()
        val elapsedMs = (System.nanoTime() - started) / 1_000_000

        assertTrue("dropSessions waited ${elapsedMs}ms for the close", elapsedMs < 100)
        assertNull("the dropped session is still the server's live one", dropper.current())
        assertTrue("the close never ran", session.closeStarted.await(1, java.util.concurrent.TimeUnit.SECONDS))
        session.release()
    }

    @Test
    fun emptyConnectionClassifier() {
        assertEquals(true, Server.isEmptyConnection(javax.net.ssl.SSLHandshakeException("x").apply { initCause(java.io.EOFException()) }))
        assertEquals(true, Server.isEmptyConnection(javax.net.ssl.SSLException("Connection closed by peer")))
        assertEquals(false, Server.isEmptyConnection(javax.net.ssl.SSLHandshakeException("no cipher suites in common")))
    }

    /**
     * H-1: a peer that connects and sends nothing must not stop the phone from
     * serving the next Mac. The silent socket holds one of the two handshake
     * workers; a real client uses the other and completes within seconds.
     */
    @Test
    fun silentClientDoesNotBlockTheNextHandshake() {
        val platform = FakePlatform()
        platform.clients.add(PairedClient("c1", "MacBook", TlsV2Fixture.MAC_FP_HEX))
        val phoneIdentity = TestTls.generate("Contigua Phone (silent test)")
        val macIdentity = TestTls.generate("Contigua Mac (silent test)")
        val server = Server({ socket, plain, hello -> sessionFor(platform, socket, plain, hello) }, log = {},
            { phoneIdentity.certPem }, { phoneIdentity.keyP8 }, { GateSettings(true, true) })
        val port = server.start()
        try {
            Socket("127.0.0.1", port).use { silent ->
                silent.tcpNoDelay = true
                // Give the accept loop a moment to hand the silent socket to a
                // handshake worker before the real client arrives.
                Thread.sleep(200)
                val started = System.nanoTime()
                client(port, macIdentity, phoneIdentity).use { tls ->
                    val ssl = tls as javax.net.ssl.SSLSocket
                    ssl.soTimeout = 5_000
                    ssl.startHandshake()
                    assertEquals("TLSv1.3", ssl.session.protocol)
                }
                val elapsedMs = (System.nanoTime() - started) / 1_000_000
                assertTrue("handshake took ${elapsedMs}ms next to a silent peer", elapsedMs < 5_000)
            }
        } finally {
            server.stop()
        }
    }

    /**
     * M-3: with "Allow connections" off, a stored pin's Mac still gets the
     * protocol refusal (its UI shows it), while any other peer is closed
     * without a single byte once TLS completes.
     */
    @Test
    fun withConnectionsOffOnlyAPinnedPeerHearsTheRefusal() {
        val platform = FakePlatform()
        val phoneIdentity = TestTls.generate("Contigua Phone (gate test)")
        val pinnedMac = TestTls.generate("Contigua Mac (pinned)")
        val unknownMac = TestTls.generate("Contigua Mac (unknown)")
        val pin = app.contigua.e2ee.KeyPin.toHex(
            app.contigua.e2ee.KeyPin.fingerprint(
                pinnedMac.cert.publicKey as java.security.interfaces.ECPublicKey))
        val logs = java.util.Collections.synchronizedList(mutableListOf<String>())
        val server = Server({ socket, plain, hello -> sessionFor(platform, socket, plain, hello) }, log = { logs.add(it) },
            { phoneIdentity.certPem }, { phoneIdentity.keyP8 }, { GateSettings(false, true) },
            { listOf(pin) })
        val port = server.start()
        try {
            client(port, pinnedMac, phoneIdentity).use { tls ->
                val ssl = tls as javax.net.ssl.SSLSocket
                ssl.soTimeout = 3_000
                ssl.startHandshake()
                val out = ssl.getOutputStream()
                out.write(Frames.encodeJson(0, Json.encode(mapOf(
                    "t" to "hello", "v" to 4, "path" to "a1b2c3d4", "clientId" to "c1", "name" to "Mac"))))
                out.flush()
                val error = readJson(FrameReader(ssl.getInputStream()))
                assertEquals("error", error["t"])
                assertEquals("connections_off", error["code"])
            }
            client(port, unknownMac, phoneIdentity).use { tls ->
                val ssl = tls as javax.net.ssl.SSLSocket
                ssl.soTimeout = 3_000
                ssl.startHandshake()
                val first = runCatching { ssl.getInputStream().read() }
                assertTrue("an unknown peer must not get a protocol byte",
                    first.isFailure || first.getOrNull() == -1)
            }
        } finally {
            server.stop()
        }
    }

    /**
     * PAIR-21: a Mac whose own session is still live (a network drop the phone
     * has not noticed) is adopted at once instead of hearing `busy` until the
     * kernel gives up on the vanished peer. A different Mac still gets `busy`.
     */
    @Test
    fun theSamePinnedMacSupersedesItsOwnLiveSession() {
        val platform = FakePlatform()
        platform.clients.add(PairedClient("c1", "MacBook", TlsV2Fixture.MAC_FP_HEX))
        val phoneIdentity = TestTls.generate("Contigua Phone (supersede test)")
        val macA = TestTls.generate("Contigua Mac (A)")
        val macB = TestTls.generate("Contigua Mac (B)")
        val logs = java.util.Collections.synchronizedList(mutableListOf<String>())
        val server = Server({ socket, plain, hello -> sessionFor(platform, socket, plain, hello) }, log = { logs.add(it) },
            { phoneIdentity.certPem }, { phoneIdentity.keyP8 }, { GateSettings(true, true) },
            { listOf(fingerprintHex(macA)) })
        val port = server.start()
        try {
            client(port, macA, phoneIdentity).use { first ->
                val firstReader = FrameReader(first.getInputStream())
                first.getOutputStream().write(
                    Frames.encodeJson(0, Json.encode(mapOf("t" to "hello", "v" to 4, "path" to "a1b2c3d4", "clientId" to "c1", "name" to "MacBook"))),
                )
                first.getOutputStream().flush()
                assertEquals("welcome", readJson(firstReader)["t"])

                // A different Mac is not the same person coming back.
                client(port, macB, phoneIdentity).use { other ->
                    val reader = FrameReader(other.getInputStream())
                    other.getOutputStream().write(
                        Frames.encodeJson(0, Json.encode(mapOf("t" to "hello", "v" to 4, "path" to "a1b2c3d4", "clientId" to "c1", "name" to "MacBook"))),
                    )
                    other.getOutputStream().flush()
                    val error = readJson(reader)
                    assertEquals("error", error["t"])
                    assertEquals("busy", error["code"])
                }

                val started = System.nanoTime()
                client(port, macA, phoneIdentity).use { again ->
                    val reader = FrameReader(again.getInputStream())
                    again.getOutputStream().write(
                        Frames.encodeJson(0, Json.encode(mapOf("t" to "hello", "v" to 4, "path" to "a1b2c3d4", "clientId" to "c1", "name" to "MacBook"))),
                    )
                    again.getOutputStream().flush()
                    assertEquals("welcome", readJson(reader)["t"])
                }
                val elapsedMs = (System.nanoTime() - started) / 1_000_000
                assertTrue("the same Mac waited ${elapsedMs}ms to be adopted", elapsedMs < 2_000)
                assertTrue("the supersede left no line", logs.contains("session superseded"))
            }
        } finally {
            server.stop()
        }
    }

    /**
     * PATH-3: a hello carrying the live session's id, from the live Mac, is a
     * join — one more path, no drop, no second session, and both paths serve.
     */
    @Test
    fun aJoinAttachesWithoutSuperseding() {
        val platform = FakePlatform()
        platform.clients.add(PairedClient("c1", "MacBook", TlsV2Fixture.MAC_FP_HEX))
        val phoneIdentity = TestTls.generate("Contigua Phone (join test)")
        val macIdentity = TestTls.generate("Contigua Mac (join test)")
        val pin = fingerprintHex(macIdentity)
        val server = Server({ socket, plain, hello -> sessionFor(platform, socket, plain, hello) }, log = {},
            { phoneIdentity.certPem }, { phoneIdentity.keyP8 }, { GateSettings(true, true) },
            { listOf(pin) })
        val port = server.start()
        try {
            client(port, macIdentity, phoneIdentity).use { first ->
                val firstReader = FrameReader(first.getInputStream())
                first.getOutputStream().write(Frames.encodeJson(0, Json.encode(mapOf(
                    "t" to "hello", "v" to 4, "path" to "a1b2c3d4", "clientId" to "c1", "name" to "MacBook"))))
                first.getOutputStream().flush()
                val welcome = readJson(firstReader)
                assertEquals("welcome", welcome["t"])
                val session = welcome["session"] as String
                assertEquals(32, session.length)

                client(port, macIdentity, phoneIdentity).use { second ->
                    val secondReader = FrameReader(second.getInputStream())
                    second.getOutputStream().write(Frames.encodeJson(0, Json.encode(mapOf(
                        "t" to "hello", "v" to 4, "path" to "b2c3d4e5", "join" to session,
                        "clientId" to "c1", "name" to "MacBook"))))
                    second.getOutputStream().flush()
                    val joined = readJson(secondReader)
                    assertEquals("welcome", joined["t"])
                    assertEquals(session, joined["session"])

                    // PATH-13: a session has at most three paths; the fourth
                    // join is refused with its own code. The third stays open
                    // so the cap is what refuses the fourth.
                    val third = client(port, macIdentity, phoneIdentity)
                    val thirdReader = FrameReader(third.getInputStream())
                    third.getOutputStream().write(Frames.encodeJson(0, Json.encode(mapOf(
                        "t" to "hello", "v" to 4, "path" to "c3d4e5f6", "join" to session,
                        "clientId" to "c1", "name" to "MacBook"))))
                    third.getOutputStream().flush()
                    assertEquals("welcome", readJson(thirdReader)["t"])
                    client(port, macIdentity, phoneIdentity).use { fourth ->
                        val fourthReader = FrameReader(fourth.getInputStream())
                        fourth.getOutputStream().write(Frames.encodeJson(0, Json.encode(mapOf(
                            "t" to "hello", "v" to 4, "path" to "d4e5f6a7", "join" to session,
                            "clientId" to "c1", "name" to "MacBook"))))
                        fourth.getOutputStream().flush()
                        val error = readJson(fourthReader)
                        assertEquals("error", error["t"])
                        assertEquals("too_many_paths", error["code"])
                    }
                    third.close()

                    // PATH-3: the first path was not superseded by the join.
                    first.getOutputStream().write(Frames.encodeJson(0, Json.encode(mapOf("t" to "ping", "ts" to 6))))
                    first.getOutputStream().flush()
                    assertEquals(6L, gather(mutableListOf(), firstReader)["ts"])
                    // PATH-8: the Mac's marker moves the phone's sending path;
                    // the next reply goes out on the joined path.
                    second.getOutputStream().write(Frames.encodeJson(0, Json.encode(mapOf(
                        "t" to "path.switch", "path" to "b2c3d4e5", "seq" to 1))))
                    second.getOutputStream().flush()
                    second.getOutputStream().write(Frames.encodeJson(0, Json.encode(mapOf("t" to "ping", "ts" to 5))))
                    second.getOutputStream().flush()
                    // The replay may resend the first pong (it was never acked);
                    // wait for this ping's own answer.
                    var pong = gather(mutableListOf(), secondReader)
                    while ((pong["ts"] as Number).toLong() != 5L) pong = gather(mutableListOf(), secondReader)
                    assertEquals(5L, pong["ts"])
                }
            }
        } finally {
            server.stop()
        }
    }

    /**
     * PATH-1: the phone's own version check runs before any session state
     * exists: a v3 hello gets `error version` with this phone's v and a close,
     * never a `welcome`.
     */
    @Test
    fun aV3HelloIsRefusedBeforeAnySessionExists() {
        val platform = FakePlatform()
        val phoneIdentity = TestTls.generate("Contigua Phone (version test)")
        val macIdentity = TestTls.generate("Contigua Mac (version test)")
        val server = Server({ socket, plain, hello -> sessionFor(platform, socket, plain, hello) }, log = {},
            { phoneIdentity.certPem }, { phoneIdentity.keyP8 }, { GateSettings(true, true) })
        val port = server.start()
        try {
            client(port, macIdentity, phoneIdentity).use { old ->
                val reader = FrameReader(old.getInputStream())
                old.getOutputStream().write(Frames.encodeJson(0, Json.encode(mapOf(
                    "t" to "hello", "v" to 3, "path" to "a1b2c3d4", "clientId" to "c3", "name" to "OldMac"))))
                old.getOutputStream().flush()
                val error = readJson(reader)
                assertEquals("error", error["t"])
                assertEquals("version", error["code"])
                assertEquals(4L, (error["v"] as Number).toLong())
                assertNull(reader.readFrame())
            }
        } finally {
            server.stop()
        }
    }

    /** R-8/D-4: the version refusal reaches the app through the callback. */
    @Test
    fun aRefusedVersionReachesTheAppCallback() {
        val platform = FakePlatform()
        val phoneIdentity = TestTls.generate("Contigua Phone (version callback)")
        val macIdentity = TestTls.generate("Contigua Mac (version callback)")
        val seen = mutableListOf<Int?>()
        val server = Server(
            { socket, plain, hello -> sessionFor(platform, socket, plain, hello) },
            log = {},
            { phoneIdentity.certPem },
            { phoneIdentity.keyP8 },
            { GateSettings(true, true) },
            { listOf(fingerprintHex(macIdentity)) },
            onVersionRefused = { seen.add(it) },
        )
        val port = server.start()
        try {
            client(port, macIdentity, phoneIdentity).use { old ->
                val reader = FrameReader(old.getInputStream())
                old.getOutputStream().write(Frames.encodeJson(0, Json.encode(mapOf(
                    "t" to "hello", "v" to 3, "path" to "a1b2c3d4", "clientId" to "c3", "name" to "OldMac"))))
                old.getOutputStream().flush()
                assertEquals("version", readJson(reader)["code"])
            }
            assertEquals(listOf<Int?>(3), seen)
        } finally {
            server.stop()
        }
    }

    /** RR-13: an unpinned peer never reaches the slot; its hello must not put
     * a sentence on the person's card either. */
    @Test
    fun anUnpinnedRefusedVersionLeavesTheCardAlone() {
        val platform = FakePlatform()
        val phoneIdentity = TestTls.generate("Contigua Phone (version unpinned)")
        val macIdentity = TestTls.generate("Contigua Mac (version unpinned)")
        val seen = mutableListOf<Int?>()
        val server = Server(
            { socket, plain, hello -> sessionFor(platform, socket, plain, hello) },
            log = {},
            { phoneIdentity.certPem },
            { phoneIdentity.keyP8 },
            { GateSettings(true, true) },
            onVersionRefused = { seen.add(it) },
        )
        val port = server.start()
        try {
            client(port, macIdentity, phoneIdentity).use { old ->
                val reader = FrameReader(old.getInputStream())
                old.getOutputStream().write(Frames.encodeJson(0, Json.encode(mapOf(
                    "t" to "hello", "v" to 3, "path" to "a1b2c3d4", "clientId" to "c3", "name" to "OldMac"))))
                old.getOutputStream().flush()
                assertEquals("version", readJson(reader)["code"])
            }
            assertEquals(emptyList<Int?>(), seen)
        } finally {
            server.stop()
        }
    }

    /** PATH-3: a join for an id the phone does not serve answers `no_session`. */
    @Test
    fun aJoinForAnUnknownSessionIsRefused() {
        val platform = FakePlatform()
        platform.clients.add(PairedClient("c1", "MacBook", TlsV2Fixture.MAC_FP_HEX))
        val phoneIdentity = TestTls.generate("Contigua Phone (stale join)")
        val macIdentity = TestTls.generate("Contigua Mac (stale join)")
        val pin = fingerprintHex(macIdentity)
        val server = Server({ socket, plain, hello -> sessionFor(platform, socket, plain, hello) }, log = {},
            { phoneIdentity.certPem }, { phoneIdentity.keyP8 }, { GateSettings(true, true) },
            { listOf(pin) })
        val port = server.start()
        try {
            client(port, macIdentity, phoneIdentity).use { first ->
                val firstReader = FrameReader(first.getInputStream())
                first.getOutputStream().write(Frames.encodeJson(0, Json.encode(mapOf(
                    "t" to "hello", "v" to 4, "path" to "a1b2c3d4", "clientId" to "c1", "name" to "MacBook"))))
                first.getOutputStream().flush()
                assertEquals("welcome", readJson(firstReader)["t"])

                client(port, macIdentity, phoneIdentity).use { second ->
                    val secondReader = FrameReader(second.getInputStream())
                    second.getOutputStream().write(Frames.encodeJson(0, Json.encode(mapOf(
                        "t" to "hello", "v" to 4, "path" to "c3d4e5f6", "join" to "1".repeat(32),
                        "clientId" to "c1", "name" to "MacBook"))))
                    second.getOutputStream().flush()
                    val error = readJson(secondReader)
                    assertEquals("error", error["t"])
                    assertEquals("no_session", error["code"])
                }
            }
        } finally {
            server.stop()
        }
    }

    /**
     * RRR-2/E-1: only the founder's socket was sized 128 KiB (in Session), so a
     * joined path kept the kernel's autotuned MiBs: after a failover the
     * delta-drop rule fired seconds late and video sat in the kernel. Every
     * path socket is sized at the one place a connection is served.
     */
    @Test
    fun aJoinedPathSocketCarriesTheSendBufferCap() {
        val phoneIdentity = TestTls.generate("Contigua Phone (send buffer)")
        val macIdentity = TestTls.generate("Contigua Mac (send buffer)")
        val pin = fingerprintHex(macIdentity)
        val sessionId = "1".repeat(32)
        val live = FakeLiveSession(sessionId = sessionId).apply { attachResult = AttachResult.ATTACHED }
        val dropper = SessionDropper()
        dropper.adopt(pin, true) { live }
        val server = Server(
            { _, _, _ -> error("a join must not found a session") }, log = {},
            { phoneIdentity.certPem }, { phoneIdentity.keyP8 }, { GateSettings(true, true) },
            { listOf(pin) }, sessions = dropper,
        )
        val port = server.start()
        try {
            client(port, macIdentity, phoneIdentity).use { join ->
                join.getOutputStream().write(Frames.encodeJson(0, Json.encode(mapOf(
                    "t" to "hello", "v" to 4, "path" to "b2c3d4e5", "join" to sessionId,
                    "clientId" to "c1", "name" to "MacBook"))))
                join.getOutputStream().flush()
                val deadline = System.currentTimeMillis() + 3_000
                while (live.attachedPlain == null && System.currentTimeMillis() < deadline) Thread.sleep(5) // real-time: the join is attached on the server's handshake thread
            }
            val plain = live.attachedPlain ?: error("the join never reached the session")
            val size = plain.sendBufferSize
            // Linux reports twice what was set; a socket that was never sized
            // reports the small autotuning seed instead.
            assertTrue("the joined path's send buffer is $size bytes", size >= Session.SEND_BUFFER_BYTES)
            assertTrue("the joined path's send buffer is $size bytes", size <= 2 * Session.SEND_BUFFER_BYTES)
        } finally {
            server.stop()
        }
    }

    private fun fingerprintHex(identity: TestTls.Identity): String = app.contigua.e2ee.KeyPin.toHex(
        app.contigua.e2ee.KeyPin.fingerprint(identity.cert.publicKey as java.security.interfaces.ECPublicKey),
    )

    /**
     * N1: `tos=136` marks the accepted socket before the TLS handshake, and
     * with no switch the socket is left as it was.
     */
    @Test
    fun theTrafficClassIsAppliedBeforeTheTlsHandshake() {
        val platform = FakePlatform()
        platform.clients.add(PairedClient("c1", "MacBook", TlsV2Fixture.MAC_FP_HEX))
        val phoneIdentity = TestTls.generate("Contigua Phone (tos test)")
        val macIdentity = TestTls.generate("Contigua Mac (tos test)")
        val order = java.util.Collections.synchronizedList(mutableListOf<String>())
        val server = Server(
            { socket, plain, hello ->
                order.add("session")
                sessionFor(platform, socket, plain, hello)
            },
            log = {},
            { phoneIdentity.certPem },
            { phoneIdentity.keyP8 },
            { GateSettings(true, true) },
            strategy = {
                StreamStrategy.parse { key -> if (key == "tos") "136" else null }
            },
            markTraffic = { _, tos ->
                order.add("tos=$tos")
                true
            },
        )
        val port = server.start()
        try {
            client(port, macIdentity, phoneIdentity).use { first ->
                val reader = FrameReader(first.getInputStream())
                val out = first.getOutputStream()
                out.write(Frames.encodeJson(0, Json.encode(mapOf("t" to "hello", "v" to 4, "path" to "a1b2c3d4", "clientId" to "c1", "name" to "MacBook"))))
                out.flush()
                assertEquals("welcome", readJson(reader)["t"])
            }
            assertEquals(listOf("tos=136", "session"), order.toList())
        } finally {
            server.stop()
        }
    }

    @Test
    fun noTrafficClassSwitchLeavesTheSocketAlone() {
        val platform = FakePlatform()
        val phoneIdentity = TestTls.generate("Contigua Phone (tos off test)")
        val macIdentity = TestTls.generate("Contigua Mac (tos off test)")
        var marked = false
        val server = Server(
            { socket, plain, hello -> sessionFor(platform, socket, plain, hello) },
            log = {},
            { phoneIdentity.certPem },
            { phoneIdentity.keyP8 },
            { GateSettings(true, true) },
            strategy = { StreamStrategy.DEFAULT },
            markTraffic = { _, _ ->
                marked = true
                true
            },
        )
        val port = server.start()
        try {
            client(port, macIdentity, phoneIdentity).use { first ->
                (first as javax.net.ssl.SSLSocket).startHandshake()
            }
            assertEquals(false, marked)
        } finally {
            server.stop()
        }
    }

    private fun sessionFor(
        platform: FakePlatform,
        socket: Socket,
        plain: Socket,
        hello: Map<String, Any?>?,
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
        now = { 1_000 },
        log = {},
        handshakeTimeoutMs = 3_000,
        tlsView = TlsV2Fixture.view,
        gateProvider = { GateSettings(true, true) },
        preReadHello = hello,
    )

    @Test
    fun aForgottenMacHearsForgottenOnTheLiveSessionBeforeTheClose() {
        val platform = FakePlatform()
        platform.clients.add(PairedClient("c1", "MacBook", TlsV2Fixture.MAC_FP_HEX))
        val phoneIdentity = TestTls.generate("Contigua Phone (forget)")
        val macIdentity = TestTls.generate("Contigua Mac (forget)")
        val server = Server(
            { socket, plain, hello ->
                Session(
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
                    now = { 1_000 },
                    log = {},
                    handshakeTimeoutMs = 3_000,
                    preReadHello = hello,
                    tlsView = TlsV2Fixture.view,
                    gateProvider = { GateSettings(true, true) },
                )
            },
            log = {},
            { phoneIdentity.certPem },
            { phoneIdentity.keyP8 },
            { GateSettings(true, true) },
        )
        val port = server.start()
        try {
            client(port, macIdentity, phoneIdentity).use { mac ->
                val reader = FrameReader(mac.getInputStream())
                val out = mac.getOutputStream()
                out.write(Frames.encodeJson(0, Json.encode(mapOf("t" to "hello", "v" to 4,
                    "path" to "a1b2c3d4", "clientId" to "c1", "name" to "MacBook"))))
                out.flush()
                assertEquals("welcome", readJson(reader)["t"])

                // A Mac the live session does not belong to hears nothing.
                assertEquals(0, server.notifyForgotten(setOf("other")))

                assertEquals(1, server.notifyForgotten(setOf("c1")))
                var told: Map<String, Any?>? = null
                for (i in 0 until 20) {
                    val message = try { readJson(reader) } catch (e: Throwable) { break }
                    if (message["t"] == "error") { told = message; break }
                }
                assertEquals("forgotten", told?.get("code"))
            }
        } finally {
            server.stop()
        }
    }

    private fun client(port: Int, macIdentity: TestTls.Identity, phoneIdentity: TestTls.Identity): Socket =
        TestTls.clientSocket(macIdentity, phoneIdentity.certPem, "127.0.0.1", port)
}
