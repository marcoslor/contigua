package dev.pocketdeck.camera

import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.IOException

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The capture state machine on the JVM (K1): a fake camera, a fake encoder, a
 * fake pipe. The framing is read back with the shell's own reader.
 */
class CameraCaptureTest {

    private class RecordingSink : AuSink {
        val out = ByteArrayOutputStream()
        var closed = false
        var brokenAfter = Int.MAX_VALUE
        private var writes = 0

        override fun writeAu(ptsUs: Long, key: Boolean, data: ByteArray) {
            if (closed) throw IOException("closed")
            if (writes >= brokenAfter) throw IOException("broken pipe")
            writes++
            CameraAu.write(out, ptsUs, key, data)
        }

        override fun close() {
            closed = true
        }

        fun records(): List<CameraAu.Au> {
            val reader = CameraAuReader(ByteArrayInputStream(out.toByteArray()))
            val list = ArrayList<CameraAu.Au>()
            while (true) list.add(reader.next() ?: break)
            return list
        }
    }

    private class FakeEngine : CameraEngine {
        var starts = 0
        var stops = 0
        var listener: CameraEngine.Listener? = null
        var lastSpec: CameraSpec? = null

        override fun start(spec: CameraSpec, listener: CameraEngine.Listener) {
            starts++
            lastSpec = spec
            this.listener = listener
        }

        override fun stop() {
            stops++
        }

        fun streaming(w: Int = 1280, h: Int = 720) = listener!!.onStarted(w, h)

        fun frame(ptsUs: Long, key: Boolean, data: ByteArray) = listener!!.onFrame(ptsUs, key, data)

        fun state(state: CameraState, reason: String? = null) = listener!!.onState(state, reason)
    }

    private class Recorder {
        val events = ArrayList<Triple<Int, CameraState, String?>>()
        fun emit(stream: Int, state: CameraState, reason: String?) {
            events.add(Triple(stream, state, reason))
        }

        fun states() = events.map { it.second }
    }

    @Test
    fun startReportsStreamingAndWritesFramedAccessUnits() {
        val engine = FakeEngine()
        val sink = RecordingSink()
        val recorder = Recorder()
        val control = CameraControl(engine, sink, recorder::emit)

        assertTrue(control.start(CameraSpec(stream = 9), allowed = true))
        assertEquals(1, engine.starts)
        engine.streaming()
        engine.frame(1_000L, key = true, data = byteArrayOf(0, 0, 0, 1, 9))
        engine.frame(2_000L, key = false, data = byteArrayOf(0, 0, 0, 1, 7))

        assertEquals(listOf(CameraState.STREAMING), recorder.states())
        val records = sink.records()
        assertEquals(2, records.size)
        assertEquals(1_000L, records[0].ptsUs)
        assertTrue(records[0].key)
        assertArrayEquals(byteArrayOf(0, 0, 0, 1, 9), records[0].data)
        assertEquals(2_000L, records[1].ptsUs)
        assertFalse(records[1].key)
        assertArrayEquals(byteArrayOf(0, 0, 0, 1, 7), records[1].data)
    }

    @Test
    fun secondStartIsBusyAndDoesNotTouchTheLiveCapture() {
        val engine = FakeEngine()
        val sink = RecordingSink()
        val recorder = Recorder()
        val control = CameraControl(engine, sink, recorder::emit)

        assertTrue(control.start(CameraSpec(stream = 4), allowed = true))
        engine.streaming()
        assertFalse(control.start(CameraSpec(stream = 5), allowed = true))

        assertEquals(1, engine.starts)
        assertEquals(0, engine.stops)
        assertEquals(listOf(5), recorder.events.filter { it.second == CameraState.BUSY }.map { it.first })
        assertEquals(4, control.stream)
    }

    @Test
    fun evictionStopsOnceAndNeverRetries() {
        val engine = FakeEngine()
        val sink = RecordingSink()
        val recorder = Recorder()
        val control = CameraControl(engine, sink, recorder::emit)

        assertTrue(control.start(CameraSpec(stream = 2), allowed = true))
        engine.streaming()
        engine.state(CameraState.EVICTED, "onDisconnected")

        assertEquals(listOf(CameraState.STREAMING, CameraState.EVICTED), recorder.states())
        assertEquals(1, engine.stops)
        assertTrue(sink.closed)
        assertNull(control.stream)
        assertEquals(1, engine.starts) // no retry
    }

