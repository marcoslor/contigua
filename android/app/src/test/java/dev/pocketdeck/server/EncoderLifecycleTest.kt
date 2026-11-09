package dev.pocketdeck.server

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The encoder/display lifecycle, pinned as one machine: the calls the stream
 * makes in each state, the events that leave it untouched, and the field-log
 * path. The fake stream below performs the returned actions exactly as
 * `WindowStream` does (a fake codec seam: build, start on the shared surface,
 * attach, detach, release), so a sequence here is the sequence on the phone.
 */
class EncoderLifecycleTest {

    private val size = IntSize(1280, 720)

    /** A stream's side of the contract, backed by counted slots instead of MediaCodec. */
    private class FakeStream(
        private val surfaceWorks: Boolean = false,
        /** Starts to refuse on the shared surface before one succeeds. */
        startRefusals: Int = 0,
        private val suspendApplied: Boolean = true,
    ) {
        val calls = ArrayList<String>()
        val lines = ArrayList<String>()
        val lifecycle = EncoderLifecycle(stream = 3) { lines += it }
        val state: EncoderState get() = lifecycle.state

        var displayed = DisplayPhase.None
        var encoder = false
        var previous = false
        var persistent = false
        var prepared = false
        var preparedStarted = false
        var width = 0
        var height = 0
        var failBuilds = 0
        var startRefusals = startRefusals
        /** Set by the build: the fake codec kind, for the HEVC pin below. */
        var builtKind = VideoCodec.Avc
        var attachedInPlan = false

        val keyGate = KeyRequestGate()

        fun open(display: DisplayPhase, size: IntSize) {
            run(lifecycle.dispatch(EncoderEvent.Open(display, size)))
        }

        fun pause() {
            run(lifecycle.dispatch(EncoderEvent.Pause))
        }

        fun resume() {
            run(lifecycle.dispatch(EncoderEvent.Resume))
        }

        fun suspend(on: Boolean) {
            run(lifecycle.dispatch(EncoderEvent.Suspend(on)))
        }

        fun close() {
            run(lifecycle.dispatch(EncoderEvent.Release))
        }

        /** The sequencer's `prepare`: one build at [asked]. */
        fun prepare(asked: IntSize): IntSize? {
            builtSize = null
            run(lifecycle.dispatch(EncoderEvent.Prepare(asked)))
            return builtSize
        }

        /** The sequencer's `attachPrepared`: true when an encoder ended attached. */
        fun attachPrepared(): Boolean {
            if (!prepared) return false
            attachedInPlan = false
            run(lifecycle.dispatch(EncoderEvent.Attach))
            return attachedInPlan
        }

        fun releasePrevious() {
            run(lifecycle.dispatch(EncoderEvent.ReleasePrevious))
        }

        private var builtSize: IntSize? = null

        private fun run(actions: List<EncoderAction>) {
            val pending = ArrayDeque<EncoderAction>()
            for (action in actions) pending.addLast(action)
            while (pending.isNotEmpty()) {
                val outcome = perform(pending.removeFirst()) ?: continue
                val next = lifecycle.dispatch(outcome)
                next.asReversed().forEach { pending.addFirst(it) }
            }
        }

        private fun perform(action: EncoderAction): EncoderEvent? = when (action) {
            EncoderAction.CreateSurface -> {
                calls += "create-surface"
                persistent = surfaceWorks
                EncoderEvent.SurfaceReady(persistent)
            }
            is EncoderAction.Build -> {
                calls += "build ${action.size.w}x${action.size.h}${if (action.attach) " attach" else ""}"
                builtSize = action.size
                width = action.size.w
                height = action.size.h
                if (failBuilds > 0) {
                    failBuilds--
                    prepared = false
                    builtSize = null
                    EncoderEvent.BuildFailed
                } else {
                    prepared = true
                    preparedStarted = !persistent
                    EncoderEvent.Built(preparedStarted, action.attach)
                }
            }
            EncoderAction.StartPrepared -> {
                calls += "start-prepared"
                if (startRefusals > 0) {
                    startRefusals--
                    prepared = false
                    EncoderEvent.StartRefused(IntSize(width, height))
                } else {
                    preparedStarted = true
                    EncoderEvent.Started
                }
            }
            EncoderAction.DropSurface -> {
                calls += "drop-surface"
                persistent = false
                null
            }
            is EncoderAction.CreateDisplay -> {
                calls += "create-display ${action.display.wire}"
                displayed = action.display
                EncoderEvent.Created
            }
            EncoderAction.AttachFresh -> {
                calls += "attach-fresh"
                takePrepared()
                encoder = true
                keyGate.reset()
                EncoderEvent.Installed(suspended = state.suspended)
            }
            is EncoderAction.Attach -> {
                calls += "attach persistent=${action.persistent}"
                takePrepared()
                encoder = true
                keyGate.reset()
                attachedInPlan = true
                EncoderEvent.Installed(suspended = state.suspended)
            }
            EncoderAction.Swap -> {
                calls += "swap"
                val had = encoder
                previous = had
                takePrepared()
                encoder = true
                keyGate.reset()
                attachedInPlan = true
                EncoderEvent.Swapped(suspended = state.suspended, previous = had)
            }
            EncoderAction.DetachOld -> {
                calls += "detach-old"
                encoder = false
                null
            }
            EncoderAction.Detach -> {
                calls += "detach"
                encoder = false
                null
            }
            EncoderAction.ReleasePrepared -> {
                calls += "release-prepared"
                prepared = false
                null
            }
            EncoderAction.ReleasePreviousCodec -> {
                calls += "release-previous-codec"
                previous = false
                null
            }
            EncoderAction.ReleaseDisplay -> {
                calls += "release-display"
                displayed = DisplayPhase.None
                null
            }
            EncoderAction.ReleaseSurface -> {
                calls += "release-surface"
                persistent = false
                null
            }
            EncoderAction.ResendConfig -> {
                calls += "resend-config"
                null
            }
            EncoderAction.RequestKey -> {
                calls += "request-key"
                null
            }
            EncoderAction.Nudge -> {
                calls += "nudge"
                null
            }
            is EncoderAction.ApplySuspend -> {
                calls += "apply-suspend ${action.suspended}"
                EncoderEvent.SuspendApplied(action.suspended, suspendApplied)
            }
            EncoderAction.Rebuild -> {
                calls += "rebuild"
                // The sequencer's resume: fit (n/a here), build, attach, release.
                prepare(IntSize(width, height))
                attachPrepared()
                releasePrevious()
                null
            }
        }

        private fun takePrepared() {
            prepared = false
            preparedStarted = false
        }
    }

