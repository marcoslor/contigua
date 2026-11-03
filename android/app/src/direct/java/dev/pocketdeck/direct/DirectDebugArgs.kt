package dev.pocketdeck.direct

/**
 * The debug control's one argument (brief item 7): strictly `on`, `off`,
 * `permission` or `state`. Anything else is not ours to act on.
 */
data class DirectDebugArgs(val op: String) {
    companion object {
        val OPS = setOf("on", "off", "permission", "state")

        fun parse(raw: String?): DirectDebugArgs? =
            raw?.trim()?.lowercase()?.takeIf { it in OPS }?.let { DirectDebugArgs(it) }
    }
}
