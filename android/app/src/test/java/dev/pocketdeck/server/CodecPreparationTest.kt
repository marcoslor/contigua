package dev.pocketdeck.server

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The prepare flow with a fake encoder factory: HEVC is tried by default, a
 * failing HEVC build retries once with H.264, and the process remembers it so
 * the next stream goes straight to AVC.
 */
class CodecPreparationTest {

    private val avc = setOf(VideoCodec.Avc)
    private val both = setOf(VideoCodec.Avc, VideoCodec.Hevc)

    private class FakeEncoder(val kind: VideoCodec) {
        var started = false
        var released = false
    }

    private class Factory {
        val created = mutableListOf<FakeEncoder>()
        val kinds: List<VideoCodec> get() = created.map { it.kind }
    }

    private fun hardware(probes: IntArray): HevcCodecState = HevcCodecState {
        probes[0]++
        HevcCodecState.Probe.Hardware { _, _ -> true }
    }

    private fun prepare(
        state: HevcCodecState,
        strategy: StreamStrategy = StreamStrategy(codec = VideoCodec.Hevc),
        macCodecs: Set<VideoCodec> = both,
        factory: Factory = Factory(),
        lines: MutableList<String> = mutableListOf(),
        configure: (FakeEncoder) -> Unit = {},
        start: (FakeEncoder) -> Unit = { it.started = true },
    ): CodecPreparation.Ready<FakeEncoder, FakeEncoder>? =
        CodecPreparation.prepare(
            strategy = strategy,
            macCodecs = macCodecs,
            size = IntSize(1280, 720),
            state = state,
            label = "1280x720",
            create = { kind -> FakeEncoder(kind).also { factory.created += it } },
            build = { encoder, _ -> configure(encoder); start(encoder); encoder },
            release = { it.released = true },
            log = { lines += it },
        )

    @Test
    fun aFailingHevcConfigureRetriesAvcOnceAndTheNextStreamSkipsHevc() {
        val probes = intArrayOf(0)
        val state = hardware(probes)
        val factory = Factory()
        val lines = mutableListOf<String>()

        val first = prepare(
            state = state,
            factory = factory,
            lines = lines,
            configure = { if (it.kind == VideoCodec.Hevc) error("boom") },
        )

        assertEquals(VideoCodec.Avc, first?.kind)
        assertTrue(first?.built?.started == true)
        assertEquals(listOf(VideoCodec.Hevc, VideoCodec.Avc), factory.kinds)
        assertTrue(factory.created.first().released)
        assertEquals(1, probes[0])
        assertTrue(lines.contains("hevc: unknown --probe--> available"))
        assertTrue(lines.contains("hevc: available --configure--> unavailable(configure)"))
        assertTrue(lines.contains("codec=hevc unsupported: configure"))
        assertTrue("the old failing-size line is not written for HEVC",
                   lines.none { it.startsWith("encoder for") })

        val second = prepare(
            state = state,
            factory = factory,
            lines = lines,
            configure = { if (it.kind == VideoCodec.Hevc) error("boom") },
        )

        assertEquals(VideoCodec.Avc, second?.kind)
        assertEquals(
            "the second stream creates AVC only",
            listOf(VideoCodec.Hevc, VideoCodec.Avc, VideoCodec.Avc),
            factory.kinds,
        )
        assertEquals("no second probe", 1, probes[0])
    }

    @Test
    fun aFailingHevcStartTakesTheSameFallback() {
        val probes = intArrayOf(0)
        val factory = Factory()
        val lines = mutableListOf<String>()

        val ready = prepare(
            state = hardware(probes),
            factory = factory,
            lines = lines,
            start = { if (it.kind == VideoCodec.Hevc) error("boom") },
        )

        assertEquals(VideoCodec.Avc, ready?.kind)
        assertEquals(listOf(VideoCodec.Hevc, VideoCodec.Avc), factory.kinds)
        assertTrue(lines.contains("codec=hevc unsupported: configure"))
    }

    @Test
    fun theAvcPathKeepsTheOldFailureLines() {
        val probes = intArrayOf(0)
        val lines = mutableListOf<String>()
        val ready = prepare(
            state = hardware(probes),
            strategy = StreamStrategy(codec = VideoCodec.Avc),
            lines = lines,
            configure = { error("boom") },
        )
        assertNull(ready)
        assertTrue(lines.contains("encoder for 1280x720 failed: boom"))
        assertEquals("a forced AVC never probes HEVC", 0, probes[0])
    }

    @Test
    fun aMissingAvcEncoderNamesItself() {
        val lines = mutableListOf<String>()
        val ready = CodecPreparation.prepare(
            strategy = StreamStrategy(codec = VideoCodec.Avc),
            macCodecs = avc,
            size = IntSize(1280, 720),
            state = hardware(intArrayOf(0)),
            label = "1280x720",
            create = { error("nope") },
            build = { _, _ -> Unit },
            release = {},
            log = { lines += it },
        )
        assertNull(ready)
        assertTrue(lines.contains("no avc encoder: nope"))
    }

    @Test
    fun aMacWithoutHevcNeverProbesAndNamesMac() {
        val probes = intArrayOf(0)
        val factory = Factory()
        val lines = mutableListOf<String>()
        val ready = prepare(
            state = hardware(probes),
            macCodecs = avc,
            factory = factory,
            lines = lines,
        )
        assertEquals(VideoCodec.Avc, ready?.kind)
        assertEquals(listOf(VideoCodec.Avc), factory.kinds)
        assertEquals(0, probes[0])
        assertTrue(lines.contains("codec=hevc unsupported: mac"))
    }

    @Test
    fun aSoftwareHevcIsTheEncoderFallback() {
        val lines = mutableListOf<String>()
        val factory = Factory()
        val state = HevcCodecState { HevcCodecState.Probe.Software }
        val ready = prepare(state = state, factory = factory, lines = lines)
        assertEquals(VideoCodec.Avc, ready?.kind)
        assertEquals(listOf(VideoCodec.Avc), factory.kinds)
        assertTrue(lines.contains("hevc: unknown --probe--> unavailable(encoder)"))
        assertTrue(lines.contains("codec=hevc unsupported: encoder"))
    }
}
