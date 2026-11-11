package app.contigua.server

import kotlin.math.pow

/**
 * How capture undoes the remote-submix device's own music volume, which would
 * otherwise attenuate everything we stream.
 *
 * Preferred: set that device's index directly (per-device call), which can
 * never touch the speaker. Fallback: leave every volume alone and boost the
 * captured PCM by the attenuation the submix index applies. There is no path
 * that sets the music stream volume itself: that lands on whatever device
 * music is routed to at that instant, possibly the speaker.
 */
internal object SubmixLevel {

    /** Upper bound for the software fallback: 40 dB covers index ~5/15. */
    const val MAX_GAIN = 100f

    sealed interface Plan {
        /** The submix device is at max; capture is full scale. */
        data object DeviceSet : Plan
        /** Volumes untouched; multiply samples by [gain]. */
        data class SoftwareGain(val gain: Float) : Plan
    }

    /**
     * @param deviceVolumeSet the submix device index read back at max
     * @param submixDb attenuation of the submix device's current index in dB
     *   (≤ 0), null when unknown
     */
    fun plan(deviceVolumeSet: Boolean, submixDb: Float?): Plan = when {
        deviceVolumeSet -> Plan.DeviceSet
        submixDb == null || submixDb.isNaN() || submixDb >= 0f -> Plan.SoftwareGain(1f)
        else -> Plan.SoftwareGain(10f.pow(-submixDb / 20f).coerceAtMost(MAX_GAIN))
    }

    /** Applies [gain] to little-endian PCM16 in place, clipping at full scale. */
    fun applyGain(pcm: ByteArray, length: Int, gain: Float) {
        if (gain == 1f) return
        var i = 0
        while (i + 1 < length) {
            val s = (pcm[i].toInt() and 0xff) or (pcm[i + 1].toInt() shl 8)
            val v = (s * gain).toInt().coerceIn(Short.MIN_VALUE.toInt(), Short.MAX_VALUE.toInt())
            pcm[i] = v.toByte()
            pcm[i + 1] = (v shr 8).toByte()
            i += 2
        }
    }
}
