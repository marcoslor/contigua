package dev.pocketdeck.camera

import org.junit.Assert.assertEquals
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

/**
 * The encoder seam on the JVM (K1): the call order MediaCodec requires for a
 * surface-input encoder, and the release that keeps a failed configure/start
 * from leaking the native codec. This is the order the emulator boot showed
 * `start` before `createInputSurface` breaking with a CodecException.
 */
class CameraEncoderOrderTest {

    /** Records the calls; fails at [failAt] (`create`, `configure`, `input_surface`, `start`). */
    private class FakeCodec(private val failAt: String? = null) : SurfaceCodec {
        val calls = ArrayList<String>()
        val handle = Any()
        val surface = Any()
        var released = 0

        private fun record(step: String) {
            calls.add(step)
            if (step == failAt) throw IllegalStateException("refused at $step")
        }

        override fun create(): Any {
            record(EncoderSetup.CREATE)
            return handle
        }

        override fun configure(codec: Any) = record(EncoderSetup.CONFIGURE)

        override fun createInputSurface(codec: Any): Any {
            record(EncoderSetup.INPUT_SURFACE)
            return surface
        }

        override fun start(codec: Any) = record(EncoderSetup.START)

        override fun release(codec: Any) {
            released++
            assertSame(handle, codec)
        }
    }

    private fun failure(codec: FakeCodec): CodecSetupException {
        try {
            EncoderSetup.start(codec)
            fail("expected CodecSetupException")
            throw AssertionError()
        } catch (e: CodecSetupException) {
            return e
        }
    }

    @Test
    fun `the input surface is created before start`() {
        val codec = FakeCodec()
        val started = EncoderSetup.start(codec)
        assertEquals(
            listOf(EncoderSetup.CREATE, EncoderSetup.CONFIGURE, EncoderSetup.INPUT_SURFACE, EncoderSetup.START),
            codec.calls,
        )
        assertSame(codec.handle, started.codec)
        assertSame(codec.surface, started.surface)
        assertEquals(0, codec.released)
    }

    @Test
    fun `a failed start releases the codec and names the step`() {
        val codec = FakeCodec(failAt = EncoderSetup.START)
        val e = failure(codec)
        assertEquals(EncoderSetup.START, e.step)
        assertTrue(e.refused is IllegalStateException)
        assertEquals(1, codec.released)
    }

    @Test
    fun `a refused input surface releases the codec`() {
        val codec = FakeCodec(failAt = EncoderSetup.INPUT_SURFACE)
        val e = failure(codec)
        assertEquals(EncoderSetup.INPUT_SURFACE, e.step)
        assertEquals(1, codec.released)
    }

    @Test
    fun `a failed configure releases the codec`() {
        val codec = FakeCodec(failAt = EncoderSetup.CONFIGURE)
        val e = failure(codec)
        assertEquals(EncoderSetup.CONFIGURE, e.step)
        assertEquals(1, codec.released)
    }

    @Test
    fun `a failed create has nothing to release`() {
        val codec = FakeCodec(failAt = EncoderSetup.CREATE)
        val e = failure(codec)
        assertEquals(EncoderSetup.CREATE, e.step)
        assertEquals(0, codec.released)
    }
}
