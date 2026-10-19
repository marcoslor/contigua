package dev.pocketdeck.server

/**
 * The two user-facing connection gates, pushed from the app process over AIDL.
 * The shell server holds no copy of its own: [null] means the app never
 * delivered the stored values, which refuses everything (fail closed).
 */
data class GateSettings(
    val allowConnections: Boolean,
    val allowPairings: Boolean,
)

/** What the handshake does with one Mac. The code is the wire `error` code. */
enum class GateDecision(val code: String?) {
    ACCEPT(null),
    REFUSE_CONNECTIONS_OFF("connections_off"),
    REFUSE_PAIRING_OFF("pairing_off"),
}

object ConnectionGate {

    /**
     * The pure gate: the master switch covers every Mac, the pairing switch
     * only Macs the phone has never paired with. A missing setting refuses
     * like the master being off, never like the permissive default.
     */
    fun decide(settings: GateSettings?, isPaired: Boolean): GateDecision = when {
        settings == null || !settings.allowConnections -> GateDecision.REFUSE_CONNECTIONS_OFF
        !isPaired && !settings.allowPairings -> GateDecision.REFUSE_PAIRING_OFF
        else -> GateDecision.ACCEPT
    }
}
