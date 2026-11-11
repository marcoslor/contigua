package app.contigua.server

import org.junit.Assert.assertEquals
import org.junit.Test

class AppExitTest {

    @Test
    fun closesOnlyStreamsThatLostTheirTask() {
        val previous = mapOf(1 to true, 2 to false, 3 to true)
        val current = mapOf(1 to false, 2 to false, 3 to true)
        assertEquals(listOf(1), AppExit.exited(previous, current))
    }

    @Test
    fun neverClosesAStreamThatNeverHadATask() {
        assertEquals(emptyList<Int>(), AppExit.exited(mapOf(1 to false), mapOf(1 to false)))
        assertEquals(emptyList<Int>(), AppExit.exited(emptyMap(), mapOf(1 to false)))
    }

    @Test
    fun closesWhenTheStreamIsMissingFromTheCurrentSnapshot() {
        assertEquals(listOf(7), AppExit.exited(mapOf(7 to true), emptyMap()))
    }
}
