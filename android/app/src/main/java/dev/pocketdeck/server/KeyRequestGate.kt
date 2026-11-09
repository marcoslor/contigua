package dev.pocketdeck.server

/**
 * The duplicate-keyframe rule: a fresh encoder starts on an IDR, and the Mac
 * asks for one after every VIDEO_CONFIG. A request that arrives just after an
 * IDR the phone already sent is answered by that frame; a second sync request
 * would only cost another key frame. The Mac's 500 ms retry is outside the
 * window and is honoured.
 */
internal class KeyRequestGate(private val dedupeMs: Long = DEDUPE_MS) {

    private var lastIdrAtMs = Long.MIN_VALUE

    /** A new encoder: any earlier IDR belongs to a stream the Mac no longer sees. */
    @Synchronized
    fun reset() {
        lastIdrAtMs = Long.MIN_VALUE
    }

    /**
     * Deltas after the last IDR were dropped (the drop rule): the decoder now
     * needs a key after them, so that IDR answers no request any more.
     */
    @Synchronized
    fun onDeltasDropped() {
        lastIdrAtMs = Long.MIN_VALUE
    }

    /** The encoder produced an IDR at [nowMs] and the frame went to the queue. */
    @Synchronized
    fun onIdr(nowMs: Long) {
        lastIdrAtMs = nowMs
    }

    /** What to do with a key-frame request seen at [nowMs]. */
    @Synchronized
    fun onRequest(nowMs: Long): KeyRequest {
        val idrAt = lastIdrAtMs
        if (idrAt != Long.MIN_VALUE && nowMs >= idrAt && nowMs - idrAt <= dedupeMs) {
            return KeyRequest.Satisfied(nowMs - idrAt)
        }
        return KeyRequest.Send
    }

    sealed interface KeyRequest {
        /** The IDR that already went out, [idrAgoMs] ago, answers this request. */
        data class Satisfied(val idrAgoMs: Long) : KeyRequest

        /** No recent IDR: ask the encoder for a sync frame. */
        data object Send : KeyRequest
    }

    companion object {
        /** The Mac's first request after a config lands inside this window. */
        const val DEDUPE_MS = 250L
    }
}
