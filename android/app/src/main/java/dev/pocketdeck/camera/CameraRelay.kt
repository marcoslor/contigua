package dev.pocketdeck.camera

import dev.pocketdeck.proto.Json

/**
 * The app → shell `cameraState` payload, parsed into what the shell keeps
 * (gate, list) and what it relays (`cam.state`). Pure Kotlin: the shell's relay
 * and the JVM test share exactly this interpretation.
 */
object CameraRelay {

    /**
     * One push. A gate push has [allowed]; a state push has [stream] and
     * [state]. Both may appear in one JSON in principle; the shell applies the
     * gate first, then relays the state.
     */
    class Update(
        val allowed: Boolean?,
        val cams: List<CameraInfo>?,
        val stream: Int?,
        val state: String?,
        val reason: String?,
    ) {
        val hasGate: Boolean get() = allowed != null

        val hasState: Boolean get() = stream != null && !state.isNullOrEmpty()
    }

    fun parse(json: String): Update? {
        val obj = runCatching { Json.parseObject(json) }.getOrNull() ?: return null
        val allowed = if (obj.containsKey("allowed")) Json.bool(obj["allowed"]) == true else null
        val cams = if (obj.containsKey("cams")) CameraInfo.list(obj["cams"]) else null
        return Update(
            allowed = allowed,
            cams = cams,
            stream = Json.int(obj["stream"]),
            state = Json.str(obj["state"]),
            reason = Json.str(obj["reason"]),
        )
    }
}
