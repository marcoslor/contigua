package dev.pocketdeck.app

/**
 * Pure builders for the device events the app's notification listener pushes to
 * the shell service (`pushDeviceEvent`, docs/design/notify.md). JVM-testable: no
 * Android types. The shell service validates the same rules again before the
 * message reaches the wire.
 */
object NotifyEvents {

    /** Per-string cap; anything longer is dropped, never truncated mid-message. */
    const val MAX_CHARS = 8 * 1024
    const val MAX_PKG = 255

    /** Notifications from these packages never leave the phone. */
    val skippedPackages = setOf("dev.pocketdeck")

    private fun capped(s: String): String? = if (s.isNotEmpty() && s.length <= MAX_CHARS) s else null

    private fun validPackage(pkg: String): String? =
        if (pkg.isNotEmpty() && pkg.length <= MAX_PKG && pkg.none { !it.isLetterOrDigit() && it !in "._-" }) pkg else null

    /**
     * One posted notification. Null when the message would be empty or a string
     * broke a cap: the phone never sends malformed events instead of policing
     * them at the other end.
     */
    fun notificationEvent(
        id: String,
        pkg: String,
        title: String?,
        text: String?,
        when_: Long,
    ): Map<String, Any?>? {
        val validPkg = validPackage(pkg) ?: return null
        if (id.isEmpty() || id.length > 64) return null
        if (id.any { !it.isLetterOrDigit() && it !in "-._" }) return null
        if (validPkg in skippedPackages) return null
        val cleanTitle = title?.let(::capped)
        val cleanText = text?.let(::capped)
        // A notification with neither a title nor text has nothing to show; a
        // silent carrier Ridge otherwise only produces noise on the Mac.
        if (cleanTitle == null && cleanText == null) return null
        return buildMap {
            put("t", "notify.post")
            put("id", id)
            put("pkg", validPkg)
            cleanTitle?.let { put("title", it) }
            cleanText?.let { put("text", it) }
            if (when_ > 0L) put("when", when_)
        }
    }

    fun removedEvent(id: String): Map<String, Any?>? =
        if (id.isEmpty() || id.length > 64 || id.any { !it.isLetterOrDigit() && it !in "-._" }) null else mapOf("t" to "notify.remove", "id" to id)

    /**
     * The chosen media session's state; null clears Now Playing. `positionMs` is
     * the session's position at send time; the Mac advances it with `rate`.
     */
    fun mediaState(
        playing: Boolean,
        pkg: String?,
        title: String?,
        artist: String?,
        album: String?,
        durationMs: Long?,
        positionMs: Long?,
        rate: Double,
    ): Map<String, Any?> = buildMap {
        put("t", "media.state")
        put("playing", playing)
        validPackage(pkg.orEmpty())?.let { put("pkg", it) }
        title?.let(::capped)?.takeIf { it.isNotEmpty() }?.let { put("title", it) }
        artist?.let(::capped)?.takeIf { it.isNotEmpty() }?.let { put("artist", it) }
        album?.let(::capped)?.takeIf { it.isNotEmpty() }?.let { put("album", it) }
        durationMs?.takeIf { it > 0 }?.let { put("durationMs", it) }
        positionMs?.takeIf { it >= 0 }?.let { put("positionMs", it) }
        if (playing) put("rate", rate)
    }

    /** Transport commands; anything else is not a command and is dropped. */
    fun validMediaCommand(action: String): String? = when (action) {
        "play", "pause", "next", "prev" -> action
        else -> null
    }
}
