package app.contigua.server

import org.junit.Assert.assertFalse
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * WIN-79 F3: one `UiAutomation` connection per process. Every session's factory
 * asks the same owner and gets the same source; only the service's stop
 * disconnects it, never a session ending.
 */
class UiTreeSourceTest {

    @Test
    fun WIN79_sessionsShareOneTreeSource() {
        val owner = UiTreeSourceOwner {}
        val first = owner.get()
        val second = owner.get()
        // Two sessions get the one process-wide source, not one each.
        assertSame(first, second)
        assertFalse("the source starts live", first.disconnected)
        // The service stop disconnects it; a session close never does.
        owner.disconnect()
        assertTrue(first.disconnected)
        // Idempotent: a second stop is a no-op.
        owner.disconnect()
        assertTrue(first.disconnected)
    }

    /** MCP-107: only a debug build with `debug.contigua.ui_cache=keep` skips the cache clear. */
    @Test
    fun MCP107_theCacheClearIsSkippedOnlyByTheDebugKnob() {
        assertTrue(UiCacheDebug.keep(true, "keep"))
        assertFalse(UiCacheDebug.keep(false, "keep"))
        assertFalse(UiCacheDebug.keep(true, null))
        assertFalse(UiCacheDebug.keep(true, "1"))
    }
}
