package app.contigua.server

import app.contigua.proto.FrameReader
import app.contigua.proto.Frames
import app.contigua.proto.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * PAIR-5/R2: a phone inside its post-deny cooldown refuses a `pair.request`
 * with `pair_cooldown` on the wire, before the session closes. The real phone
 * sends the session-level error with `stream: 0` (Session.sendError); this
 * runs the production TLS acceptor so the write-then-close shape is the one a
 * Mac sees, not a plaintext harness.
 */
class PairCooldownWireTest {

    private fun readJson(reader: FrameReader): Map<String, Any?> {
        val frame = readPathFrame(reader) ?: error("connection closed")
        return pathJson(frame)
    }

    @Test
    fun theCooldownRefusalIsWrittenBeforeTheSessionCloses() {
        var ms = 1_000L
        val cooldown = PairCooldown(now = { ms })
        cooldown.start()
        assertTrue("the test starts inside the window", cooldown.active())

        val platform = FakePlatform()
        val phoneIdentity = TestTls.generate("Contigua Phone (cooldown wire)")
        val macIdentity = TestTls.generate("Contigua Mac (cooldown wire)")
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
                    pairCooldown = cooldown,
                )
            },
            log = {},
            { phoneIdentity.certPem },
            { phoneIdentity.keyP8 },
            { GateSettings(true, true) },
        )
        val port = server.start()
        try {
            TestTls.clientSocket(macIdentity, phoneIdentity.certPem, "127.0.0.1", port).use { mac ->
                val reader = FrameReader(mac.getInputStream())
                val out = mac.getOutputStream()
                // An unpaired Mac that asks to pair: the gate accepts, then the
                // cooldown refuses before any prompt or code.
                out.write(Frames.encodeJson(0, Json.encode(mapOf(
                    "t" to "hello", "v" to 4, "path" to "a1b2c3d4",
                    "clientId" to "c1", "name" to "MacBook", "pair" to true))))
                out.flush()
                out.write(Frames.encodeJson(0, Json.encode(mapOf("t" to "pair.request"))))
                out.flush()

                val error = readJson(reader)
                assertEquals("error", error["t"])
                assertEquals("pair_cooldown", error["code"])
                // The Mac reads a session-level error: the real phone's
                // sendError always names stream 0.
                assertEquals(0, (error["stream"] as? Number)?.toInt())

                // The error is the last frame: the session closes only after it
                // is on the wire, never before.
                val end = System.currentTimeMillis() + 3_000
                var closed = false
                while (System.currentTimeMillis() < end) {
                    val frame = runCatching { readPathFrame(reader) }.getOrNull()
                    if (frame == null) { closed = true; break }
                    val message = pathJson(frame)
                    throw AssertionError("a frame after the refusal: ${message["t"]}")
                }
                assertTrue("the session did not close after the refusal", closed)
            }
        } finally {
            server.stop()
        }
    }
}
