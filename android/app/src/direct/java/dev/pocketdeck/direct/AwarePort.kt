package dev.pocketdeck.direct

import java.net.ServerSocket

/**
 * One Aware data path as the phone sees it, reduced to what the listener needs
 * (docs/design/direct-link.md §4.2). It is an interface so K1 can hand in a
 * fake: the platform's `Network` never reaches the machine.
 */
interface AwareNetwork {
    /** Binds [socket] to the Aware network before it is bound to a port. */
    fun bindSocket(socket: ServerSocket)

    /** The link's estimated bandwidth in kbit/s, or -1 when unknown. */
    fun bandwidthKbps(): Int = -1
}

/**
 * The platform surface the machine drives, one call per platform callback
 * (docs/design/direct-link.md §8.1). Every method runs in the app process:
 * only the app may hold a `WifiAwareSession` or a network it created.
 *
 * The failure callbacks are the platform's own (`onAttachFailed`,
 * `onSessionConfigFailed`); they carry a closed reason token, never a message
 * from the platform.
 */
interface AwarePort {
    fun available(): Boolean

    fun attach(onAttached: () -> Unit, onFailed: (String) -> Unit)

    fun publish(
        ssi: ByteArray,
        passphrase: String,
        onStarted: () -> Unit,
        onFailed: (String) -> Unit,
    )

    /** True when the platform accepted the new service-specific info in place. */
    fun updateSsi(ssi: ByteArray): Boolean

    fun requestNetwork(
        passphrase: String,
        port: Int,
        onAvailable: (AwareNetwork) -> Unit,
        onLost: () -> Unit,
    )

    /** Unregisters the NDP request/callback, if one is live. */
    fun releaseNetwork()

    fun unpublish()

    fun detach()
}
