package app.contigua.server

import android.app.UiAutomation
import android.content.Context
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import androidx.test.core.app.ApplicationProvider
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

    /**
     * `initCause` refuses only a throwable's own self, so a chain can loop
     * (A caused by B caused by A). The line is still written, and the connect
     * thread never spins on it.
     */
    @Test(timeout = 5_000)
    fun testAConnectFailureWithACauseLoopStillLogs() {
        val outer = RuntimeException("a")
        val inner = IllegalStateException("b", outer)
        outer.initCause(inner)
        val line = UiAutomationTree.connectFailureLine(outer)
        assertEquals(true, line.startsWith("ui.tree: connect RuntimeException root="))
    }

    /** An unconnected `UiAutomation`, built the way the tree builds its own. */
    private fun automation(): UiAutomation {
        val iface = Class.forName("android.app.IUiAutomationConnection")
        val connection = Class.forName("android.app.UiAutomationConnection")
            .getDeclaredConstructor().newInstance()
        return runCatching {
            UiAutomation::class.java.getDeclaredConstructor(Context::class.java, iface)
                .newInstance(ApplicationProvider.getApplicationContext<Context>(), connection)
        }.getOrElse {
            UiAutomation::class.java.getDeclaredConstructor(Looper::class.java, iface)
                .newInstance(Looper.getMainLooper(), connection)
        }
    }

    /**
     * #273: a session ends before any `ui.tree` or `ui.settle` started the
     * watch thread, so `cancel` finds no watch to cancel and the end is lost.
     * Its own settle then starts the thread and answers a session that is gone
     * (MCP-81). The end is kept: the watch it starts answers nothing.
     */
    @Test(timeout = 10_000)
    fun aCancelBeforeTheWatchThreadExistsSendsNothing() { // [MCP-81]
        val made = automation()
        val tree = UiAutomationTree(log = {})
        tree.connector = { made }
        val ended = Any()
        try {
            tree.cancel(ended) // no `ui.tree` or `ui.settle` has started the watch thread yet
            val answer = tree.settle(5, 300, 200, SystemClock.uptimeMillis(), ended)
            assertEquals("the ended session's watch answers nothing", SettleAnswer.Cancelled, answer)
        } finally {
            tree.disconnect()
        }
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
