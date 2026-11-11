package app.contigua.server

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

    /** The phone pins nothing for this Mac and the Mac did not ask to pair. */
    NOT_PAIRED("not_paired"),

    /** No pin and no pairing attempt while pairings are off: no reply at all. */
    CLOSE_SILENT(null),
}

object ConnectionGate {

    /**
     * The pure gate: the master switch covers every Mac, the pairing switch
     * only Macs the phone has never paired with. A missing setting refuses
     * like the master being off, never like the permissive default.
     *
     * [isPairing] is the Mac's own intent (its hello said so, or a scanned QR
     * named it). A Mac that believes it is paired but which the phone pins
     * nothing for is answered `not_paired` — at once, never by a timeout
     * (PAIR-23) — or closed without a word when pairings are off (PAIR-12).
     */
    fun decide(settings: GateSettings?, isPaired: Boolean, isPairing: Boolean): GateDecision = when {
        settings == null || !settings.allowConnections -> GateDecision.REFUSE_CONNECTIONS_OFF
        isPaired -> GateDecision.ACCEPT
        isPairing && !settings.allowPairings -> GateDecision.REFUSE_PAIRING_OFF
        isPairing -> GateDecision.ACCEPT
        settings.allowPairings -> GateDecision.NOT_PAIRED
        else -> GateDecision.CLOSE_SILENT
    }
}
