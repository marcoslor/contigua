package dev.pocketdeck.server

/**
 * P3's per-direction replay window (PATH-26). One `u64` sequence space covers
 * every datagram type; a sequence is accepted once, and only while it is
 * inside the last [size] packets. Sizing is the cap's job:
 * [MediaCrypto.requiredReplayWindow] at one second, 1024 at the shipped
 * 8 Mbit/s (≈1.17 s).
 */
class MediaReplayWindow(private val size: Int = DEFAULT_SIZE) {
    init {
        require(size in 64..65_536 && size % 64 == 0) { "window" }
    }

    private val words = LongArray(size / 64)
    private var highest = 0L

    /** True exactly once per sequence; old and duplicate sequences are false. */
    fun accept(seq: Long): Boolean {
        if (seq <= 0) return false
        if (highest == 0L) {
            highest = seq
            set(seq)
            return true
        }
        if (seq > highest) {
            if (seq - highest >= size) {
                words.fill(0)
            } else {
                var s = highest + 1
                while (s <= seq) {
                    clear(s)
                    s++
                }
            }
            highest = seq
            set(seq)
            return true
        }
        if (highest - seq >= size) return false
        if (get(seq)) return false
        set(seq)
        return true
    }

    /** The highest accepted sequence, 0 before the first. */
    fun highest(): Long = highest

    private fun slot(seq: Long): Int = (seq % size).toInt()

    private fun set(seq: Long) {
        val s = slot(seq)
        words[s / 64] = words[s / 64] or (1L shl (s % 64))
    }

    private fun clear(seq: Long) {
        val s = slot(seq)
        words[s / 64] = words[s / 64] and (1L shl (s % 64)).inv()
    }

    private fun get(seq: Long): Boolean {
        val s = slot(seq)
        return words[s / 64] and (1L shl (s % 64)) != 0L
    }

    companion object {
        const val DEFAULT_SIZE = 1024
        /** The shipped window; the cap test keeps these two in step. */
        val SHIPPED = DEFAULT_SIZE
    }
}
