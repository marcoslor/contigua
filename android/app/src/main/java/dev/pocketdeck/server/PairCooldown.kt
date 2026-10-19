package dev.pocketdeck.server

/**
 * M-1: after the person denies a pairing prompt (or it times out), the phone
 * refuses new unpaired pairing attempts for 30 s. One instance per server, not
 * per session: reconnecting must not reset the window and let a LAN peer raise
 * prompt after prompt.
 *
 * The clock is injected so the tests pin the window without sleeping.
 */
class PairCooldown(
    private val now: () -> Long = { System.nanoTime() / 1_000_000 },
    private val windowMs: Long = WINDOW_MS,
) {

    @Volatile private var refusedUntilMs = 0L

    /** The prompt was denied or expired: stay quiet for the window. */
    fun start() {
        refusedUntilMs = now() + windowMs
    }

    /** True while a new `pair.request` must be answered with `pair_denied`. */
    fun active(): Boolean = now() < refusedUntilMs

    companion object {
        /** Long enough to stop prompt spam, short enough to re-pair by hand. */
        const val WINDOW_MS = 30_000L
    }
}
