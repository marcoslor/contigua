package dev.pocketdeck.proto

import java.io.InputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder

/** Thrown for wire-level violations (bad length, oversized frame, truncated body). */
class ProtocolException(message: String) : Exception(message)

/**
 * One wire frame: `u32 len · u8 type · u32 stream · payload` where `len` counts
 * everything after itself. See docs/PROTOCOL.md §Framing.
 */
class Frame(val type: Int, val stream: Int, val payload: ByteArray) {
    override fun toString(): String = "Frame(type=0x${type.toString(16)}, stream=$stream, len=${payload.size})"
}

/** Typed payloads for the fixed-layout frame types. */
data class TouchPayload(val action: Int, val pointerId: Int, val nx: Float, val ny: Float)
data class ScrollPayload(val nx: Float, val ny: Float, val hscroll: Float, val vscroll: Float)
data class KeyPayload(val action: Int, val keycode: Int, val metaState: Int)
data class VideoConfigPayload(val codec: Int, val width: Int, val height: Int, val csd: ByteArray)
data class VideoFramePayload(val ptsUs: Long, val key: Boolean, val data: ByteArray)
data class AudioConfigPayload(val codec: Int, val sampleRate: Int, val channels: Int, val frameMs: Int, val setup: ByteArray)
data class AudioFramePayload(val ptsUs: Long, val data: ByteArray)

/** Frame framing + payload codecs. Big-endian everywhere. */
object Frames {

    const val MAX_FRAME = 8 * 1024 * 1024
    private const val HEADER = 5 // type(1) + stream(4)

    const val TYPE_JSON = 0x01
    const val TYPE_VIDEO_CONFIG = 0x02
    const val TYPE_VIDEO_FRAME = 0x03
    const val TYPE_AUDIO_CONFIG = 0x04
    const val TYPE_AUDIO_FRAME = 0x05
    const val TYPE_TOUCH = 0x10
    const val TYPE_SCROLL = 0x11
    const val TYPE_KEY = 0x12
    const val TYPE_APK_DATA = 0x20
    const val TYPE_SHARE_DATA = 0x21

    const val CODEC_H264 = 1
    const val CODEC_OPUS = 2
    const val CODEC_AAC = 3

    const val TOUCH_DOWN = 0
    const val TOUCH_UP = 1
    const val TOUCH_MOVE = 2
    const val TOUCH_CANCEL = 3

    const val ACTION_DOWN = 0
    const val ACTION_UP = 1

    fun encode(type: Int, stream: Int, payload: ByteArray): ByteArray {
        val bb = ByteBuffer.allocate(4 + HEADER + payload.size).order(ByteOrder.BIG_ENDIAN)
        bb.putInt(HEADER + payload.size)
        bb.put(type.toByte())
        bb.putInt(stream)
        bb.put(payload)
        return bb.array()
    }

    fun encodeJson(stream: Int, json: String): ByteArray = encode(TYPE_JSON, stream, json.toByteArray(Charsets.UTF_8))

    // ---- payload codecs -------------------------------------------------

    fun encodeTouch(p: TouchPayload): ByteArray {
        val bb = ByteBuffer.allocate(1 + 1 + 4 + 4).order(ByteOrder.BIG_ENDIAN)
        bb.put(p.action.toByte())
        bb.put(p.pointerId.toByte())
        bb.putFloat(p.nx)
        bb.putFloat(p.ny)
        return bb.array()
    }

    fun decodeTouch(payload: ByteArray): TouchPayload {
        requireSize(payload, 10, "touch")
        val bb = ByteBuffer.wrap(payload).order(ByteOrder.BIG_ENDIAN)
        return TouchPayload(bb.get().toInt() and 0xFF, bb.get().toInt() and 0xFF, bb.float, bb.float)
    }

    fun encodeScroll(p: ScrollPayload): ByteArray {
        val bb = ByteBuffer.allocate(16).order(ByteOrder.BIG_ENDIAN)
        bb.putFloat(p.nx)
        bb.putFloat(p.ny)
        bb.putFloat(p.hscroll)
        bb.putFloat(p.vscroll)
        return bb.array()
    }

    fun decodeScroll(payload: ByteArray): ScrollPayload {
        requireSize(payload, 16, "scroll")
        val bb = ByteBuffer.wrap(payload).order(ByteOrder.BIG_ENDIAN)
        return ScrollPayload(bb.float, bb.float, bb.float, bb.float)
    }

    fun encodeKey(p: KeyPayload): ByteArray {
        val bb = ByteBuffer.allocate(1 + 4 + 4).order(ByteOrder.BIG_ENDIAN)
        bb.put(p.action.toByte())
        bb.putInt(p.keycode)
        bb.putInt(p.metaState)
        return bb.array()
    }

    fun decodeKey(payload: ByteArray): KeyPayload {
        requireSize(payload, 9, "key")
        val bb = ByteBuffer.wrap(payload).order(ByteOrder.BIG_ENDIAN)
        return KeyPayload(bb.get().toInt() and 0xFF, bb.int, bb.int)
    }

