package app.contigua.app

import android.util.Log
import app.contigua.proto.Json
import app.contigua.proto.JsonException

/**
 * The phone side of notification sharing: sends the app-process listener's
 * events to the shell service over AIDL and delivers the Mac's media commands.
 * Text is never logged (privacy: this file must not embed title/text bodies in
 * any message).
 */
class PdNotificationBridge {

    /** The Mac's opt-in plus the listener grant, answered by the shell session. */
    fun gate(): Boolean = DeckState.notifyForward

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
        // After the gate, so a JVM test records exactly what the Mac would get.
        recordForTest?.invoke(event)
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

        /**
         * The shell answered `notify.enable on` while forwarding: the listener
         * resends its active set (NOTIFY-1/PATH-6). One call per enable.
         */
        @Volatile
        var resyncSink: (() -> Unit)? = null

        /**
         * A JVM test records what would cross the wire here (after both gates);
         * the app leaves it null. Nothing else reads or writes it.
         */
        @Volatile
        var recordForTest: ((Map<String, Any?>) -> Unit)? = null

        private const val TAG = "ContiguaApp"
    }
}
