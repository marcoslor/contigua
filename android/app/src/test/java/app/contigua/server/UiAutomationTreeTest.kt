package app.contigua.server

import android.os.Handler
import android.os.Looper
import org.junit.Assert.assertEquals
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config

/** MCP-107: the settle watch's state lives on its looper only. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class UiAutomationTreeTest {

    /** A port with display 5 holding window 9; records the masks it was set to. */
    class FakePort : SettlePort {
        val masks = ArrayList<Int>()
        override fun windows(): Map<Int, List<Int>> = mapOf(5 to listOf(9))
        override fun loading(displayId: Int, stale: () -> Boolean): Boolean = false
        override fun setEventTypes(mask: Int) { masks.add(mask) }
    }

    private fun events(watch: SettleWatches.Watch): Int = when (val s = watch.state) {
        is SettleWatch.State.Watching -> s.events
        is SettleWatch.State.Checking -> s.events
        SettleWatch.State.Idle -> -1
    }

    /**
     * A failed connect logs the wrapper's class and its root cause's class,
     * and nothing of either message (logs carry codes and classes only).
     */
    @Test
    fun testAConnectFailureLogsItsRootClassOnly() {
        val refusal = IllegalStateException("UiAutomationService android.accessibilityservice.IAccessibilityServiceClient already registered!")
        val wrapped = java.lang.reflect.InvocationTargetException(RuntimeException("binder: com.example", refusal))
        assertEquals(
            "ui.tree: connect InvocationTargetException root=IllegalStateException",
            UiAutomationTree.connectFailureLine(wrapped),
        )
        assertEquals(
            "ui.tree: connect SecurityException root=SecurityException",
            UiAutomationTree.connectFailureLine(SecurityException("uid 2000 is not allowed")),
        )
    }

    @Test
    fun MCP107_anEventFromAnotherThreadRunsOnTheWatchLooper() {
        val looper = shadowOf(Looper.getMainLooper())
        val watches = SettleWatches(Handler(Looper.getMainLooper()), FakePort(), log = {}, now = { 0L }, runCheck = {})
        val watch = watches.start(Any(), 5, 300, 2_000, 0)!!
        looper.idle()
        assertEquals(0, events(watch))
        // The listener fires on a thread of the platform's choosing.
        val other = Thread { watches.deliver(SettleWatch.TYPE_WINDOW_CONTENT_CHANGED, 9) }
        other.start()
        other.join()
        // Nothing touched the watch off its looper...
        assertEquals(0, events(watch))
        // ...the event runs when the looper does.
        looper.idle()
        assertEquals(1, events(watch))
    }
}
