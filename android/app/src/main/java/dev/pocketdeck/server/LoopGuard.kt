package dev.pocketdeck.server

/**
 * Picks the app that opens a Mac -> phone link. PocketDeck itself handles
 * http/https VIEW ("Open on Mac"), so letting the system resolve the intent
 * could hand the link straight back to the Mac. Never pick our own package.
 */
object LoopGuard {
    /** The system's resolver/chooser: not a real handler. */
    const val RESOLVER_PACKAGE = "android"

    /**
     * [preferred] is the package the system would use (the default handler, or
     * the resolver when there is a choice); [resolved] every matching handler.
     * Returns the package to launch explicitly, or null when only we can open it.
     */
    fun pick(preferred: String?, resolved: List<String>, own: String = Session.OWN_PACKAGE): String? {
        val eligible = resolved.filter { it != own && it != RESOLVER_PACKAGE }.distinct()
        return if (preferred != null && preferred in eligible) preferred else eligible.firstOrNull()
    }
}
