package dev.pocketdeck.server

import dev.pocketdeck.proto.PathKind
import kotlin.math.ceil
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

/**
 * The ranking (docs/design/paths.md §7): the 30 s window, the pure score and
 * the Steady/Challenging machine. The phone computes it for its own health
 * reporting and never acts on a switch (PATH-8); the Mac runs the same table.
 */
sealed interface PathRankingState {
    data object Idle : PathRankingState
    data class Steady(val current: String) : PathRankingState
    data class Challenging(val current: String, val challenger: String, val since: Double) : PathRankingState
}

sealed interface PathRankingEvent {
    data class PathUp(val id: String) : PathRankingEvent
    data class PathDown(val id: String) : PathRankingEvent

    /** One ping round: the RTT, or null for a lost pong. */
    data class Sample(val id: String, val rttMs: Double?) : PathRankingEvent
    data class Tick(val now: Double) : PathRankingEvent

    /** The current path failed: switch at once, no hysteresis. */
    data class CurrentFailed(val id: String) : PathRankingEvent

    /** The session switched (the peer's marker): the ranking follows. */
    data class ExternalSwitch(val id: String) : PathRankingEvent
}

sealed interface PathRankingAction {
    data class SwitchTo(val path: String) : PathRankingAction
    data object SessionOrphan : PathRankingAction
}

class PathStats {
    val samples = ArrayList<Pair<Double, Double?>>()
    var pings = 0
    val pongs: Int get() = samples.count { it.second != null }

    fun prune(now: Double, window: Double) {
        samples.removeAll { now - it.first > window }
    }
}

class PathRanking {
    var state: PathRankingState = PathRankingState.Idle
        private set
    val stats = HashMap<String, PathStats>()
    val kinds = HashMap<String, PathKind>()

    fun register(id: String, kind: PathKind = PathKind.LAN) {
        kinds[id] = kind
        stats.getOrPut(id) { PathStats() }
    }

    fun addSample(id: String, rttMs: Double?, at: Double) {
        register(id)
        val s = stats.getValue(id)
        s.pings++
        s.samples.add(at to rttMs)
        s.prune(at, WINDOW)
    }

    /** The score in 0…1000, or null while the path has fewer than 2 pongs. */
    fun score(id: String, now: Double): Int? {
        val s = stats[id] ?: return null
        s.prune(now, WINDOW)
        if (s.pongs < MIN_PONGS || s.pings <= 0) return null
        val rtts = s.samples.mapNotNull { it.second }.sorted()
        val p50 = nearestRank(rtts, 0.50)
        val p95 = nearestRank(rtts, 0.95)
        val loss = (s.pings - s.pongs).toDouble() / s.pings
        return score(p50, p95, loss, (kinds[id] ?: PathKind.LAN).floorMbps)
    }

    private fun bestLiveRankable(now: Double, excluding: String? = null): String? =
        stats.keys.filter { it != excluding }
            .mapNotNull { id -> score(id, now)?.let { id to it } }
            .maxByOrNull { it.second }?.first

    private fun bestLiveAny(now: Double, excluding: String? = null): String? =
        stats.keys.filter { it != excluding }
            .maxByOrNull { score(it, now) ?: -1 }

