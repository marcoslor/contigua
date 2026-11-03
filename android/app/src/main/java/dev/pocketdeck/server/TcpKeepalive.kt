package dev.pocketdeck.server

import android.system.Os
import android.system.OsConstants
import java.io.FileDescriptor
import java.net.Socket

/** The five kernel options a session socket gets, in the order it gets them. */
enum class TcpOption {
    KEEP_ALIVE,
    KEEP_IDLE_SECONDS,
    KEEP_INTERVAL_SECONDS,
    KEEP_COUNT,
    USER_TIMEOUT_MS,
}

data class TcpSocketOption(val option: TcpOption, val value: Int)

/**
 * How a session's TCP connection notices a peer that vanished without a FIN
 * (docs/specs/pairing.md PAIR-22). The phone's reader sits in a blocking read
 * with no timeout once the session is up, so a Mac that dropped off the
 * network is otherwise noticed only when a write finally fails — the kernel's
 * retransmit give-up, about 15 minutes. Keepalives are answered by the Mac's
 * kernel even while its app is App-Napped, so this never drops a healthy
 * session, and `TCP_USER_TIMEOUT` bounds an unacknowledged write as well.
 */
object TcpKeepalive {
    const val IDLE_SECONDS = 20
    const val INTERVAL_SECONDS = 5
    const val COUNT = 4
    const val USER_TIMEOUT_MS = 40_000

    /** No descriptor could be read: the options were not applied at all. */
    const val NO_DESCRIPTOR = -1

    // The platform's OsConstants omits these three, so their Linux tcp.h values
    // live here (IPPROTO_TCP level): TCP_KEEPIDLE, TCP_KEEPINTVL, TCP_KEEPCNT.
    private const val TCP_KEEPIDLE = 4
    private const val TCP_KEEPINTVL = 5
    private const val TCP_KEEPCNT = 6

    /** The option set, a pure function so the values are pinned by a test. */
    fun options(): List<TcpSocketOption> = listOf(
        TcpSocketOption(TcpOption.KEEP_ALIVE, 1),
        TcpSocketOption(TcpOption.KEEP_IDLE_SECONDS, IDLE_SECONDS),
        TcpSocketOption(TcpOption.KEEP_INTERVAL_SECONDS, INTERVAL_SECONDS),
        TcpSocketOption(TcpOption.KEEP_COUNT, COUNT),
        TcpSocketOption(TcpOption.USER_TIMEOUT_MS, USER_TIMEOUT_MS),
    )

    /**
     * Applies [options] to [socket]'s descriptor. Returns 0 on success, the
     * kernel's errno for a refused option, or [NO_DESCRIPTOR] when the accepted
     * socket cannot be reached — never throws: a session must serve without it.
     */
    fun apply(socket: Socket): Int {
        val fd = fileDescriptorOf(socket) ?: return NO_DESCRIPTOR
        for (option in options()) {
            val (level, name) = kernelOption(option.option)
            try {
                Os.setsockoptInt(fd, level, name, option.value)
            } catch (e: Throwable) {
                return if (e is android.system.ErrnoException) e.errno else NO_DESCRIPTOR
            }
        }
        return 0
    }

    private fun kernelOption(option: TcpOption): Pair<Int, Int> = when (option) {
        TcpOption.KEEP_ALIVE -> OsConstants.SOL_SOCKET to OsConstants.SO_KEEPALIVE
        TcpOption.KEEP_IDLE_SECONDS -> OsConstants.IPPROTO_TCP to TCP_KEEPIDLE
        TcpOption.KEEP_INTERVAL_SECONDS -> OsConstants.IPPROTO_TCP to TCP_KEEPINTVL
        TcpOption.KEEP_COUNT -> OsConstants.IPPROTO_TCP to TCP_KEEPCNT
        TcpOption.USER_TIMEOUT_MS -> OsConstants.IPPROTO_TCP to OsConstants.TCP_USER_TIMEOUT
    }

    /**
     * The accepted socket's descriptor. The server runs under
     * `app_process` at the shell UID and owns a plain `java.net.Socket`, whose
     * descriptor the platform exposes to the framework through the hidden
     * `getFileDescriptor$()`/`getInt$()` pair — the same route the framework's
     * own socket code takes; the repo's other shell-side probes use hidden
     * members the same way. Null when they are not there.
     */
    private fun fileDescriptorOf(socket: Socket): FileDescriptor? {
        return try {
            val getDescriptor = Socket::class.java.getDeclaredMethod("getFileDescriptor$")
            getDescriptor.isAccessible = true
            val descriptor = getDescriptor.invoke(socket) as? FileDescriptor ?: return null
            // Fail here rather than hand the kernel descriptor 0 (stdin) if the
            // accessor is gone: the caller logs the failure and serves anyway.
            val getInt = FileDescriptor::class.java.getDeclaredMethod("getInt$")
            getInt.isAccessible = true
            if ((getInt.invoke(descriptor) as? Int ?: -1) < 0) null else descriptor
        } catch (e: Throwable) {
            null
        }
    }
}
