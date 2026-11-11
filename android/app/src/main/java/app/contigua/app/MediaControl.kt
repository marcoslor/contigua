package app.contigua.app

import app.contigua.proto.Json

/**
 * One active phone media session as `media.sessions` lists it (docs/design/
 * notify.md, "Media part 2 design"). No title, artist or album: the list is
 * what the Mac needs to offer a choice, nothing else.
 */
data class MediaSessionInfo(
    val key: String,
    val pkg: String,
    val app: String,
    val playing: Boolean,
)

/** One command from the Mac (`media.command`), already parsed. */
data class MediaCommand(
    val action: String,
    val key: String? = null,
    val positionMs: Long? = null,
    val level: Int? = null,
)

/**
 * The pure media rules of "Media part 2": the chosen session, the sessions
 * list, the clamps and the command parse. JVM-tested without Android; the
 * shell service re-validates the same fields before they reach the wire.
 */
object MediaControl {

    const val MAX_KEY = 64
    const val MAX_APP = 64
    const val MAX_SESSIONS = 16

    /** A position beyond a day is not a track position; the session clamps again. */
    const val MAX_POSITION_MS = 24L * 3600 * 1000

    /** The phone clamps to its own volumeMax; this only bounds a bogus one. */
    const val MAX_LEVEL = 1000

    val actions = setOf("play", "pause", "next", "prev", "seek", "volume")

    /** An opaque per-session key: [A-Za-z0-9-._], at most 64 chars. */
    fun validKey(key: String?): String? =
        key?.takeIf { it.isNotEmpty() && it.length <= MAX_KEY && it.all { c -> c.isLetterOrDigit() || c in "-._" } }

    /**
     * The key Now Playing follows: the Mac's pick while that session is still
     * active, else the system's first one.
     */
    fun chooseKey(keys: List<String>, preferred: String?): String? {
        val good = validKey(preferred)
        if (good != null && good in keys) return good
        return keys.firstOrNull()
    }

    /** `media.sessions`; malformed entries are dropped, never sent. */
    fun sessionsWire(sessions: List<MediaSessionInfo>, chosen: String?): Map<String, Any?> {
        val list = ArrayList<Map<String, Any?>>(minOf(sessions.size, MAX_SESSIONS))
        for (session in sessions) {
            if (list.size == MAX_SESSIONS) break
            val key = validKey(session.key) ?: continue
            val pkg = session.pkg.takeIf {
                it.isNotEmpty() && it.length <= NotifyEvents.MAX_PKG && it.all { c -> c.isLetterOrDigit() || c in "._-" }
            } ?: continue
            val app = session.app.trim().take(MAX_APP).ifEmpty { pkg }
            list += mapOf("key" to key, "pkg" to pkg, "app" to app, "playing" to session.playing)
        }
        return buildMap {
            put("t", "media.sessions")
            put("list", list)
            validKey(chosen)?.let { put("chosen", it) }
        }
    }

    /** A seek position inside the track; a session without a duration keeps it as is. */
    fun positionClamp(positionMs: Long, durationMs: Long?): Long {
        val position = positionMs.coerceAtLeast(0)
        return if (durationMs != null && durationMs > 0) position.coerceAtMost(durationMs) else position
    }

    /** The volume level the session takes: inside `[0, volumeMax]`. */
    fun levelClamp(level: Int, volumeMax: Int?): Int {
        val max = (volumeMax ?: 0).coerceAtLeast(0)
        if (max <= 0) return 0
        return level.coerceIn(0, max)
    }

    /** `media.command` from the shell service; null when it is not a command. */
    fun commandFromWire(obj: Map<String, Any?>): MediaCommand? {
        val action = Json.str(obj["action"]) ?: return null
        if (action !in actions) return null
        val key = validKey(Json.str(obj["key"]))
        return when (action) {
            "seek" -> MediaCommand(
                action = action,
                key = key,
                positionMs = Json.long(obj["positionMs"])?.coerceIn(0, MAX_POSITION_MS) ?: return null,
            )
            "volume" -> MediaCommand(
                action = action,
                key = key,
                level = Json.int(obj["level"])?.coerceIn(0, MAX_LEVEL) ?: return null,
            )
            else -> MediaCommand(action = action, key = key)
        }
    }
}