    fun handle(event: PathRankingEvent, now: Double): List<PathRankingAction> {
        when (event) {
            is PathRankingEvent.PathUp -> {
                register(event.id)
                when (state) {
                    is PathRankingState.Idle -> {
                        val best = bestLiveRankable(now) ?: return emptyList()
                        state = PathRankingState.Steady(best)
                    }
                    is PathRankingState.Steady, is PathRankingState.Challenging -> Unit
                }
                return emptyList()
            }
            is PathRankingEvent.PathDown -> {
                stats.remove(event.id)
                return when (val s = state) {
                    is PathRankingState.Idle -> emptyList()
                    is PathRankingState.Steady -> {
                        if (event.id != s.current) emptyList()
                        else {
                            val next = bestLiveAny(now)
                            if (next == null) {
                                state = PathRankingState.Idle
                                listOf(PathRankingAction.SessionOrphan)
                            } else {
                                state = PathRankingState.Steady(next)
                                listOf(PathRankingAction.SwitchTo(next))
                            }
                        }
                    }
                    is PathRankingState.Challenging -> {
                        if (event.id == s.challenger) state = PathRankingState.Steady(s.current)
                        if (event.id != s.current) emptyList()
                        else {
                            val next = bestLiveAny(now)
                            if (next == null) {
                                state = PathRankingState.Idle
                                listOf(PathRankingAction.SessionOrphan)
                            } else {
                                state = PathRankingState.Steady(next)
                                listOf(PathRankingAction.SwitchTo(next))
                            }
                        }
                    }
                }
            }
            is PathRankingEvent.Sample -> {
                if (stats[event.id] == null && state is PathRankingState.Idle) return emptyList()
                addSample(event.id, event.rttMs, now)
                return emptyList()
            }
            is PathRankingEvent.Tick -> {
                when (val s = state) {
                    is PathRankingState.Idle -> return emptyList()
                    is PathRankingState.Steady -> {
                        val challenger = bestLiveRankable(event.now, excluding = s.current)
                            ?: return emptyList()
                        val currentScore = score(s.current, event.now) ?: return emptyList()
                        val challengerScore = score(challenger, event.now) ?: return emptyList()
                        if (challengerScore < currentScore + MARGIN) return emptyList()
                        state = PathRankingState.Challenging(s.current, challenger, event.now)
                        return emptyList()
                    }
                    is PathRankingState.Challenging -> {
                        if (stats[s.challenger] == null || stats[s.current] == null) {
                            state = PathRankingState.Steady(s.current)
                            return emptyList()
                        }
                        val currentScore = score(s.current, event.now)
                        val challengerScore = score(s.challenger, event.now)
                        if (currentScore == null || challengerScore == null ||
                            challengerScore < currentScore + MARGIN
                        ) {
                            state = PathRankingState.Steady(s.current)
                            return emptyList()
                        }
                        if (event.now - s.since < HYSTERESIS) return emptyList()
                        state = PathRankingState.Steady(s.challenger)
                        return listOf(PathRankingAction.SwitchTo(s.challenger))
                    }
                }
            }
            is PathRankingEvent.CurrentFailed -> {
                stats.remove(event.id)
                val next = bestLiveAny(now)
                return if (next == null) {
                    state = PathRankingState.Idle
                    listOf(PathRankingAction.SessionOrphan)
                } else {
                    state = PathRankingState.Steady(next)
                    listOf(PathRankingAction.SwitchTo(next))
                }
            }
            is PathRankingEvent.ExternalSwitch -> {
                register(event.id)
                state = PathRankingState.Steady(event.id)
                return emptyList()
            }
        }
    }

    companion object {
        const val WINDOW = 30.0
        const val MARGIN = 100
        const val HYSTERESIS = 5.0
        const val MIN_PONGS = 2

        fun nearestRank(sorted: List<Double>, q: Double): Double {
            if (sorted.isEmpty()) return 0.0
            val index = max(0, ceil(q * sorted.size).toInt() - 1)
            return sorted[min(index, sorted.size - 1)]
        }

        /** The pure formula (docs/design/paths.md §7.1), 0…1000. */
        fun score(p50Ms: Double, p95Ms: Double, loss: Double, floorMbps: Int): Int {
            val qRtt = 1.0 / (1.0 + max(0.0, p50Ms) / 10.0)
            val qJit = 1.0 / (1.0 + max(0.0, p95Ms - p50Ms) / 25.0)
            val qLoss = 1.0 - min(max(0.0, loss), 0.10) / 0.10
            val qBw = min(1.0, floorMbps / 209.0)
            return (1000.0 * (0.45 * qRtt + 0.15 * qJit + 0.20 * qLoss + 0.20 * qBw)).roundToInt()
        }
    }
}
