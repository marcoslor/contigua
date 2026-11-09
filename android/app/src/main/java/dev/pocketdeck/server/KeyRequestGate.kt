package dev.pocketdeck.server

/**
 * The duplicate-keyframe gate. The rule lands with the wiring that uses it; the
 * test below pins the behaviour first.
 */
internal class KeyRequestGate(private val dedupeMs: Long = DEDUPE_MS) {

    fun reset() = Unit

    fun onIdr(nowMs: Long) = Unit

    fun onRequest(nowMs: Long): KeyRequest = KeyRequest.Send

    sealed interface KeyRequest {
        data class Satisfied(val idrAgoMs: Long) : KeyRequest

        data object Send : KeyRequest
    }

    companion object {
        const val DEDUPE_MS = 250L
    }
}