    private fun draining(fake: FakeStream) {
        fake.open(DisplayPhase.Virtual, size)
        assertEquals(EncoderPhase.Attached, fake.state.phase)
    }

    // ------------------------------------------------------------------ open

    @Test
    fun `an app window opens on its own surface and drains`() {
        val fake = FakeStream(surfaceWorks = false)
        fake.open(DisplayPhase.Virtual, size)

        assertEquals(
            listOf("create-surface", "build 1280x720", "create-display virtual", "attach-fresh"),
            fake.calls,
        )
        assertEquals(EncoderPhase.Attached, fake.state.phase)
        assertEquals(DisplayPhase.Virtual, fake.state.display)
        assertTrue(fake.encoder)
        assertFalse(fake.state.persistent)
    }

    @Test
    fun `a shared surface that starts becomes the display's one surface`() {
        val fake = FakeStream(surfaceWorks = true)
        fake.open(DisplayPhase.Virtual, size)

        assertEquals(
            listOf("create-surface", "build 1280x720", "start-prepared", "create-display virtual",
                "attach-fresh"),
            fake.calls,
        )
        assertTrue(fake.state.persistent)
        assertEquals(EncoderPhase.Attached, fake.state.phase)
    }

    @Test
    fun `a shared surface the encoder refuses is dropped and the stream reopens on its own surface`() {
        val fake = FakeStream(surfaceWorks = true, startRefusals = 1)
        fake.open(DisplayPhase.Virtual, size)

        assertEquals(
            listOf("create-surface", "build 1280x720", "start-prepared", "drop-surface",
                "build 1280x720", "create-display virtual", "attach-fresh"),
            fake.calls,
        )
        assertFalse(fake.state.persistent)
        assertEquals(EncoderPhase.Attached, fake.state.phase)
        // The second build has its own surface and is started, so it is not
        // asked to start on the shared one again.
        assertEquals(1, fake.calls.count { it == "start-prepared" })
    }

