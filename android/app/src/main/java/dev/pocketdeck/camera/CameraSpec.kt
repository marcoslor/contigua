package dev.pocketdeck.camera

import dev.pocketdeck.proto.Json

/** One `cam.start` request as the app service sees it. */
data class CameraSpec(
    val stream: Int,
    /** A camera id from `cam.cams`; wins over [facing]. Null picks by facing. */
    val cameraId: String? = null,
    /** `back` or `front` when no id was named. */
    val facing: String? = null,
    val w: Int = DEFAULT_W,
    val h: Int = DEFAULT_H,
    val fps: Int = DEFAULT_FPS,
) {

    /** The request inside the protocol's caps (docs/PROTOCOL.md "Camera"). */
    fun clamped(): CameraSpec = copy(
        w = w.coerceIn(160, MAX_W),
        h = h.coerceIn(120, MAX_H),
        fps = fps.coerceIn(1, MAX_FPS),
    )

    fun toJson(): String = Json.encode(
        linkedMapOf(
            "stream" to stream,
            "id" to cameraId,
            "facing" to facing,
            "w" to w,
            "h" to h,
            "fps" to fps,
        ),
    )

    companion object {
        const val DEFAULT_W = 1280
        const val DEFAULT_H = 720
        const val DEFAULT_FPS = 30
        const val MAX_W = 1920
        const val MAX_H = 1080
        const val MAX_FPS = 30

        /** Null when the request has no usable stream id. */
        fun fromJson(text: String?): CameraSpec? {
            val obj = runCatching { Json.parseObject(text ?: "") }.getOrNull() ?: return null
            return from(obj)
        }

        fun from(obj: Map<String, Any?>): CameraSpec? {
            val stream = Json.int(obj["stream"]) ?: return null
            if (stream <= 0) return null
            var w = Json.int(obj["w"]) ?: DEFAULT_W
            var h = Json.int(obj["h"]) ?: DEFAULT_H
            if (w <= 0) w = DEFAULT_W
            if (h <= 0) h = DEFAULT_H
            return CameraSpec(
                stream = stream,
                cameraId = Json.str(obj["id"])?.takeIf { it.isNotEmpty() },
                facing = Json.str(obj["facing"])?.takeIf { it == "back" || it == "front" },
                w = w,
                h = h,
                fps = Json.int(obj["fps"]) ?: DEFAULT_FPS,
            ).clamped()
        }
    }
}

/** The states of docs/PROTOCOL.md "Camera", in wire spelling. */
enum class CameraState(val wire: String) {
    STREAMING("streaming"),
    BUSY("busy"),
    OFF("off"),
    LOCKED("locked"),
    DISABLED("disabled"),
    EVICTED("evicted"),
    STOPPED("stopped"),
    ERROR("error"),
}

/** The app → shell `cameraState` payloads (one AIDL method, several shapes). */
object CameraMessages {

    /** A state change for one capture. */
    fun state(stream: Int, state: CameraState, reason: String? = null): String {
        val fields = linkedMapOf<String, Any?>("stream" to stream, "state" to state.wire)
        if (!reason.isNullOrEmpty()) fields["reason"] = reason
        return Json.encode(fields)
    }

    /** The gate and the camera list, pushed whenever either changes. */
    fun gate(allowed: Boolean, cams: List<CameraInfo>): String = Json.encode(
        linkedMapOf(
            "allowed" to allowed,
            "cams" to cams.map { it.toMap() },
        ),
    )

    /** The wire's `cam.state` (the shell relays this; the JVM test pins it). */
    fun wireState(stream: Int, state: String, reason: String?): Map<String, Any?> {
        val fields = linkedMapOf<String, Any?>("t" to "cam.state", "stream" to stream, "state" to state)
        if (!reason.isNullOrEmpty()) fields["reason"] = reason
        return fields
    }
}

/** One camera as `cam.cams` advertises it. */
data class CameraInfo(val id: String, val facing: String, val w: Int, val h: Int) {
    fun toMap(): Map<String, Any?> =
        linkedMapOf("id" to id, "facing" to facing, "w" to w, "h" to h)

    companion object {
        fun from(value: Any?): CameraInfo? {
            val obj = Json.asObject(value) ?: return null
            val id = Json.str(obj["id"]) ?: return null
            return CameraInfo(
                id = id,
                facing = Json.str(obj["facing"]) ?: "back",
                w = Json.int(obj["w"]) ?: CameraSpec.DEFAULT_W,
                h = Json.int(obj["h"]) ?: CameraSpec.DEFAULT_H,
            )
        }

        fun list(value: Any?): List<CameraInfo> =
            Json.asList(value).orEmpty().mapNotNull { from(it) }
    }
}
