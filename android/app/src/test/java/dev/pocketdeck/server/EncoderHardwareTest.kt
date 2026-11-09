package dev.pocketdeck.server

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The hardware rule for an HEVC encoder: API 29+ asks the platform, older
 * releases know only the name, where the platform's software encoders share
 * `OMX.google.` / `c2.android.`.
 */
class EncoderHardwareTest {

    @Test
    fun api28NamesThePlatformsSoftwareEncoders() {
        assertFalse(EncoderHardware.isHardware("OMX.google.hevc.encoder", 28, null))
        assertFalse(EncoderHardware.isHardware("c2.android.hevc.encoder", 28, null))
    }

    @Test
    fun api28AcceptsAVendorsEncoder() {
        assertTrue(EncoderHardware.isHardware("OMX.qcom.video.encoder.hevc", 28, null))
        assertTrue(EncoderHardware.isHardware("c2.qti.hevc.encoder", 28, null))
    }

    @Test
    fun api29UsesThePlatformsAnswer() {
        assertTrue(EncoderHardware.isHardware("anything", 29, hardwareAccelerated = true))
        assertFalse(EncoderHardware.isHardware("OMX.qcom.video.encoder.hevc", 29, false))
        assertFalse("an absent answer is never hardware", EncoderHardware.isHardware("x", 33, null))
    }

    @Test
    fun anEmptyNameOnApi28IsNotASoftwarePrefix() {
        assertTrue(EncoderHardware.isHardware("", 28, null))
    }
}
