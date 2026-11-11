package app.contigua.server

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The simulator's "after" against today's build (items 2 and 4).
 *
 * The real send queue, goodput meter, bitrate policy, encoder loop, early
 * signal and ladder run on one deterministic link. "After" must lower the
 * queue-delay p95 and the drop episodes on the crowded profiles (and on a link
 * below the bitrate floor, where the ladder sends fewer pixels), and must leave
 * a clean 20 Mbit/s link's bitrate within 10 % of today's.
 */
class RateControlSimTest {

    private fun crowded(mbps: Long, hook: LinkSim.Hook?, seconds: Int = 300): LinkSim =
        LinkSim(
            name = "wifiq$mbps",
            capacityBps = { mbps * 1_000_000L },
            seconds = seconds,
            targetBps = 8_000_000,
            lossPermille = 5,
            spikeUs = 200_000,
            spikeEveryUs = 2_000_000,
            hook = hook,
        ).run()

    private fun narrow(hook: LinkSim.Hook?): LinkSim =
        LinkSim(
            name = "wifiq0.6",
            capacityBps = { 600_000L },
            seconds = 120,
            targetBps = 8_000_000,
            lossPermille = 5,
            spikeUs = 200_000,
            spikeEveryUs = 2_000_000,
            hook = hook,
        ).run()

    private fun clean(hook: LinkSim.Hook?): LinkSim =
        LinkSim(
            name = "clean20",
            capacityBps = { 20_000_000L },
            seconds = 60,
            targetBps = 8_000_000,
            hook = hook,
        ).run()

    private fun step(hook: LinkSim.Hook?): LinkSim =
        LinkSim(
            name = "step20-3-20",
            capacityBps = { now ->
                when {
                    now < 15_000_000L -> 20_000_000L
                    now < 75_000_000L -> 3_000_000L
                    else -> 20_000_000L
                }
            },
            seconds = 180,
            targetBps = 8_000_000,
            spikeUs = 0,
            hook = hook,
        ).run()

    private class EarlyHook : LinkSim.Hook {
        private val control = RateControl()
        private var state = RateControlState()
        var lastRung = LadderRung.Full
            private set
        var highWindows = 0
            private set
        var floorWindows = 0
            private set
        var scaleSteps = 0
            private set
        var windows = 0
            private set
        var links = 0
            private set
        var lowers = 0
            private set

        override fun drop(nowMs: Long) {
            state = control.step(state, RateControlEvent.Drop(nowMs)).state
        }

        override fun window(
            nowMs: Long,
            delayP95Us: Long?,
            delayP50Us: Long?,
            linkBps: Int?,
            believedBps: Int,
            atFloor: Boolean,
            fullTargetBps: Int,
        ): LinkSim.Hook.Result {
            windows++
            if (delayP95Us != null && delayP95Us >= RateControl.HIGH_DELAY_US) highWindows++
            if (linkBps != null) links++
            if (atFloor) floorWindows++
            val step = control.step(
                state,
                RateControlEvent.Window(
                    nowMs, delayP95Us, delayP50Us, linkBps, believedBps, atFloor,
                ),
            )
            state = step.state
            val lower = (step.action as? RateControlAction.LowerTo)?.bps
            if (lower != null) lowers++
            var target: Int? = null
            (step.action as? RateControlAction.Scale)?.let { scale ->
                lastRung = scale.to
                scaleSteps++
                target = if (scale.to == LadderRung.Full) {
                    fullTargetBps
                } else {
                    minOf(
                        fullTargetBps,
                        maxOf(
                            RateControl.MIN_BPS,
                            (scale.baseBps.toLong() * scale.to.scale * scale.to.scale).toInt(),
                        ),
                    )
                }
            }
            return LinkSim.Hook.Result(lower, target)
        }
    }

    @Test
    fun `the early signal beats today on the crowded eight megabit link`() {
        val before = crowded(8, null)
        val hooked = EarlyHook()
        val after = crowded(8, hooked)
        println("before ${before.summary()}")
        println("after  ${after.summary()}")
        println("hook windows=${hooked.windows} high=${hooked.highWindows} " +
            "links=${hooked.links} lowers=${hooked.lowers}")
        assertTrue(
            "standing queue p95 ${before.standingP95Ms} -> ${after.standingP95Ms} ms",
            after.standingP95Ms < before.standingP95Ms,
        )
        assertTrue(
            "drop episodes ${before.episodes} -> ${after.episodes}",
            after.episodes <= before.episodes,
        )
    }

    @Test
    fun `the early signal beats today on the crowded four megabit link`() {
        val before = crowded(4, null)
        val hooked = EarlyHook()
        val after = crowded(4, hooked)
        println("before ${before.summary()}")
        println("after  ${after.summary()}")
        println("hook windows=${hooked.windows} high=${hooked.highWindows} " +
            "links=${hooked.links} lowers=${hooked.lowers}")
        assertTrue(
            "standing queue p95 ${before.standingP95Ms} -> ${after.standingP95Ms} ms",
            after.standingP95Ms < before.standingP95Ms,
        )
        assertTrue(
            "drop episodes ${before.episodes} -> ${after.episodes}",
            after.episodes <= before.episodes,
        )
    }

    @Test
    fun `the ladder sends fewer pixels under the bitrate floor`() {
        val hooked = EarlyHook()
        val before = narrow(null)
        val after = narrow(hooked)
        println("before ${before.summary()}")
        println("after  ${after.summary()}")
        println("ladder high=${hooked.highWindows} floor=${hooked.floorWindows} " +
            "steps=${hooked.scaleSteps} rung=${hooked.lastRung.wire} " +
            "windows=${hooked.windows} links=${hooked.links} lowers=${hooked.lowers}")
        assertTrue(
            "standing queue p95 ${before.standingP95Ms} -> ${after.standingP95Ms} ms",
            after.standingP95Ms < before.standingP95Ms,
        )
        assertTrue("the ladder engaged: ${hooked.lastRung.wire}", hooked.lastRung != LadderRung.Full)
    }

    @Test
    fun `a clean twenty megabit link keeps today's bitrate`() {
        val before = clean(null)
        val hooked = EarlyHook()
        val after = clean(hooked)
        println("before ${before.summary()}")
        println("after  ${after.summary()}")
        println("hook windows=${hooked.windows} high=${hooked.highWindows} " +
            "links=${hooked.links} lowers=${hooked.lowers}")
        assertTrue(
            "today ${before.finalTargetBps / 1000} kbps, after ${after.finalTargetBps / 1000} kbps",
            after.finalTargetBps >= before.finalTargetBps * 9 / 10,
        )
        assertEquals("no drop on a clean link", before.episodes, after.episodes)
    }

    @Test
    fun `the step down and back keeps the low phase under the link and recovers`() {
        val before = step(null)
        val after = step(EarlyHook())
        println("before ${before.summary()}")
        println("after  ${after.summary()}")
        assertTrue(
            "standing queue p95 ${before.standingP95Ms} -> ${after.standingP95Ms} ms",
            after.standingP95Ms <= before.standingP95Ms,
        )
        assertTrue(
            "drop episodes ${before.episodes} -> ${after.episodes}",
            after.episodes <= before.episodes,
        )
    }
}