    @Test
    fun `a mirror opens without a shared surface`() {
        val fake = FakeStream()
        fake.open(DisplayPhase.Mirror, size)

        assertEquals(
            listOf("build 1280x720", "create-display mirror", "attach-fresh"),
            fake.calls,
        )
        assertEquals(DisplayPhase.Mirror, fake.state.display)
    }

    // ------------------------------------------------------------------ hold

    @Test
    fun `pause keeps a shared-surface encoder and detaches a lone one`() {
        val shared = FakeStream(surfaceWorks = true)
        draining(shared)
        shared.pause()

        assertEquals(EncoderPhase.Attached, shared.state.phase)
        assertTrue(shared.state.paused)
        assertTrue("the encoder keeps running", shared.encoder)

        val lone = FakeStream(surfaceWorks = false)
        draining(lone)
        lone.pause()

        assertTrue(lone.state.paused)
        assertFalse("no shared surface, the encoder is detached", lone.encoder)
        assertEquals("detach", lone.calls.last())
    }

    @Test
    fun `resume with a shared-surface encoder re-sends the config and asks for a key`() {
        val fake = FakeStream(surfaceWorks = true)
        draining(fake)
        fake.pause()
        fake.calls.clear()
        fake.resume()

        assertEquals(listOf("resend-config", "request-key", "nudge"), fake.calls)
        assertFalse(fake.state.paused)
        assertEquals(EncoderPhase.Attached, fake.state.phase)
    }

    @Test
    fun `resume without a shared-surface encoder rebuilds it`() {
        val fake = FakeStream(surfaceWorks = false)
        draining(fake)
        fake.pause()
        fake.calls.clear()
        fake.resume()

        assertEquals(
            listOf("rebuild", "build 1280x720", "swap"),
            fake.calls,
        )
        assertEquals(EncoderPhase.Attached, fake.state.phase)
        assertTrue(fake.encoder)
    }

    @Test
    fun `a paused stream that lost its encoder rebuilds on resume`() {
        // The failed swap below leaves the display and no encoder.
        val fake = failedSwap()
        assertTrue(fake.state.paused)
        fake.calls.clear()
        fake.resume()

        assertEquals(
            listOf("rebuild", "build 960x540", "swap"),
            fake.calls,
        )
        assertEquals(EncoderPhase.Attached, fake.state.phase)
        assertTrue(fake.encoder)
    }

    // ------------------------------------------------------------------ resize

    @Test
    fun `a resize swaps in the next encoder and releases the old one`() {
        val fake = FakeStream(surfaceWorks = false)
        draining(fake)
        fake.calls.clear()

        assertEquals(IntSize(960, 540), fake.prepare(IntSize(960, 540)))
        assertTrue(fake.attachPrepared())
        fake.releasePrevious()

        assertEquals(listOf("build 960x540", "swap", "release-previous-codec"), fake.calls)
        assertEquals(EncoderPhase.Attached, fake.state.phase)
        assertFalse(fake.state.previous)
    }

    @Test
    fun `a resize while paused keeps the pause`() {
        val fake = FakeStream(surfaceWorks = true)
        draining(fake)
        fake.pause()
        fake.calls.clear()

        fake.prepare(IntSize(960, 540))
        assertTrue(fake.attachPrepared())
        fake.releasePrevious()

        assertEquals(
            listOf("build 960x540", "detach-old", "start-prepared", "attach persistent=true"),
            fake.calls,
        )
        assertEquals(EncoderPhase.Attached, fake.state.phase)
        assertTrue("the window is still covered", fake.state.paused)
        assertFalse(fake.state.previous)
    }

    @Test
    fun `a failed prepare mid-resize keeps the old encoder`() {
        val fake = FakeStream(surfaceWorks = false)
        draining(fake)
        fake.failBuilds = 1
        fake.calls.clear()

        assertEquals(null, fake.prepare(IntSize(960, 540)))
        assertEquals(listOf("build 960x540"), fake.calls)
        assertEquals(EncoderPhase.Attached, fake.state.phase)
        assertTrue("the running encoder is untouched", fake.encoder)
        assertFalse(fake.state.prepared)
    }

