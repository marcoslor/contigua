package dev.pocketdeck.server

import dev.pocketdeck.proto.Frames
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * PROTOCOL "Video rules": `window.opened` first, then `window.content` and
 * VIDEO_CONFIG, then frames. `window.opened` waits for the task id the launch
 * makes (WIN-32), so video can arrive before it; the gate holds the CONFIG and
 * the newest keyframe and drops the delta frames that would precede them.
 */
class OpenGateTest : SessionFixture() {

    private val log = ArrayList<String>()
    private val gate = OpenGate(
        sendJson = { stream, json -> log.add("json:$stream:$json") },
        sendControl = { stream, bytes -> log.add("control:$stream:${bytes[0]}") },
        sendDelta = { stream, pts, bytes -> log.add("delta:$stream:${bytes[0]}") },
    )

    @Test
    fun `config and keyframe wait for the opener, delta frames are dropped`() {
        gate.expect(1)
        gate.config(1, "content", byteArrayOf(2))
        gate.frame(1, 100, key = false, bytes = byteArrayOf(7))
        gate.frame(1, 200, key = true, bytes = byteArrayOf(8))
        gate.frame(1, 300, key = false, bytes = byteArrayOf(9))
        gate.frame(1, 400, key = true, bytes = byteArrayOf(10))
        assertTrue("nothing goes out before window.opened", log.isEmpty())

        gate.announce(1) { log.add("opened") }
        assertEquals(listOf("opened", "json:1:content", "control:1:2", "control:1:10"), log)
    }

    @Test
    fun `after the opener everything goes straight through in order`() {
        gate.expect(1)
        gate.announce(1) { log.add("opened") }
        gate.config(1, "content", byteArrayOf(2))
        gate.frame(1, 100, key = true, bytes = byteArrayOf(8))
        gate.frame(1, 200, key = false, bytes = byteArrayOf(9))
        assertEquals(listOf("opened", "json:1:content", "control:1:2", "control:1:8", "delta:1:9"), log)
    }

    @Test
    fun `a stream nobody is opening passes through`() {
        gate.config(5, "content", byteArrayOf(2))
        gate.frame(5, 1, key = false, bytes = byteArrayOf(3))
        assertEquals(listOf("json:5:content", "control:5:2", "delta:5:3"), log)
    }

    @Test
    fun `a forgotten stream never sends what it held`() {
        gate.expect(1)
        gate.config(1, "content", byteArrayOf(2))
        gate.frame(1, 1, key = true, bytes = byteArrayOf(3))
        gate.forget(1)
        gate.announce(1) { log.add("opened") }
        assertEquals(emptyList<String>(), log)
    }

    @Test
    fun `window opened comes before the video a slow launch produced`() {
        connect()
        platform.video = CannedVideo { stream, w, h, sink ->
            // The display draws before the launch reply arrives, as a real
            // encoder does; the session must still open the window first.
            sink.onConfig(stream, Frames.CODEC_H264, w, h, byteArrayOf(0, 1, 2), IntRect(0, 0, w, h))
            sink.onFrame(stream, 0, key = true, byteArrayOf(7))
        }
        open(1, "com.a")
        val opened = readUntil("window.opened")
        assertEquals(1L, opened["stream"])
        assertEquals("window.content", readUntil("window.content")["t"])
        val config = readFrame()
        assertEquals("the config follows its opener", Frames.TYPE_VIDEO_CONFIG, config?.type)
    }
}
