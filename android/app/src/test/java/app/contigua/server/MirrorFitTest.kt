package app.contigua.server

import org.junit.Assert.assertEquals
import org.junit.Test

class MirrorFitTest {

    @Test
    fun boxTurnsWithTheScreen() {
        assertEquals(IntSize(800, 400), MirrorFit.turnBox(IntSize(400, 800), IntSize(2340, 1080)))
        assertEquals(IntSize(400, 800), MirrorFit.turnBox(IntSize(400, 800), IntSize(1080, 2340)))
    }
}
