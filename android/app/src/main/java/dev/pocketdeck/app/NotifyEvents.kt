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

    /** Actions on the Mac banner: the phone's own buttons and a reply field. */
    const val MAX_ACTIONS = 3
    const val MAX_ACTION_TITLE = 64
    /** A reply sent back from the Mac; over this the listener refuses it. */
    const val MAX_REPLY_CHARS = 4 * 1024

    /** The Live Update chip's own cap (docs/design/notify.md). */
    const val MAX_CHIP = 16

    /**
     * `Notification.FLAG_PROMOTED_ONGOING`: the system promoted this ongoing
     * notification into an Android 16 Live Update. Kept as a literal so the
     * rule is JVM-tested; the constant itself is API 36.
     */
    const val FLAG_PROMOTED_ONGOING = 0x00040000

    /** The marker a debug build's test poster puts on its own notifications. */
    const val DEBUG_POSTER_EXTRA = "dev.pocketdeck.debug.poster"

    /** Notifications from these packages never leave the phone (debug poster excepted). */
    val skippedPackages = setOf("dev.pocketdeck")

    /**
     * One of the phone notification's actions as the Mac could see it. Built by
     * the listener from `Notification.Action`; kept free of Android types so the
     * selection and cap rules are JVM-tested.
     */
    data class ActionCandidate(
        /** The index in the phone's own `Notification.actions`. */
        val index: Int,
        val title: String?,
        val hasIntent: Boolean,
        /** The action carries a free-form RemoteInput. */
        val reply: Boolean,
        /** A system-generated ("contextual") smart action. */
        val contextual: Boolean,
    )

    private fun capped(s: String): String? = if (s.isNotEmpty() && s.length <= MAX_CHARS) s else null

    private fun validPackage(pkg: String): String? =
        if (pkg.isNotEmpty() && pkg.length <= MAX_PKG && pkg.none { !it.isLetterOrDigit() && it !in "._-" }) pkg else null

    /**
     * The actions worth advertising: a title and a PendingIntent, not a
     * contextual smart action, at most [MAX_ACTIONS], titles trimmed and capped.
     * The advertised index stays the one in the phone's array so `notify.action`
     * names exactly what the person pressed.
     */
    fun selectActions(candidates: List<ActionCandidate>): List<ActionCandidate> {
        val selected = ArrayList<ActionCandidate>(MAX_ACTIONS)
        for (candidate in candidates) {
            if (selected.size == MAX_ACTIONS) break
            if (candidate.contextual || !candidate.hasIntent) continue
            val title = candidate.title?.trim()?.take(MAX_ACTION_TITLE) ?: continue
            if (title.isEmpty()) continue
            selected += candidate.copy(title = title)
        }
        return selected
    }

    /** The `actions` field of `notify.post`; empty when there is nothing to show. */
    fun actionWire(actions: List<ActionCandidate>): List<Map<String, Any?>> =
        actions.map { action ->
            buildMap {
                put("i", action.index)
                put("title", action.title ?: "")
                if (action.reply) put("reply", true)
            }
        }

    /** The reason a reply text is refused, or null when it may go out. */
    fun actionTextRefusal(text: String?, reply: Boolean): String? = when {
        text == null || text.isEmpty() -> null
        !reply -> "not a reply action"
        text.length > MAX_REPLY_CHARS -> "text cap"
        else -> null
    }

    /** The advertised index the Mac named, or null when it never offered it. */
    fun actionAt(actions: List<ActionCandidate>, index: Int): ActionCandidate? =
        actions.firstOrNull { it.index == index }

    /** A notification that is ongoing or no-clear is not the person's to dismiss. */
    fun canDismiss(ongoing: Boolean, noClear: Boolean): Boolean = !ongoing && !noClear

    /**
     * An ongoing notification is forwarded only when Android promoted it into a
     * Live Update (docs/design/notify.md). Everything else ongoing is service
     * chrome, as before part 2.
     */
    fun promoted(flags: Int, ongoing: Boolean): Boolean =
        ongoing && flags and FLAG_PROMOTED_ONGOING != 0

    /**
     * A ProgressStyle fraction: `progress / max`, clamped. `max` is the style's
     * own maximum, which is the sum of the segment lengths for a segmented
     * style. Null when there is no usable maximum (indeterminate or absent).
     */
    fun progressFraction(progress: Int, max: Int): Double? {
        if (max <= 0 || progress < 0) return null
        return (progress.toDouble() / max).coerceIn(0.0, 1.0)
    }

    /**
     * The `live` field of `notify.post`, or null when the notification says
     * nothing about its progress (a promoted notification with a plain title is
     * still live, so it gets at least the empty marker from the caller).
     */
    fun liveWire(
        progress: Double?,
        chip: String?,
        chronoMs: Long?,
        countDown: Boolean,
    ): Map<String, Any?>? {
        val cleanChip = chip?.trim()?.take(MAX_CHIP)?.takeIf { it.isNotEmpty() }
        val cleanProgress = progress?.takeIf { it.isFinite() }?.coerceIn(0.0, 1.0)
        val cleanChrono = chronoMs?.takeIf { it > 0L }
        if (cleanProgress == null && cleanChip == null && cleanChrono == null) return null
        return buildMap {
            cleanProgress?.let { put("progress", it) }
            cleanChip?.let { put("chip", it) }
            cleanChrono?.let { put("chrono", it) }
            if (countDown && cleanChrono != null) put("countDown", true)
        }
    }

    /**
     * Our own package's notifications are not forwarded, except a debug build's
     * test poster (never in release), so the emulator/E2E can exercise the
     * listener with notifications it created itself.
     */
    fun debugPoster(pkg: String, flagged: Boolean, debugBuild: Boolean): Boolean =
        debugBuild && flagged && pkg == "dev.pocketdeck"

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
        actions: List<ActionCandidate> = emptyList(),
        ongoing: Boolean = false,
        debugPoster: Boolean = false,
        live: Map<String, Any?>? = null,
    ): Map<String, Any?>? {
        val validPkg = validPackage(pkg) ?: return null
        if (id.isEmpty() || id.length > 64) return null
        if (id.any { !it.isLetterOrDigit() && it !in "-._" }) return null
        if (validPkg in skippedPackages && !debugPoster) return null
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
            if (ongoing) put("ongoing", true)
            live?.let { put("live", it) }
            val wire = actionWire(actions)
            if (wire.isNotEmpty()) put("actions", wire)
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
