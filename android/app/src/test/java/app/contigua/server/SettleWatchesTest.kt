package app.contigua.server

import android.os.Handler
import android.os.Looper
import org.junit.Assert.assertEquals
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config

/** The running `ui.settle` watches on their looper (docs/PROTOCOL.md "UI tree" item 7). */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class SettleWatchesTest {

    /** A port whose window list the test changes; records the masks it was set to. */
    private class Port(var listed: Map<Int, List<Int>>) : SettlePort {
        val masks = ArrayList<Int>()
        override fun windows(): Map<Int, List<Int>> = listed
        override fun loading(displayId: Int, stale: () -> Boolean): Boolean = false
        override fun setEventTypes(mask: Int) { masks.add(mask) }
    }

    private val looper = shadowOf(Looper.getMainLooper())

    private fun watches(port: SettlePort) =
        SettleWatches(Handler(Looper.getMainLooper()), port, log = {}, now = { 0L }, runCheck = {})

    private fun events(watch: SettleWatches.Watch): Int = when (val s = watch.state) {
        is SettleWatch.State.Watching -> s.events
        is SettleWatch.State.Checking -> s.events
        SettleWatch.State.Idle -> -1
    }

    /**
     * A dialog closing on display 5: the platform's windows-changed names the
     * removed window, which the re-read no longer lists. It was on the display
     * before the read, so it counts.
     */
    @Test
    fun aWindowRemovedFromTheDisplayCountsAsAChange() { // [MCP-107]
        val port = Port(mapOf(5 to listOf(9, 11)))
        val all = watches(port)
        val watch = all.start(Any(), 5, 300, 2_000, 0)!!
        looper.idle()
        assertEquals(0, events(watch))
        port.listed = mapOf(5 to listOf(9))
        all.deliver(SettleWatch.TYPE_WINDOWS_CHANGED, 11)
        looper.idle()
        assertEquals(1, events(watch))
    }
}
