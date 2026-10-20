package dev.pocketdeck.app

/**
 * The debug media session's arguments (android/app/src/debug, docs/design/
 * notify.md "Media part 2"). Pure so the parsing is JVM-tested without a
 * device: `op` is `start` or `stop`, `index` picks one of the two fake
 * sessions (1 or 2), and `paused` starts it without advancing.
 */
data class MediaDebugArgs(
    val op: String,
    val index: Int?,
    val paused: Boolean,
) {
    val start: Boolean get() = op == "start"

    companion object {
        const val MAX_SESSIONS = 2

        /** Null for a broadcast that is not ours to act on. */
        fun parse(op: String?, index: Int?, paused: Boolean): MediaDebugArgs? {
            val clean = op?.trim()?.lowercase() ?: return null
            if (clean != "start" && clean != "stop") return null
            val slot = index?.takeIf { it in 1..MAX_SESSIONS }
            // A start needs a slot; a stop without one stops both.
            if (clean == "start" && slot == null) return null
            return MediaDebugArgs(clean, slot, paused)
        }
    }
}
