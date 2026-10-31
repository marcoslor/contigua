package dev.pocketdeck.server

import dev.pocketdeck.proto.PathKind

/**
 * The session machine (docs/design/paths.md §6) and the switch's marker order
 * (§5.4): pure transitions with actions the owner performs. The Mac's
 * `PathsMachines.swift` carries the same table and vectors.
 */
sealed interface PathSessionState {
    data class Live(val current: String) : PathSessionState
    data class Migrating(val from: String, val to: String, val since: Double) : PathSessionState
    data class Orphaned(val since: Double) : PathSessionState
    data class Ended(val reason: String) : PathSessionState
}

sealed interface PathSessionEvent {
    data class PathUp(val id: String, val joined: Boolean) : PathSessionEvent
    data class PathDown(val id: String) : PathSessionEvent
    data class CurrentFailed(val id: String) : PathSessionEvent

    /** The peer's marker arrived on [arrivedOn]; [id] is the path moved to. */
    data class PeerSwitch(val id: String, val seq: Long, val arrivedOn: String) : PathSessionEvent
    data class Close(val reason: String) : PathSessionEvent
    data object GraceExpired : PathSessionEvent

    /** The 2 s drain backstop for a planned switch passed. */
    data object DrainExpired : PathSessionEvent
}

sealed interface PathSessionAction {
    data class StartPing(val path: String) : PathSessionAction
    data class StopPing(val path: String) : PathSessionAction
    data class Ranking(val event: PathRankingEvent) : PathSessionAction
    data class ClosePath(val path: String) : PathSessionAction
    data class SwitchTo(val path: String) : PathSessionAction
    data object ReplayFromLastAck : PathSessionAction
    data object RequestKeyframes : PathSessionAction
    data object MarkReconnecting : PathSessionAction
    data class End(val reason: String) : PathSessionAction
    data object Ignore : PathSessionAction
}

/** The timers the owner fires; the machine holds no clock of its own. */
object PathTimers {
    const val GRACE = 30.0
    const val DRAIN_BACKSTOP = 2.0
    const val PING_INTERVAL = 2.0
    const val PONG_TIMEOUT = 1.5
    const val JOINED_PING_DROP = 5.0
    const val MAX_PATHS = 3
}

