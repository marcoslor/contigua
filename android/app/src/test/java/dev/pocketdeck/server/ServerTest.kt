package dev.pocketdeck.server

import dev.pocketdeck.proto.Crypto
import dev.pocketdeck.proto.FrameReader
import dev.pocketdeck.proto.Frames
import dev.pocketdeck.proto.Json
import org.junit.Assert.assertEquals
import org.junit.Test
import java.net.Socket

class ServerTest {

    private fun readJson(reader: FrameReader): Map<String, Any?> {
        val frame = reader.readFrame() ?: error("connection closed")
        return Json.parseObject(String(frame.payload))
    }

    @Test
    fun secondSessionIsRejectedWithBusy() {
        val platform = FakePlatform()
        val keyHex = Crypto.toHex(Crypto.randomBytes(32))
        platform.clients.add(PairedClient("c1", "MacBook", keyHex))

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
                )
            },
            log = {},
        )
        val port = server.start()
        try {
            val first = Socket("127.0.0.1", port).apply { soTimeout = 5_000; tcpNoDelay = true }
            val firstReader = FrameReader(first.getInputStream())
            val out = first.getOutputStream()
            out.write(Frames.encodeJson(0, Json.encode(mapOf("t" to "hello", "v" to 1, "clientId" to "c1", "name" to "MacBook"))))
            out.flush()
            val challenge = readJson(firstReader)
            assertEquals("dev1", challenge["id"])
            val nonce = challenge["nonce"] as String
            val mac = Crypto.hmacSha256Hex(Crypto.fromHex(keyHex), nonce.toByteArray(Charsets.UTF_8))
            out.write(Frames.encodeJson(0, Json.encode(mapOf("t" to "auth", "mac" to mac))))
            out.flush()
            assertEquals("welcome", readJson(firstReader)["t"])

            val second = Socket("127.0.0.1", port).apply { soTimeout = 5_000; tcpNoDelay = true }
            val secondReader = FrameReader(second.getInputStream())
            val error = readJson(secondReader)
            assertEquals("error", error["t"])
            assertEquals("busy", error["code"])

            runCatching { second.close() }
            runCatching { first.close() }
        } finally {
            server.stop()
        }
    }
}