    @Test
    fun pipeLossStopsTheCapture() {
        val engine = FakeEngine()
        val sink = RecordingSink().apply { brokenAfter = 1 }
        val recorder = Recorder()
        val control = CameraControl(engine, sink, recorder::emit)

        assertTrue(control.start(CameraSpec(stream = 3), allowed = true))
        engine.streaming()
        engine.frame(1L, key = true, data = byteArrayOf(1))
        engine.frame(2L, key = false, data = byteArrayOf(2))

        val stop = recorder.events.last()
        assertEquals(3, stop.first)
        assertEquals(CameraState.STOPPED, stop.second)
        assertEquals("pipe", stop.third)
        assertEquals(1, engine.stops)
        assertNull(control.stream)
    }

    @Test
    fun consentOffRefusesBeforeTheEngineStarts() {
        val engine = FakeEngine()
        val sink = RecordingSink()
        val recorder = Recorder()
        val control = CameraControl(engine, sink, recorder::emit)

        assertFalse(control.start(CameraSpec(stream = 8), allowed = false))
        assertEquals(0, engine.starts)
        assertEquals(listOf(CameraState.OFF), recorder.states())
    }

    @Test
    fun stopReportsStoppedOnce() {
        val engine = FakeEngine()
        val sink = RecordingSink()
        val recorder = Recorder()
        val control = CameraControl(engine, sink, recorder::emit)

        assertTrue(control.start(CameraSpec(stream = 1), allowed = true))
        engine.streaming()
        control.stop("requested")
        control.stop("again")

        assertEquals(listOf(CameraState.STREAMING, CameraState.STOPPED), recorder.states())
        assertEquals(1, engine.stops)
    }

    // ---- the wire shapes -------------------------------------------------

    @Test
    fun startRequestParsesDefaultsAndClampsToTheCaps() {
        val spec = CameraSpec.fromJson("""{"stream":12}""")
        assertNotNull(spec)
        assertEquals(12, spec!!.stream)
        assertNull(spec.cameraId)
        assertEquals(CameraSpec.DEFAULT_W, spec.w)
        assertEquals(CameraSpec.DEFAULT_H, spec.h)
        assertEquals(CameraSpec.DEFAULT_FPS, spec.fps)

        val capped = CameraSpec.fromJson(
            """{"stream":12,"id":"1","w":4000,"h":4000,"fps":120}""",
        )!!
        assertEquals("1", capped.cameraId)
        assertEquals(CameraSpec.MAX_W, capped.w)
        assertEquals(CameraSpec.MAX_H, capped.h)
        assertEquals(CameraSpec.MAX_FPS, capped.fps)

        assertNull(CameraSpec.fromJson("""{"w":1280}"""))
        assertNull(CameraSpec.fromJson("not json"))
    }

    @Test
    fun stateRelayKeepsTheWireShape() {
        val json = CameraMessages.state(7, CameraState.EVICTED, "onDisconnected")
        val obj = dev.pocketdeck.proto.Json.parseObject(json)
        assertEquals(7, dev.pocketdeck.proto.Json.int(obj["stream"]))
        assertEquals("evicted", dev.pocketdeck.proto.Json.str(obj["state"]))
        assertEquals("onDisconnected", dev.pocketdeck.proto.Json.str(obj["reason"]))

        val wire = CameraMessages.wireState(7, "evicted", "onDisconnected")
        assertEquals("cam.state", wire["t"])
        assertEquals(7, wire["stream"])
        assertEquals("evicted", wire["state"])

        val quiet = CameraMessages.state(7, CameraState.STOPPED, null)
        assertFalse(dev.pocketdeck.proto.Json.parseObject(quiet).containsKey("reason"))
    }

    @Test
    fun gateMessageCarriesTheCams() {
        val json = CameraMessages.gate(
            allowed = true,
            cams = listOf(CameraInfo("0", "back", 1920, 1080), CameraInfo("1", "front", 1280, 720)),
        )
        val obj = dev.pocketdeck.proto.Json.parseObject(json)
        assertEquals(true, dev.pocketdeck.proto.Json.bool(obj["allowed"]))
        val cams = CameraInfo.list(obj["cams"])
        assertEquals(2, cams.size)
        assertEquals("front", cams[1].facing)
        assertEquals(1920, cams[0].w)
    }
}