class PathSessionMachine(
    var state: PathSessionState = PathSessionState.Orphaned(0.0),
    val live: MutableSet<String> = mutableSetOf(),
    val scores: MutableMap<String, Int> = mutableMapOf(),
    val kinds: MutableMap<String, PathKind> = mutableMapOf(),
) {
    val currentPath: String?
        get() = (state as? PathSessionState.Live)?.current

    /** The first path founds the session: no switch marker, no replay (PATH-3). */
    fun startLive(path: String) {
        state = PathSessionState.Live(path)
        live.clear()
        live.add(path)
        scores[path] = -1
    }

    private fun bestLive(excluding: String? = null): String? =
        live.filter { it != excluding }.maxByOrNull { scores[it] ?: -1 }

    fun handle(event: PathSessionEvent, now: Double): List<PathSessionAction> = when (val s = state) {
        is PathSessionState.Ended -> listOf(PathSessionAction.Ignore)
        is PathSessionState.Live -> onLive(s, event, now)
        is PathSessionState.Migrating -> onMigrating(s, event, now)
        is PathSessionState.Orphaned -> onOrphaned(s, event, now)
    }

    private fun onLive(s: PathSessionState.Live, event: PathSessionEvent, now: Double): List<PathSessionAction> {
        when (event) {
            is PathSessionEvent.PathUp -> {
                if (event.id in live) return listOf(PathSessionAction.ClosePath(event.id))
                live.add(event.id)
                scores.putIfAbsent(event.id, -1)
                return listOf(
                    PathSessionAction.StartPing(event.id),
                    PathSessionAction.Ranking(PathRankingEvent.PathUp(event.id)),
                )
            }
            is PathSessionEvent.PeerSwitch -> {
                if (event.id !in live) return listOf(PathSessionAction.Ignore)
                if (event.id == s.current) return emptyList()
                if (event.arrivedOn == s.current) {
                    state = PathSessionState.Migrating(s.current, event.id, now)
                    return listOf(
                        PathSessionAction.StartPing(event.id),
                        PathSessionAction.Ranking(PathRankingEvent.ExternalSwitch(event.id)),
                    )
                }
                state = PathSessionState.Live(event.id)
                live.remove(s.current)
                return listOf(
                    PathSessionAction.ClosePath(s.current),
                    PathSessionAction.StopPing(s.current),
                    PathSessionAction.StartPing(event.id),
                    PathSessionAction.Ranking(PathRankingEvent.ExternalSwitch(event.id)),
                )
            }
            is PathSessionEvent.CurrentFailed -> {
                if (event.id != s.current) return emptyList()
                live.remove(event.id)
                val next = bestLive()
                if (next != null) {
                    state = PathSessionState.Migrating(event.id, next, now)
                    return listOf(
                        PathSessionAction.StopPing(event.id),
                        PathSessionAction.SwitchTo(next),
                        PathSessionAction.ReplayFromLastAck,
                        PathSessionAction.RequestKeyframes,
                        PathSessionAction.StartPing(next),
                        PathSessionAction.Ranking(PathRankingEvent.CurrentFailed(event.id)),
                    )
                }
                state = PathSessionState.Orphaned(now)
                return listOf(
                    PathSessionAction.StopPing(event.id),
                    PathSessionAction.MarkReconnecting,
                    PathSessionAction.Ranking(PathRankingEvent.CurrentFailed(event.id)),
                )
            }
            is PathSessionEvent.PathDown -> {
                live.remove(event.id)
                if (event.id == s.current) {
                    val next = bestLive()
                    if (next != null) {
                        state = PathSessionState.Migrating(event.id, next, now)
                        return listOf(
                            PathSessionAction.StopPing(event.id),
                            PathSessionAction.SwitchTo(next),
                            PathSessionAction.ReplayFromLastAck,
                            PathSessionAction.RequestKeyframes,
                            PathSessionAction.StartPing(next),
                            PathSessionAction.Ranking(PathRankingEvent.CurrentFailed(event.id)),
                        )
                    }
                    state = PathSessionState.Orphaned(now)
                    return listOf(
                        PathSessionAction.StopPing(event.id),
                        PathSessionAction.MarkReconnecting,
                        PathSessionAction.Ranking(PathRankingEvent.CurrentFailed(event.id)),
                    )
                }
                return listOf(PathSessionAction.Ranking(PathRankingEvent.PathDown(event.id)))
            }
            is PathSessionEvent.Close -> {
                state = PathSessionState.Ended(event.reason)
                return listOf(PathSessionAction.End(event.reason))
            }
            PathSessionEvent.GraceExpired, PathSessionEvent.DrainExpired -> return emptyList()
        }
        return emptyList()
    }

    private fun onMigrating(
        s: PathSessionState.Migrating,
        event: PathSessionEvent,
        now: Double,
    ): List<PathSessionAction> {
        when (event) {
            is PathSessionEvent.PeerSwitch -> {
                if (event.id != s.to) return listOf(PathSessionAction.Ignore)
                state = PathSessionState.Live(s.to)
                live.remove(s.from)
                return listOf(
                    PathSessionAction.ClosePath(s.from),
                    PathSessionAction.StopPing(s.from),
                    PathSessionAction.Ranking(PathRankingEvent.ExternalSwitch(s.to)),
                )
            }
            is PathSessionEvent.PathDown -> {
                live.remove(event.id)
                if (event.id != s.to) return emptyList()
                // The old path is still usable: fall back to it at once.
                if (s.from in live) {
                    state = PathSessionState.Live(s.from)
                    return listOf(PathSessionAction.Ranking(PathRankingEvent.ExternalSwitch(s.from)))
                }
                val next = bestLive()
                if (next != null) {
                    state = PathSessionState.Migrating(s.from, next, now)
                    return listOf(
                        PathSessionAction.StopPing(event.id),
                        PathSessionAction.SwitchTo(next),
                        PathSessionAction.ReplayFromLastAck,
                        PathSessionAction.RequestKeyframes,
                        PathSessionAction.StartPing(next),
                        PathSessionAction.Ranking(PathRankingEvent.CurrentFailed(event.id)),
                    )
                }
                state = PathSessionState.Orphaned(now)
                return listOf(
                    PathSessionAction.MarkReconnecting,
                    PathSessionAction.Ranking(PathRankingEvent.CurrentFailed(event.id)),
                )
            }
            is PathSessionEvent.CurrentFailed -> {
                if (event.id != s.to) return emptyList()
                live.remove(event.id)
                val next = bestLive(excluding = s.from)
                if (next != null) {
                    state = PathSessionState.Migrating(s.from, next, now)
                    return listOf(
                        PathSessionAction.SwitchTo(next),
                        PathSessionAction.ReplayFromLastAck,
                        PathSessionAction.RequestKeyframes,
                        PathSessionAction.StartPing(next),
                        PathSessionAction.Ranking(PathRankingEvent.CurrentFailed(event.id)),
                    )
                }
                if (s.from in live) {
                    state = PathSessionState.Live(s.from)
                    return listOf(PathSessionAction.Ranking(PathRankingEvent.ExternalSwitch(s.from)))
                }
                state = PathSessionState.Orphaned(now)
                return listOf(
                    PathSessionAction.MarkReconnecting,
                    PathSessionAction.Ranking(PathRankingEvent.CurrentFailed(event.id)),
                )
            }
            PathSessionEvent.DrainExpired -> {
                live.remove(s.from)
                return listOf(PathSessionAction.ClosePath(s.from), PathSessionAction.StopPing(s.from))
            }
            is PathSessionEvent.Close -> {
                state = PathSessionState.Ended(event.reason)
                return listOf(PathSessionAction.End(event.reason))
            }
            is PathSessionEvent.PathUp -> {
                if (event.id in live) return listOf(PathSessionAction.ClosePath(event.id))
                live.add(event.id)
                scores.putIfAbsent(event.id, -1)
                return listOf(
                    PathSessionAction.StartPing(event.id),
                    PathSessionAction.Ranking(PathRankingEvent.PathUp(event.id)),
                )
            }
            PathSessionEvent.GraceExpired -> return emptyList()
        }
        return emptyList()
    }

    private fun onOrphaned(
        s: PathSessionState.Orphaned,
        event: PathSessionEvent,
        now: Double,
    ): List<PathSessionAction> {
        when (event) {
            is PathSessionEvent.PathUp -> {
                if (event.id in live) return listOf(PathSessionAction.ClosePath(event.id))
                live.add(event.id)
                scores.putIfAbsent(event.id, -1)
                state = PathSessionState.Live(event.id)
                return listOf(
                    PathSessionAction.SwitchTo(event.id),
                    PathSessionAction.ReplayFromLastAck,
                    PathSessionAction.RequestKeyframes,
                    PathSessionAction.StartPing(event.id),
                    PathSessionAction.Ranking(PathRankingEvent.PathUp(event.id)),
                )
            }
            is PathSessionEvent.PathDown -> {
                live.remove(event.id)
                return listOf(PathSessionAction.Ranking(PathRankingEvent.PathDown(event.id)))
            }
            PathSessionEvent.GraceExpired -> {
                if (now - s.since < PathTimers.GRACE) return emptyList()
                state = PathSessionState.Ended("graceExpired")
                return listOf(PathSessionAction.End("graceExpired"))
            }
            is PathSessionEvent.CurrentFailed -> {
                live.remove(event.id)
                return listOf(PathSessionAction.Ranking(PathRankingEvent.CurrentFailed(event.id)))
            }
            is PathSessionEvent.PeerSwitch -> return listOf(PathSessionAction.Ignore)
            is PathSessionEvent.Close -> {
                state = PathSessionState.Ended(event.reason)
                return listOf(PathSessionAction.End(event.reason))
            }
            PathSessionEvent.DrainExpired -> return emptyList()
        }
        return emptyList()
    }

    /** A closed token for the transition log (PATH-14): never an address. */
    fun describe(): String = when (val s = state) {
        is PathSessionState.Live -> "live ${s.current}"
        is PathSessionState.Migrating -> "migrating ${s.from}->${s.to}"
        is PathSessionState.Orphaned -> "orphaned"
        is PathSessionState.Ended -> "ended ${s.reason}"
    }
}

enum class PathSwitchKind { PLANNED, UNPLANNED }

sealed interface PathSwitchStep {
    data class Marker(val path: String, val seq: Long) : PathSwitchStep
    data object ReplayFromLastAck : PathSwitchStep
    data class RequestKeyframe(val stream: Int) : PathSwitchStep
    data class ClosePath(val path: String) : PathSwitchStep
}

object PathSwitch {
    fun plan(
        kind: PathSwitchKind,
        from: String,
        to: String,
        nextSeq: Long,
        streams: List<Int>,
    ): List<PathSwitchStep> {
        val marker = if (kind == PathSwitchKind.PLANNED) from else to
        return listOf(PathSwitchStep.Marker(marker, nextSeq), PathSwitchStep.ReplayFromLastAck) +
            streams.map { PathSwitchStep.RequestKeyframe(it) } +
            PathSwitchStep.ClosePath(from)
    }

    fun accepts(marker: String, live: Set<String>): Boolean = marker in live
}