    @Test
    fun `a failed start mid-resize rebuilds on the encoder's own surface`() {
        val fake = FakeStream(surfaceWorks = true)
        draining(fake)
        fake.calls.clear()
        fake.startRefusals = 1

        fake.prepare(IntSize(960, 540))
        assertTrue(fake.attachPrepared())
        fake.releasePrevious()

        assertEquals(
            listOf("build 960x540", "detach-old", "start-prepared", "drop-surface",
                "build 960x540 attach", "attach persistent=false"),
            fake.calls,
        )
        assertEquals(EncoderPhase.Attached, fake.state.phase)
        assertTrue(fake.encoder)
    }

    @Test
    fun `a failed rebuild mid-resize leaves the stream empty`() {
        val fake = FakeStream(surfaceWorks = true)
        draining(fake)
        fake.startRefusals = 1
        fake.prepare(IntSize(960, 540))
        fake.failBuilds = 1
        fake.calls.clear()

        assertFalse("the sequencer is told the attach failed", fake.attachPrepared())

        assertEquals(
            listOf("detach-old", "start-prepared", "drop-surface", "build 960x540 attach"),
            fake.calls,
        )
        assertEquals(EncoderPhase.Empty, fake.state.phase)
        assertFalse(fake.encoder)
        assertFalse(fake.state.prepared)
    }

    @Test
    fun `a resize recovers a stream left empty by a failed swap`() {
        val fake = failedSwap(pause = false)
        fake.calls.clear()

        fake.prepare(IntSize(1024, 768))
        assertTrue(fake.attachPrepared())
        fake.releasePrevious()

        assertEquals(listOf("build 1024x768", "swap"), fake.calls)
        assertEquals(EncoderPhase.Attached, fake.state.phase)
    }

    // ------------------------------------------------------------------ suspend

    @Test
    fun `suspend stops and resumes input, and a refused suspend leaves it flowing`() {
        val fake = FakeStream(surfaceWorks = true)
        draining(fake)

        fake.suspend(true)
        assertEquals("apply-suspend true", fake.calls.last())
        assertTrue(fake.state.suspended)

        fake.suspend(false)
        assertEquals("apply-suspend false", fake.calls.last())
        assertFalse(fake.state.suspended)

        val refused = FakeStream(surfaceWorks = true, suspendApplied = false)
        draining(refused)
        refused.suspend(true)
        assertFalse(refused.state.suspended)
        assertEquals(EncoderPhase.Attached, refused.state.phase)
    }

    @Test
    fun `a suspend outlives a pause and a rebuild`() {
        val lone = FakeStream(surfaceWorks = false)
        draining(lone)
        lone.suspend(true)
        lone.pause()
        assertFalse("pause detached the encoder", lone.encoder)
        assertTrue(lone.state.suspended)
        lone.resume()
        assertEquals(EncoderPhase.Attached, lone.state.phase)
        assertTrue("the rebuilt encoder is suspended again", lone.state.suspended)
    }

    // ------------------------------------------------------------------ release

    @Test
    fun `release closes every slot and the display`() {
        val fake = FakeStream(surfaceWorks = true)
        draining(fake)
        fake.close()

        assertEquals(
            listOf("detach", "release-prepared", "release-display", "release-surface"),
            fake.calls.takeLast(4),
        )
        assertEquals(EncoderPhase.Released, fake.state.phase)
        assertFalse(fake.encoder)
        assertEquals(DisplayPhase.None, fake.displayed)
    }

    // ------------------------------------------------------------------ log

    @Test
    fun `the field log names the phase path`() {
        val fake = FakeStream(surfaceWorks = true, startRefusals = 1)
        fake.open(DisplayPhase.Virtual, size)
        fake.pause()
        fake.resume()

        assertEquals(
            listOf(
                "stream 3 encoder: empty --open--> opening",
                "stream 3 encoder: opening --built--> prepared",
                "stream 3 encoder: prepared --start-refused--> opening",
                "stream 3 encoder: opening --built--> prepared",
                "stream 3 encoder: prepared --created--> draining",
                "stream 3 display: none --created--> virtual",
                "stream 3 encoder: draining --pause--> paused",
                "stream 3 encoder: paused --resume--> swapping",
                "stream 3 encoder: swapping --built--> prepared",
                "stream 3 encoder: prepared --attach--> draining",
            ),
            fake.lines,
        )
    }

