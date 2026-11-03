package dev.pocketdeck.direct

import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket

/**
 * The listener bound to one Aware data path (docs/design/direct-link.md §4.2):
 * the network is bound first, then the specifier's port, then one accept loop
 * hands every Mac socket to the process that serves TLS. One instance per NDP;
 * `start` is idempotent so two callbacks cannot open two loops.
 */
class AwareListener(
    private val network: AwareNetwork,
    private val listenPort: Int,
    private val onAccepted: (Socket) -> Unit,
    private val log: (String) -> Unit = {},
) {
    @Volatile private var listener: ServerSocket? = null
    @Volatile private var thread: Thread? = null

    val isRunning: Boolean get() = listener != null

    val port: Int get() = listener?.localPort ?: -1

    fun start(): Boolean {
        if (listener != null) return true
        val server = ServerSocket()
        return try {
            // The network first: a socket bound to a port before its interface
            // cannot be moved to the Aware link.
            network.bindSocket(server)
            server.reuseAddress = true
            server.bind(InetSocketAddress(listenPort))
            listener = server
            thread = Thread({ acceptLoop(server) }, "pocketdeck-aware-accept").apply {
                isDaemon = true
                start()
            }
            true
        } catch (t: Throwable) {
            runCatching { server.close() }
            log("aware listener: bind failed")
            false
        }
    }

    fun close() {
        listener?.let { runCatching { it.close() } }
        listener = null
        thread = null
    }

    private fun acceptLoop(server: ServerSocket) {
        while (!server.isClosed) {
            val client = try {
                server.accept()
            } catch (t: Throwable) {
                break
            }
            runCatching { client.tcpNoDelay = true }
            onAccepted(client)
        }
    }
}
