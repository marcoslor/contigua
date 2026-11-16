package app.contigua.server

import android.accessibilityservice.AccessibilityServiceInfo
import android.os.Handler
import android.os.Looper
import android.view.accessibility.AccessibilityEvent
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config

/**
 * WIN-79 F3: one `UiAutomation` connection per process. Every session's factory
 * asks the same owner and gets the same source; only the service's stop
 * disconnects it, never a session ending.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
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

    /** MCP-107: no event stream unless a watch runs, and then only the five content changes. */
    @Test
    fun MCP107_theConnectionAsksOnlyForContentChanges() {
        assertEquals(
            AccessibilityEvent.TYPE_WINDOW_CONTENT_CHANGED or AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED or
                AccessibilityEvent.TYPE_WINDOWS_CHANGED or AccessibilityEvent.TYPE_VIEW_TEXT_CHANGED or
                AccessibilityEvent.TYPE_VIEW_SCROLLED,
            SettleWatch.EVENT_MASK,
        )
        // The connection starts deaf.
        val info = AccessibilityServiceInfo()
        info.eventTypes = AccessibilityEvent.TYPES_ALL_MASK
        UiAutomationTree.configure(info)
        assertEquals(0, info.eventTypes)
        assertTrue(info.flags and AccessibilityServiceInfo.FLAG_RETRIEVE_INTERACTIVE_WINDOWS != 0)
        // A watch's Listen sets the mask; its end (StopListening) clears it.
        val port = UiAutomationTreeTest.FakePort()
        val looper = shadowOf(Looper.getMainLooper())
        val watches = SettleWatches(Handler(Looper.getMainLooper()), port, log = {}, now = { 0L }, runCheck = {})
        val owner = Any()
        watches.start(owner, 5, 300, 2_000, 0)!!
        looper.idle()
        assertEquals(listOf(SettleWatch.EVENT_MASK), port.masks)
        watches.cancel(owner)
        looper.idle()
        assertEquals(listOf(SettleWatch.EVENT_MASK, 0), port.masks)
    }

    /** MCP-81: `ui.settle` answers only PROTOCOL.md "UI tree" item 7's codes. */
    @Test
    fun MCP81_settleAnswersOnlyProtocolCodes() {
        val protocol = setOf("no_window", "no_display", "not_available", "busy", "failed")
        assertTrue(protocol.containsAll(UiCodes.SETTLE))
        // A source that cannot connect answers not_available, never no_a11y.
        val source = UiAutomationTree {}
        source.disconnect()
        val answer = source.settle(5, 300, 2_000, 0, Any())
        assertEquals(UiCodes.NOT_AVAILABLE, (answer as SettleAnswer.Failure).code)
        assertTrue(answer.code in protocol)
    }
}
