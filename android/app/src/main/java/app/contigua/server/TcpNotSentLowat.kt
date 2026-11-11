package app.contigua.server

import android.system.Os
import android.system.OsConstants
import java.net.Socket

/**
 * R4: bounds the bytes the kernel has accepted but not yet put on the wire, so
 * the app's own queue order is what decides whether audio waits behind video.
 * A 128 KiB send buffer alone lets 128 KiB of video sit ahead of an audio
 * packet inside the kernel, where no queue priority can help.
 *
 * `TCP_NOTSENT_LOWAT` is Linux's tcp.h option 25 at the TCP level; the
 * platform's OsConstants does not name it. A kernel that refuses it changes
 * nothing else (the session serves without it).
 */
object TcpNotSentLowat {
    /** About one 16 KiB video chunk: R4's kernel-buffer half. */
    const val BYTES = 16 * 1024
    const val OPTION = 25

    /** 0 on success, the kernel's errno, or TcpKeepalive.NO_DESCRIPTOR. */
    fun apply(socket: Socket): Int {
        val fd = TcpKeepalive.fileDescriptorOf(socket) ?: return TcpKeepalive.NO_DESCRIPTOR
        return try {
            Os.setsockoptInt(fd, OsConstants.IPPROTO_TCP, OPTION, BYTES)
            0
        } catch (e: Throwable) {
            if (e is android.system.ErrnoException) e.errno else TcpKeepalive.NO_DESCRIPTOR
        }
    }
}
