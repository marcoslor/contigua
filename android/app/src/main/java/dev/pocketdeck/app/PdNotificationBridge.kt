package dev.pocketdeck.app

import android.content.Context
import android.util.Log
import dev.pocketdeck.proto.Json
import dev.pocketdeck.proto.JsonException

/**
 * The phone side of notification sharing: sends the app-process listener's
 * events to the shell service over AIDL and delivers the Mac's media commands.
 * Text is never logged (privacy: this file must not embed title/text bodies in
 * any message).
 */
class PdNotificationBridge(private val context: Context) {

    /** Both gates: the phone's per-phone toggle and the Mac's per-session opt-in. */
    fun gate(): Boolean = Prefs.isNotifyShared(context) && DeckState.notifyForward

    fun post(event: Map<String, Any?>) {
        push(event, "notify")
    }

    fun media(event: Map<String, Any?>) {
        push(event, "media.state")
    }

    /** `media.sessions` and `media.art` ride the same gate as `media.state`. */
    fun sessions(event: Map<String, Any?>) {
        push(event, "media.sessions")
    }

    fun art(event: Map<String, Any?>) {
        push(event, "media.art")
    }

    private fun push(event: Map<String, Any?>, kind: String) {
        if (!gate()) {
            if (event["t"] == "media.state" && event["playing"] == true) Log.i(TAG, "gated, media.state held")
            return
        }
        runCatching { ShizukuClient.current()?.pushDeviceEvent(Json.encode(event)) }
            .onFailure {
                when (it) {
                    is JsonException -> Log.w(TAG, "bad $kind event dropped: ${it.message}")
                    else -> Log.w(TAG, "push failed: ${it.message}")
                }
            }
    }

    companion object {
        /** `media.command` (JSON: action, optional key/positionMs/level) from the Mac. */
        @Volatile
        var mediaSink: ((String) -> Unit)? = null

        /** `notify.action` (id, advertised index, reply text) from the Mac. */
        @Volatile
        var actionSink: ((String, Int, String?) -> Unit)? = null

        /** `notify.dismiss` (id) from the Mac. */
        @Volatile
        var dismissSink: ((String) -> Unit)? = null

        /** `media.choose` (session key) from the Mac. */
        @Volatile
        var chooseSink: ((String) -> Unit)? = null

        private const val TAG = "PocketDeckApp"
    }
}
