package dev.pocketdeck.server

import org.junit.Test

/**
 * The baseline record for the rate controller: today's build on the crowded
 * 2.4 GHz profiles and on a 20 → 3 → 20 Mbit/s step. Prints its numbers; the
 * teaching assertions live in [RateControlSimTest] once the early signal and
 * the ladder exist.
 */
class RateCtlSimTest {

    private fun crowded(mbps: Long, seconds: Int = 120): LinkSim =
        LinkSim(
            name = "wifiq$mbps",
            capacityBps = { mbps * 1_000_000L },
            seconds = seconds,
            targetBps = 8_000_000,
            lossPermille = 5,
            spikeUs = 200_000,
            spikeEveryUs = 2_000_000,
        ).run()

    private fun step(): LinkSim =
        LinkSim(
            name = "step20-3-20",
            capacityBps = { now ->
                when {
                    now < 15_000_000L -> 20_000_000L
                    now < 75_000_000L -> 3_000_000L
                    else -> 20_000_000L
                }
            },
            seconds = 120,
            targetBps = 8_000_000,
            lossPermille = 0,
            spikeUs = 0,
        ).run()

    private fun clean(): LinkSim =
        LinkSim(
            name = "clean20",
            capacityBps = { 20_000_000L },
            seconds = 60,
            targetBps = 8_000_000,
            lossPermille = 0,
            spikeUs = 0,
        ).run()

    @Test
    fun `record today's crowded and step behaviour`() {
        val eight = crowded(8)
        val four = crowded(4)
        val stepped = step()
        val clean = clean()
        for (sim in listOf(eight, four, stepped, clean)) {
            println(sim.summary())
        }
    }
}
