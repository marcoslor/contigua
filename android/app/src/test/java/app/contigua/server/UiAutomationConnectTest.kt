package app.contigua.server

import android.app.UiAutomation
import android.content.Context
import android.os.Looper
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import java.util.concurrent.atomic.AtomicInteger
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.annotation.Config

@RunWith(AndroidJUnit4::class)
@Config(sdk = [34])
class UiAutomationConnectTest {

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

    /** WIN-79: a connect that outlasts the read's 2.5 s wait is kept when it
     *  lands, and the next read uses it instead of connecting again (the
     *  platform refuses a second connection while the first is held, and that
     *  refusal must not drop the one that works). */
    @Test(timeout = 30_000)
    fun aSlowConnectIsKeptAndNeverMadeTwice() {
        val made = automation()
        val calls = AtomicInteger()
        val tree = UiAutomationTree(log = {}, connector = {
            if (calls.incrementAndGet() == 1) {
                Thread.sleep(3_000) // real-time: longer than the read's wait
                made
            } else {
                throw IllegalStateException("one connection at a time")
            }
        })
        try {
            assertNull("the first read gives up at 2.5 s", tree.ensureAutomation())
            assertSame("the slow connect lands during the next read's wait", made, tree.ensureAutomation())
            assertSame(made, tree.ensureAutomation())
            assertEquals("one connect, never a second", 1, calls.get())
        } finally {
            tree.disconnect()
        }
    }
}
