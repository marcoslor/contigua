package dev.pocketdeck.direct

import java.net.Socket

/**
 * DIRECT-17's app half: every socket the Aware listener accepts goes to the
 * shell as a descriptor. The app closes its own copy once the shell has the fd;
 * when the shell cannot wrap it, the two ends are bridged byte for byte instead
 * and `path-bridge` is logged once.
 */
class DirectPathHandoff(
    private val handOver: (Socket) -> Boolean,
    private val bridge: (Socket) -> Boolean,
    private val close: (Socket) -> Unit = { runCatching { it.close() } },
    private val log: (String) -> Unit = {},
) {
    private var bridgeLogged = false

    /** True when the socket is now served by the shell, over the fd or the bridge. */
    @Synchronized
    fun deliver(socket: Socket): Boolean {
        if (runCatching { handOver(socket) }.getOrDefault(false)) {
            close(socket)
            return true
        }
        if (runCatching { bridge(socket) }.getOrDefault(false)) {
            if (!bridgeLogged) {
                bridgeLogged = true
                log("path-bridge")
            }
            return true
        }
        close(socket)
        return false
    }
}
