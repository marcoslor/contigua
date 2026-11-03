package dev.pocketdeck.proto

/**
 * The phone's `direct.state` message (docs/PROTOCOL.md "Direct link",
 * transport DIRECT-12). `on` is the phone's own switch with the permission
 * granted; `reason` is one of four closed tokens and nothing else, so a
 * platform message can never reach the Mac.
 */
data class PhoneDirectState(val on: Boolean, val reason: String? = null) {

    fun message(): Map<String, Any?> {
        val message = LinkedHashMap<String, Any?>()
        message["t"] = "direct.state"
        message["on"] = on
        reason?.let { message["reason"] = it }
        return message
    }

    companion object {
        val REASONS = setOf("no_permission", "no_feature", "location_off", "aware_busy")

        /** [reason] kept only when it is one of [REASONS]. */
        fun of(on: Boolean, reason: String?): PhoneDirectState =
            PhoneDirectState(on, reason?.takeIf { it in REASONS })
    }
}
