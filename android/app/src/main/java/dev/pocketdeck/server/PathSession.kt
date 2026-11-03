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

    /**
     * The path the session was using failed (PATH-7's lost pong on a path that
     * is not receiving). A path leaving the layer is [PathDown], never this.
     */
    data class CurrentFailed(val id: String) : PathSessionEvent

    /**
     * One ping went unanswered for 1.5 s (PATH-7). With two or more paths that
     * fails the current one at once; with only one it is a ranking sample and
     * the caller has already recorded it.
     */
    data class PongLost(val id: String) : PathSessionEvent

    /** The peer's marker arrived on [arrivedOn]; [id] is the path moved to. */
    data class PeerSwitch(val id: String, val seq: Long, val arrivedOn: String) : PathSessionEvent
    data class Close(val reason: String) : PathSessionEvent
    data object GraceExpired : PathSessionEvent
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
    const val PING_INTERVAL = 2.0
    const val PONG_TIMEOUT = 1.5
    const val JOINED_PING_DROP = 5.0
    const val MAX_PATHS = 3
}

/**
 * The path whose lost pong is a failover signal: the migration's target while
 * a switch is pending (the phone's sending path is still the old one until the
 * Mac's marker arrives), else the sending path.
 */
internal fun pongWatchPath(state: PathSessionState, sending: String?): String? =
    if (state is PathSessionState.Migrating) state.to else sending

/**
 * D-2: a pong lost on a path that is still delivering bytes is a ranking
 * sample only. The phone's own pong loss never moves its sending path
 * (PATH-8, R-10); it only demotes the path's standing.
 */
internal fun pongFailure(loss: PathHub.PongLoss, current: String?): PathSessionEvent? =
    if (!loss.alive && loss.path == current) PathSessionEvent.PongLost(loss.path) else null

/** R-14: the state's closed token for the transition log (PATH-14). */
internal fun PathSessionState.describe(): String = when (this) {
    is PathSessionState.Live -> "live $current"
    is PathSessionState.Migrating -> "migrating $from->$to"
    is PathSessionState.Orphaned -> "orphaned"
    is PathSessionState.Ended -> "ended $reason"
}

/**
 * E-10/PATH-21: the session's 30 s deadline. A migration waits for the Mac's
 * marker; without one it is bounded exactly like the orphan's grace, so the
 * phone cannot hold its slot forever on a switch that never completes.
 */
internal fun PathSessionState.graceDeadline(): Double? = when (this) {
    is PathSessionState.Migrating -> since + PathTimers.GRACE
    is PathSessionState.Orphaned -> since + PathTimers.GRACE
    is PathSessionState.Live, is PathSessionState.Ended -> null
}

/** The event's closed token: an id or reason may follow in the state, never here. */
internal fun PathSessionEvent.token(): String = when (this) {
    is PathSessionEvent.PathUp -> "up"
    is PathSessionEvent.PathDown -> "down"
    is PathSessionEvent.CurrentFailed -> "failed"
    is PathSessionEvent.PongLost -> "pong-lost"
    is PathSessionEvent.PeerSwitch -> "switch"
    is PathSessionEvent.Close -> "close"
    PathSessionEvent.GraceExpired -> "grace"
}

/** AGENTS.md: `paths: <from> --<event>--> <to>`, closed tokens only. */
internal object PathSessionLog {
    fun line(before: PathSessionState, event: PathSessionEvent, after: PathSessionState): String =
        "paths: ${before.describe()} --${event.token()}--> ${after.describe()}"
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
                // E-3: the Mac decides a path's life. The old path stays
                // attached as a standby (read, answering pings) and is never
                // closed here; only a socket error or the Mac closes it.
                state = PathSessionState.Live(event.id)
                return listOf(
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
            is PathSessionEvent.PongLost -> {
                if (event.id != s.current) return emptyList()
                // PATH-7 scopes the 1.5 s rule to two or more paths: with one
                // there is nothing to switch to and the sample above is all.
                if (live.size < 2) return emptyList()
                // D-2/R-10: demote, never close. The path stays live and pinged
                // (a standby) and the phone does not move its sending path or
                // replay: only the Mac's marker does that (PATH-8).
                val next = live.filter { it != event.id }.maxByOrNull { scores[it] ?: -1 }
                    ?: return emptyList()
                state = PathSessionState.Live(next)
                return listOf(PathSessionAction.Ranking(PathRankingEvent.CurrentFailed(event.id)))
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
            PathSessionEvent.GraceExpired -> return emptyList()
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
                // E-10/PATH-8: the Mac alone decides. A marker naming any
                // attached path completes the migration there, not only the
                // target this side picked before the Mac rejoined.
                if (event.id !in live) return listOf(PathSessionAction.Ignore)
                state = PathSessionState.Live(event.id)
                return listOf(PathSessionAction.Ranking(PathRankingEvent.ExternalSwitch(event.id)))
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
            is PathSessionEvent.PongLost -> {
                if (event.id != s.to) return emptyList()
                // D-2: demote the migration's target to a standby when the old
                // path is usable; never close it and never replay here.
                if (s.from in live) {
                    state = PathSessionState.Live(s.from)
                    return listOf(PathSessionAction.Ranking(PathRankingEvent.ExternalSwitch(s.from)))
                }
                val next = live.filter { it != event.id }.maxByOrNull { scores[it] ?: -1 }
                if (next != null) {
                    state = PathSessionState.Live(next)
                    return listOf(PathSessionAction.Ranking(PathRankingEvent.ExternalSwitch(next)))
                }
                state = PathSessionState.Orphaned(now)
                return listOf(
                    PathSessionAction.MarkReconnecting,
                    PathSessionAction.Ranking(PathRankingEvent.CurrentFailed(event.id)),
                )
            }
            PathSessionEvent.GraceExpired -> {
                if (now - s.since < PathTimers.GRACE) return emptyList()
                state = PathSessionState.Ended("graceExpired")
                return listOf(PathSessionAction.End("graceExpired"))
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
            is PathSessionEvent.PongLost -> {
                // No path carries the session: nothing to fail over from.
                live.remove(event.id)
                return emptyList()
            }
            is PathSessionEvent.PeerSwitch -> {
                // E-10/PATH-8: a marker from the Mac ends the grace and moves
                // the sending path, as a join does (the hub already replayed).
                if (event.id !in live) return listOf(PathSessionAction.Ignore)
                state = PathSessionState.Live(event.id)
                return listOf(PathSessionAction.Ranking(PathRankingEvent.ExternalSwitch(event.id)))
            }
            is PathSessionEvent.Close -> {
                state = PathSessionState.Ended(event.reason)
                return listOf(PathSessionAction.End(event.reason))
            }
        }
        return emptyList()
    }

    /** A closed token for the transition log (PATH-14): never an address. */
    fun describe(): String = state.describe()
}

enum class PathSwitchKind { PLANNED, UNPLANNED }

sealed interface PathSwitchStep {
    data class Marker(val path: String, val seq: Long) : PathSwitchStep
    data object ReplayFromLastAck : PathSwitchStep
    data class RequestKeyframe(val stream: Int) : PathSwitchStep
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
            streams.map { PathSwitchStep.RequestKeyframe(it) }
    }

    fun accepts(marker: String, live: Set<String>): Boolean = marker in live
}