    // ------------------------------------------------------------------ edges

    @Test
    fun `ignored events leave their state alone`() {
        val open = EncoderState(phase = EncoderPhase.Opening, pendingDisplay = DisplayPhase.Virtual)
        assertIgnored(open, EncoderEvent.Created)
        assertIgnored(open, EncoderEvent.Pause)
        assertIgnored(open, EncoderEvent.Resume)

        val draining = EncoderState(phase = EncoderPhase.Attached, persistent = true)
        assertIgnored(draining, EncoderEvent.Open(DisplayPhase.Virtual, size))
        assertIgnored(draining, EncoderEvent.Resume)
        assertIgnored(draining, EncoderEvent.ReleasePrevious)
        assertIgnored(draining, EncoderEvent.Created)
        assertIgnored(draining, EncoderEvent.Attach)
        assertIgnored(draining, EncoderEvent.Suspend(false))

        val paused = draining.copy(paused = true)
        assertIgnored(paused, EncoderEvent.Pause)

        val released = EncoderState(phase = EncoderPhase.Released)
        assertIgnored(released, EncoderEvent.Release)
        assertIgnored(released, EncoderEvent.Pause)
        assertIgnored(released, EncoderEvent.Open(DisplayPhase.Virtual, size))
    }

    private fun assertIgnored(state: EncoderState, event: EncoderEvent) {
        val step = encoderTransition(state, event)
        assertEquals("$state must ignore ${event.wire}", state, step.state)
        assertTrue("$state must ignore ${event.wire} without actions", step.actions.isEmpty())
    }

    @Test
    fun `every phase accepts every event`() {
        val states = listOf(
            EncoderState(),
            EncoderState(phase = EncoderPhase.Opening, pendingDisplay = DisplayPhase.Virtual),
            EncoderState(phase = EncoderPhase.Prepared, prepared = true, preparedStarted = true,
                pendingDisplay = DisplayPhase.Virtual),
            EncoderState(phase = EncoderPhase.Attached, persistent = true),
            EncoderState(phase = EncoderPhase.Attached, persistent = true, paused = true),
            EncoderState(phase = EncoderPhase.Attached, persistent = true, suspended = true),
            EncoderState(phase = EncoderPhase.Attached, persistent = true, paused = true,
                suspended = true),
            EncoderState(phase = EncoderPhase.Swapping, persistent = true, prepared = true),
            EncoderState(phase = EncoderPhase.Released),
        )
        val events = listOf(
            EncoderEvent.Open(DisplayPhase.Virtual, size),
            EncoderEvent.SurfaceReady(true),
            EncoderEvent.Built(true),
            EncoderEvent.Built(false, attach = true),
            EncoderEvent.BuildFailed,
            EncoderEvent.Started,
            EncoderEvent.StartRefused(size),
            EncoderEvent.Created,
            EncoderEvent.Prepare(size),
            EncoderEvent.Attach,
            EncoderEvent.Swapped(suspended = false, previous = true),
            EncoderEvent.Installed(suspended = false),
            EncoderEvent.Pause,
            EncoderEvent.Resume,
            EncoderEvent.Suspend(true),
            EncoderEvent.Suspend(false),
            EncoderEvent.SuspendApplied(true, applied = true),
            EncoderEvent.SuspendApplied(false, applied = true),
            EncoderEvent.ReleasePrevious,
            EncoderEvent.Release,
        )
        for (state in states) {
            for (event in events) {
                val step = encoderTransition(state, event)
                if (state.phase == EncoderPhase.Released) {
                    assertEquals("released is terminal", state, step.state)
                }
            }
        }
    }

    // ------------------------------------------------------------------ helpers

    /** A stream whose swap rebuild fails: display resized, no encoder, optionally paused. */
    private fun failedSwap(pause: Boolean = true): FakeStream {
        val fake = FakeStream(surfaceWorks = true)
        fake.open(DisplayPhase.Virtual, size)
        fake.startRefusals = 1
        fake.prepare(IntSize(960, 540))
        fake.failBuilds = 1
        assertFalse(fake.attachPrepared())
        if (pause) {
            fake.pause()
            assertTrue(fake.state.paused)
        }
        return fake
    }
}
