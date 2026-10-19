package dev.pocketdeck.server

import dev.pocketdeck.proto.FrameReader
import dev.pocketdeck.proto.Frames
import dev.pocketdeck.proto.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.net.Socket

/**
 * The TLS acceptor of [Server] (docs/design/e2ee.md §2): one listener answer
 * with busy + TLS-strict refusals — no plaintext session ever opens.
 */
class ServerTest {

    private fun readJson(reader: FrameReader): Map<String, Any?> {
        val frame = reader.readFrame() ?: error("connection closed")
        return Json.parseObject(String(frame.payload))
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

        val phoneIdentity = TestTls.generate("PocketDeck Phone (test)")
        val macIdentity = TestTls.generate("PocketDeck Mac (test)")

        val server = Server(
            { socket ->
                Session(
                    socket = socket,
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
                out.write(Frames.encodeJson(0, Json.encode(mapOf("t" to "hello", "v" to 2, "clientId" to "c1", "name" to "MacBook"))))
                out.flush()
                val welcome = readJson(firstReader)
                assertEquals("welcome", welcome["t"])

                client(port, macIdentity, phoneIdentity).use { second ->
                    val secondReader = FrameReader(second.getInputStream())
                    val secondOut = second.getOutputStream()
                    secondOut.write(Frames.encodeJson(0, Json.encode(mapOf("t" to "hello", "v" to 2, "clientId" to "c2", "name" to "Other"))))
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
        val phoneIdentity = TestTls.generate("PocketDeck Phone (plaintext test)")
        val server = Server({ socket -> sessionFor(platform, socket) }, log = {},
            { phoneIdentity.certPem }, { phoneIdentity.keyP8 }, { GateSettings(true, true) })
        val port = server.start()
        try {
            val plain = Socket("127.0.0.1", port)
            plain.tcpNoDelay = true
            plain.soTimeout = 3_000
            val out = plain.getOutputStream()
            out.write(Frames.encodeJson(0, Json.encode(mapOf("t" to "hello", "v" to 2, "clientId" to "c1", "name" to "Plaintext"))))
            out.flush()
            out.write(Frames.encodeJson(0, Json.encode(mapOf("t" to "hello", "v" to 2, "clientId" to "c1", "name" to "Plaintext"))))
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
        val phoneIdentity = TestTls.generate("PocketDeck Phone (empty test)")
        val macIdentity = TestTls.generate("PocketDeck Mac (empty test)")
        val logs = java.util.Collections.synchronizedList(mutableListOf<String>())
        val server = Server({ socket -> sessionFor(platform, socket) }, log = { logs.add(it) },
            { phoneIdentity.certPem }, { phoneIdentity.keyP8 }, { GateSettings(true, true) })
        val port = server.start()
        try {
            repeat(3) { Socket("127.0.0.1", port).close() }
            // An empty connection frees its handshake slot as soon as TLS sees
            // the EOF; give the two workers a moment before the real client so
            // this asserts quietness, not the busy-slot rejection.
            Thread.sleep(300)
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
        val phoneIdentity = TestTls.generate("PocketDeck Phone (silent test)")
        val macIdentity = TestTls.generate("PocketDeck Mac (silent test)")
        val server = Server({ socket -> sessionFor(platform, socket) }, log = {},
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
        val phoneIdentity = TestTls.generate("PocketDeck Phone (gate test)")
        val pinnedMac = TestTls.generate("PocketDeck Mac (pinned)")
        val unknownMac = TestTls.generate("PocketDeck Mac (unknown)")
        val pin = dev.pocketdeck.e2ee.KeyPin.toHex(
            dev.pocketdeck.e2ee.KeyPin.fingerprint(
                pinnedMac.cert.publicKey as java.security.interfaces.ECPublicKey))
        val logs = java.util.Collections.synchronizedList(mutableListOf<String>())
        val server = Server({ socket -> sessionFor(platform, socket) }, log = { logs.add(it) },
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
                    "t" to "hello", "v" to 2, "clientId" to "c1", "name" to "Mac"))))
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

    private fun sessionFor(platform: FakePlatform, socket: Socket): Session = Session(
        socket = socket,
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
    )

    private fun client(port: Int, macIdentity: TestTls.Identity, phoneIdentity: TestTls.Identity): Socket =
        TestTls.clientSocket(macIdentity, phoneIdentity.certPem, "127.0.0.1", port)
}
