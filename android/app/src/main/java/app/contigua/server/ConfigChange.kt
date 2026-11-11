package app.contigua.server

/**
 * WIN-63: a VIDEO_CONFIG goes out only when the decoder needs a new one.
 *
 * With per-frame encoding statistics on (`KEY_VIDEO_ENCODING_STATISTICS_LEVEL`),
 * a Codec2 encoder (seen on a Qualcomm `c2.qti.avc.encoder`) attaches each
 * frame's QP average to that buffer's output format, so `dequeueOutputBuffer`
 * reports `INFO_OUTPUT_FORMAT_CHANGED` before almost every frame while the
 * parameter sets stay byte for byte the same. Each one used to go out as a
 * VIDEO_CONFIG; the Mac flushes its decoder and asks for a keyframe on every
 * config (WIN-62), so a moving picture became a keyframe storm at ~0 fps.
 *
 * One instance per encoder: the drain loop of a new encoder starts with a
 * fresh one, so its first format always goes out. Two states: nothing sent
 * yet, and the last format sent. A format equal to the last one in codec,
 * size, picture rect and parameter-set bytes is not sent again.
 */
internal class ConfigChange {

    private class Sent(val codec: Int, val width: Int, val height: Int, val picture: IntRect, val csd: ByteArray)

    private var last: Sent? = null

    /** True when this format must go out as a VIDEO_CONFIG; it is then the one remembered. */
    @Synchronized
    fun shouldSend(codec: Int, width: Int, height: Int, picture: IntRect, csd: ByteArray): Boolean {
        val prev = last
        if (prev != null && prev.codec == codec && prev.width == width && prev.height == height &&
            prev.picture == picture && prev.csd.contentEquals(csd)
        ) {
            return false
        }
        last = Sent(codec, width, height, picture, csd.copyOf())
        return true
    }
}
