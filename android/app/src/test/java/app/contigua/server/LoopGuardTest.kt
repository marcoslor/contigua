package app.contigua.server

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class LoopGuardTest {
    private val own = "app.contigua"
    private val chrome = "com.android.chrome"

    @Test
    fun keepsTheDefaultWhenItIsNotUs() {
        assertEquals("org.firefox", LoopGuard.pick("org.firefox", listOf(chrome, own, "org.firefox")))
    }

    @Test
    fun weAreTheDefaultSoPickAnother() {
        assertEquals(chrome, LoopGuard.pick(own, listOf(own, chrome)))
    }

    @Test
    fun resolverIsNeverPicked() {
        assertEquals(chrome, LoopGuard.pick("android", listOf(own, chrome)))
    }

    @Test
    fun onlyUsMeansNoHandler() {
        assertNull(LoopGuard.pick(own, listOf(own)))
        assertNull(LoopGuard.pick(null, emptyList()))
    }
}
