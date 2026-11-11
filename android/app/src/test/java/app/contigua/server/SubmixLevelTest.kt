package app.contigua.server

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Submix level decision: a successful per-device set wins; otherwise volumes
 * stay untouched and the PCM is boosted by the submix attenuation, bounded
 * and clipped.
 */
class SubmixLevelTest {

    @Test
    fun `per-device set means no software gain`() {
        assertEquals(SubmixLevel.Plan.DeviceSet, SubmixLevel.plan(deviceVolumeSet = true, submixDb = -32f))
    }

    @Test
    fun `fallback undoes the submix attenuation`() {
        val plan = SubmixLevel.plan(deviceVolumeSet = false, submixDb = -20f)
        assertTrue(plan is SubmixLevel.Plan.SoftwareGain)
        assertEquals(10f, (plan as SubmixLevel.Plan.SoftwareGain).gain, 0.01f)
    }

    @Test
    fun `unknown or full-scale attenuation means unity gain`() {
        assertEquals(SubmixLevel.Plan.SoftwareGain(1f), SubmixLevel.plan(false, null))
        assertEquals(SubmixLevel.Plan.SoftwareGain(1f), SubmixLevel.plan(false, 0f))
        assertEquals(SubmixLevel.Plan.SoftwareGain(1f), SubmixLevel.plan(false, Float.NaN))
    }

    @Test
    fun `gain is capped`() {
        val plan = SubmixLevel.plan(false, -96f) as SubmixLevel.Plan.SoftwareGain
        assertEquals(SubmixLevel.MAX_GAIN, plan.gain, 0f)
    }

    @Test
    fun `applyGain scales and clips pcm16`() {
        fun pcm(vararg s: Int) = ByteArray(s.size * 2).also { b ->
            s.forEachIndexed { i, v -> b[2 * i] = v.toByte(); b[2 * i + 1] = (v shr 8).toByte() }
        }
        fun samples(b: ByteArray) = (0 until b.size / 2).map { (b[2 * it].toInt() and 0xff) or (b[2 * it + 1].toInt() shl 8) }
        val b = pcm(100, -100, 20000, -20000)
        SubmixLevel.applyGain(b, b.size, 2f)
        assertEquals(listOf(200, -200, 32767, -32768), samples(b))
    }
}
