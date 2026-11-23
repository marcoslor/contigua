package app.contigua.server

import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.assertEquals
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.annotation.Config

@RunWith(AndroidJUnit4::class)
@Config(sdk = [34])
class DeckServiceStateTest {

    /** MCP-31: the service's own `state` read (sent after `welcome` when the
     *  state watch cannot subscribe, and in a panel or phone.* answer before the
     *  watch's first update) names `initial_read` like the watch's first read. */
    @Test
    fun theServiceStateReadNamesItsLockSource() {
        assertEquals(LockSource.INITIAL_READ, DeckService(null).state().lockSource)
    }
}
