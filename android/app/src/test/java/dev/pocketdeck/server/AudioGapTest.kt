package dev.pocketdeck.server

import dev.pocketdeck.proto.Frames
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * R4: with a 300 KiB keyframe queued and audio arriving every 20 ms, no audio
 * packet waits behind more than one 16 KiB video chunk plus the 16 KiB kernel
 * buffer. The queue's chunk lane is what lets audio overtake the rest of a
 * large frame.
 */
class AudioGapTest {
    private fun videoFrame(stream: Int, ptsUs: Long, key: Boolean, dataBytes: Int): ByteArray {
        val payload = ByteBuffer.allocate(9 + dataBytes).order(ByteOrder.BIG_ENDIAN)
        payload.putLong(ptsUs)
        payload.put(if (key) 1 else 0)
        payload.put(ByteArray(dataBytes) { (it * 31 % 251).toByte() })
        return Frames.encode(Frames.TYPE_VIDEO_FRAME, stream, payload.array())
    }

    private fun audioFrame(ptsUs: Long): ByteArray {
        val payload = ByteBuffer.allocate(8 + 200).order(ByteOrder.BIG_ENDIAN)
        payload.putLong(ptsUs)
        payload.put(ByteArray(200) { 7 })
        return Frames.encode(Frames.TYPE_AUDIO_FRAME, 0, payload.array())
    }

    @Test
    fun audioNeverWaitsBehindMoreThanOneChunkOfAKeyframe() {
        var nowUs = 0L
        val q = SendQueue(nowUs = { nowUs }).also { it.videoChunks = true }
        q.enqueueControl(1, videoFrame(1, 0, key = true, dataBytes = 300 * 1024), ptsUs = 0)
        // A 6 Mbit/s link: one 16 KiB chunk is 21.8 ms; R4 allows two (the
        // in-flight write plus the kernel buffer) = 43.7 ms.
        val bytesPerUs = 6_000_000.0 / 8.0 / 1_000_000.0
        val boundUs = (2 * 16 * 1024 / bytesPerUs).toLong()
        val tickUs = 20_000L
        var maxWait = 0L
        var audioSent = 0
        var chunks = 0
        var chunkCount = 0
        var expectedIndex = 0
        for (tick in 0 until 30) {  // 600 ms
            q.enqueueAudio(audioFrame(tick * tickUs), nowUs)
            val until = nowUs + tickUs
            while (true) {
                val entry = q.pollNow() ?: break
                nowUs += (entry.bytes.size / bytesPerUs).toLong()
                when (entry.bytes[4].toInt() and 0xFF) {
                    Frames.TYPE_AUDIO_FRAME -> {
                        audioSent++
                        maxWait = maxOf(maxWait, nowUs - entry.enqueuedUs)
                    }
                    Frames.TYPE_VIDEO_CHUNK -> {
                        chunks++
                        val index = ((entry.bytes[18].toInt() and 0xFF) shl 8) or
                            (entry.bytes[19].toInt() and 0xFF)
                        chunkCount = ((entry.bytes[20].toInt() and 0xFF) shl 8) or
                            (entry.bytes[21].toInt() and 0xFF)
                        assertEquals(expectedIndex, index)
                        expectedIndex++
                    }
                    Frames.TYPE_VIDEO_FRAME ->
                        throw AssertionError("a 300 KiB keyframe went on the wire whole")
                }
                if (nowUs >= until) break
            }
            nowUs = maxOf(nowUs, until)
        }
        assertEquals(30, audioSent)
        assertEquals(19, chunkCount)
        assertEquals(19, chunks)
        assertTrue("audio waited $maxWait us, R4 bound $boundUs us", maxWait <= boundUs)
    }

    @Test
    fun aLargeDeltaIsChunkedToo() {
        val q = SendQueue().also { it.videoChunks = true }
        q.enqueueDelta(1, 0, videoFrame(1, 0, key = false, dataBytes = 80 * 1024))
        val first = q.pollNow()!!
        assertEquals(Frames.TYPE_VIDEO_CHUNK, first.bytes[4].toInt() and 0xFF)
        var chunks = 1
        while (true) {
            val next = q.pollNow() ?: break
            assertEquals(Frames.TYPE_VIDEO_CHUNK, next.bytes[4].toInt() and 0xFF)
            chunks++
        }
        assertEquals(5, chunks)
    }

    @Test
    fun aSmallFrameGoesWhole() {
        val q = SendQueue().also { it.videoChunks = true }
        q.enqueueControl(1, videoFrame(1, 0, key = true, dataBytes = 1000), ptsUs = 0)
        val entry = q.pollNow()!!
        assertEquals(Frames.TYPE_VIDEO_FRAME, entry.bytes[4].toInt() and 0xFF)
    }

    @Test
    fun aMacWithoutTheHelloCapabilityGetsWholeFrames() {
        val q = SendQueue()
        q.enqueueControl(1, videoFrame(1, 0, key = true, dataBytes = 300 * 1024), ptsUs = 0)
        val entry = q.pollNow()!!
        assertEquals(Frames.TYPE_VIDEO_FRAME, entry.bytes[4].toInt() and 0xFF)
    }
}