    /** `u8 codec · u16 w · u16 h · Annex-B csd`. */
    fun encodeVideoConfig(p: VideoConfigPayload): ByteArray {
        val bb = ByteBuffer.allocate(5 + p.csd.size).order(ByteOrder.BIG_ENDIAN)
        bb.put(p.codec.toByte())
        bb.putShort(p.width.toShort())
        bb.putShort(p.height.toShort())
        bb.put(p.csd)
        return bb.array()
    }

    fun decodeVideoConfig(payload: ByteArray): VideoConfigPayload {
        requireSize(payload, 5, "video config")
        val bb = ByteBuffer.wrap(payload).order(ByteOrder.BIG_ENDIAN)
        val codec = bb.get().toInt() and 0xFF
        val w = bb.short.toInt() and 0xFFFF
        val h = bb.short.toInt() and 0xFFFF
        val csd = ByteArray(bb.remaining())
        bb.get(csd)
        return VideoConfigPayload(codec, w, h, csd)
    }

    /** `u64 ptsUs · u8 flags(bit0=key) · Annex-B access unit`. */
    fun encodeVideoFrame(p: VideoFramePayload): ByteArray {
        val bb = ByteBuffer.allocate(9 + p.data.size).order(ByteOrder.BIG_ENDIAN)
        bb.putLong(p.ptsUs)
        bb.put(if (p.key) 1 else 0)
        bb.put(p.data)
        return bb.array()
    }

    fun decodeVideoFrame(payload: ByteArray): VideoFramePayload {
        requireSize(payload, 9, "video frame")
        val bb = ByteBuffer.wrap(payload).order(ByteOrder.BIG_ENDIAN)
        val pts = bb.long
        val flags = bb.get().toInt() and 0xFF
        val data = ByteArray(bb.remaining())
        bb.get(data)
        return VideoFramePayload(pts, flags and 1 != 0, data)
    }

    /** `u8 codec · u32 sampleRate · u8 channels · u16 frameMs · setup`. */
    fun encodeAudioConfig(p: AudioConfigPayload): ByteArray {
        val bb = ByteBuffer.allocate(8 + p.setup.size).order(ByteOrder.BIG_ENDIAN)
        bb.put(p.codec.toByte())
        bb.putInt(p.sampleRate)
        bb.put(p.channels.toByte())
        bb.putShort(p.frameMs.toShort())
        bb.put(p.setup)
        return bb.array()
    }

    fun decodeAudioConfig(payload: ByteArray): AudioConfigPayload {
        requireSize(payload, 8, "audio config")
        val bb = ByteBuffer.wrap(payload).order(ByteOrder.BIG_ENDIAN)
        val codec = bb.get().toInt() and 0xFF
        val sampleRate = bb.int
        val channels = bb.get().toInt() and 0xFF
        val frameMs = bb.short.toInt() and 0xFFFF
        val setup = ByteArray(bb.remaining())
        bb.get(setup)
        return AudioConfigPayload(codec, sampleRate, channels, frameMs, setup)
    }

    /** `u64 ptsUs · packet`. */
    fun encodeAudioFrame(p: AudioFramePayload): ByteArray {
        val bb = ByteBuffer.allocate(8 + p.data.size).order(ByteOrder.BIG_ENDIAN)
        bb.putLong(p.ptsUs)
        bb.put(p.data)
        return bb.array()
    }

    fun decodeAudioFrame(payload: ByteArray): AudioFramePayload {
        requireSize(payload, 8, "audio frame")
        val bb = ByteBuffer.wrap(payload).order(ByteOrder.BIG_ENDIAN)
        val pts = bb.long
        val data = ByteArray(bb.remaining())
        bb.get(data)
        return AudioFramePayload(pts, data)
    }

    private fun requireSize(payload: ByteArray, min: Int, what: String) {
        if (payload.size < min) throw ProtocolException("$what payload too short: ${payload.size} < $min")
    }
}

/** Reads whole frames from a stream; returns null on clean EOF at a frame boundary. */
class FrameReader(private val input: InputStream) {

    fun readFrame(): Frame? {
        val header = readFully(4) ?: return null
        val len = readInt(header, 0)
        if (len < 5) throw ProtocolException("frame length too small: $len")
        if (len > Frames.MAX_FRAME) throw ProtocolException("frame length too large: $len")
        val body = readFully(len) ?: throw ProtocolException("truncated frame body")
        val type = body[0].toInt() and 0xFF
        val stream = readInt(body, 1)
        val payload = body.copyOfRange(5, body.size)
        return Frame(type, stream, payload)
    }

    private fun readFully(n: Int): ByteArray? {
        val buf = ByteArray(n)
        var off = 0
        while (off < n) {
            val r = input.read(buf, off, n - off)
            if (r < 0) {
                if (off == 0) return null
                throw ProtocolException("truncated frame (read $off/$n)")
            }
            off += r
        }
        return buf
    }

    private fun readInt(b: ByteArray, off: Int): Int =
        ((b[off].toInt() and 0xFF) shl 24) or
            ((b[off + 1].toInt() and 0xFF) shl 16) or
            ((b[off + 2].toInt() and 0xFF) shl 8) or
            (b[off + 3].toInt() and 0xFF)
}
