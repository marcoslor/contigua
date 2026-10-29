package dev.pocketdeck.server

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.net.Socket

/**
 * PAIR-22's option set: the five kernel values are a pure function so a change
 * to any of them is a visible test failure, and the apply step never throws
 * where the platform does not expose a descriptor (it must not fail a session).
 */
class TcpKeepaliveTest {

    @Test
    fun theOptionSetIsExactlyTheFiveDocumentedValues() {
        assertEquals(
            listOf(
                TcpSocketOption(TcpOption.KEEP_ALIVE, 1),
                TcpSocketOption(TcpOption.KEEP_IDLE_SECONDS, 20),
                TcpSocketOption(TcpOption.KEEP_INTERVAL_SECONDS, 5),
                TcpSocketOption(TcpOption.KEEP_COUNT, 4),
                TcpSocketOption(TcpOption.USER_TIMEOUT_MS, 40_000),
            ),
            TcpKeepalive.options(),
        )
        assertEquals(
            TcpOption.entries.toSet(),
            TcpKeepalive.options().map { it.option }.toSet(),
        )
    }

    @Test
    fun aSocketWithNoPlatformDescriptorIsReportedAndNeverThrows() {
        Socket().use { socket ->
            val result = TcpKeepalive.apply(socket)
            assertNotEquals("the JVM socket must not report success", 0, result)
        }
    }

    @Test
    fun theBoundIsWellInsideTheKernelsRetransmitGiveUp() {
        // 20 s idle + 4 probes 5 s apart = 40 s of silence before the kernel
        // says the peer is gone; the replied-to keepalives of a healthy Mac
        // never count.
        val probeWindows = TcpKeepalive.IDLE_SECONDS + TcpKeepalive.INTERVAL_SECONDS * (TcpKeepalive.COUNT - 1)
        assertTrue("keepalive needs ${probeWindows}s", probeWindows <= 60)
    }
}
