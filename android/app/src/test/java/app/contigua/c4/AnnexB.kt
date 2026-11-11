package app.contigua.c4

import java.io.ByteArrayOutputStream

/** Splits a raw Annex-B H.264 byte stream into a config blob and access units. */
object AnnexB {

    data class Access(val key: Boolean, val data: ByteArray)
    data class Stream(val csd: ByteArray, val frames: List<Access>)

    private val START = byteArrayOf(0, 0, 0, 1)

    fun parse(bytes: ByteArray): Stream {
        val csd = ByteArrayOutputStream()
        val frames = ArrayList<Access>()
        val pending = ByteArrayOutputStream()
        for (nal in split(bytes)) {
            if (nal.isEmpty()) continue
            when (nal[0].toInt() and 0x1F) {
                7, 8 -> { // SPS / PPS
                    csd.write(START)
                    csd.write(nal)
                }
                1, 5 -> { // non-IDR / IDR slice: one access unit (x264: one slice/frame)
                    pending.write(START)
                    pending.write(nal)
                    frames.add(Access(nal[0].toInt() and 0x1F == 5, pending.toByteArray()))
                    pending.reset()
                }
                6, 9 -> { // SEI / AUD: attach to the next access unit
                    pending.write(START)
                    pending.write(nal)
                }
                else -> Unit
            }
        }
        return Stream(csd.toByteArray(), frames)
    }

    private fun split(bytes: ByteArray): List<ByteArray> {
        val out = ArrayList<ByteArray>()
        var start = -1
        var i = 0
        while (i < bytes.size - 2) {
            if (bytes[i].toInt() == 0 && bytes[i + 1].toInt() == 0 && bytes[i + 2].toInt() == 1) {
                if (start >= 0) out.add(trim(bytes, start, i))
                start = i + 3
                i += 3
            } else {
                i++
            }
        }
        if (start in 0 until bytes.size) out.add(trim(bytes, start, bytes.size))
        return out
    }

    private fun trim(bytes: ByteArray, from: Int, to: Int): ByteArray {
        var end = to
        while (end > from && bytes[end - 1].toInt() == 0) end--
        return bytes.copyOfRange(from, end)
    }
}
