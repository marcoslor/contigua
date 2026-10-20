package dev.pocketdeck.camera

import java.io.EOFException
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream

/**
 * The app → shell framing of one camera capture (docs/design/camera.md "C1
 * implementation notes"): `u32 len · u64 ptsUs · u8 flags · Annex-B access unit`,
 * big-endian, one record per encoder output buffer. Pure Kotlin so the JVM tests
 * can read back exactly what a capture writes.
 */
object CameraAu {

    /** `flags` bit0: the record's access unit starts with an IDR (and SPS/PPS). */
    const val FLAG_KEYFRAME = 1

    /** One access unit can never exceed the wire's frame cap (docs/PROTOCOL.md). */
    const val MAX_BYTES = 8 * 1024 * 1024

    class Au(val ptsUs: Long, val key: Boolean, val data: ByteArray)

    fun write(out: OutputStream, ptsUs: Long, key: Boolean, data: ByteArray) {
        if (data.isEmpty() || data.size > MAX_BYTES) {
            throw IOException("bad access unit size ${data.size}")
        }
        val head = ByteArray(13)
        putInt(head, 0, data.size)
        putLong(head, 4, ptsUs)
        head[12] = if (key) FLAG_KEYFRAME.toByte() else 0
        out.write(head)
        out.write(data)
        out.flush()
    }

    fun write(out: OutputStream, au: Au) = write(out, au.ptsUs, au.key, au.data)

    internal fun putInt(b: ByteArray, at: Int, v: Int) {
        b[at] = (v ushr 24).toByte()
        b[at + 1] = (v ushr 16).toByte()
        b[at + 2] = (v ushr 8).toByte()
        b[at + 3] = v.toByte()
    }

    internal fun putLong(b: ByteArray, at: Int, v: Long) {
        for (i in 0 until 8) b[at + i] = (v ushr (56 - 8 * i)).toByte()
    }
}

/**
 * The shell's half: reads access units off the reliable pipe until EOF. A
 * truncated record (the app died mid-write) is reported as [EOFException] and
 * ends the capture; nothing is retried.
 */
class CameraAuReader(private val input: InputStream) {

    /** The next record, or null at a clean EOF. */
    fun next(): CameraAu.Au? {
        val head = ByteArray(13)
        var read = 0
        while (read < head.size) {
            val n = input.read(head, read, head.size - read)
            if (n < 0) {
                if (read == 0) return null
                throw EOFException("truncated camera record header: $read of ${head.size}")
            }
            read += n
        }
        val len = readInt(head, 0)
        if (len <= 0 || len > CameraAu.MAX_BYTES) {
            throw IOException("bad camera record length $len")
        }
        val pts = readLong(head, 4)
        val flags = head[12].toInt() and 0xff
        val data = ByteArray(len)
        var at = 0
        while (at < len) {
            val n = input.read(data, at, len - at)
            if (n < 0) throw EOFException("truncated camera access unit: $at of $len")
            at += n
        }
        return CameraAu.Au(pts, flags and CameraAu.FLAG_KEYFRAME != 0, data)
    }

    private fun readInt(b: ByteArray, at: Int): Int =
        ((b[at].toInt() and 0xff) shl 24) or
            ((b[at + 1].toInt() and 0xff) shl 16) or
            ((b[at + 2].toInt() and 0xff) shl 8) or
            (b[at + 3].toInt() and 0xff)

    private fun readLong(b: ByteArray, at: Int): Long {
        var v = 0L
        for (i in 0 until 8) v = (v shl 8) or (b[at + i].toLong() and 0xff)
        return v
    }
}
