package dev.pocketdeck.server

import org.junit.Assert.assertEquals
import org.junit.Test

class MirrorFitTest {

    @Test
    fun fitsInsideTheBoxAtTheScreensAspect() {
        assertEquals(IntSize(368, 800), MirrorFit.fit(IntSize(400, 800), IntSize(1080, 2340)))
        assertEquals(IntSize(400, 864), MirrorFit.fit(IntSize(400, 2000), IntSize(1080, 2340)))
    }

    @Test
    fun neverUpscalesPastTheScreen() {
        assertEquals(IntSize(1072, 2336), MirrorFit.fit(IntSize(4000, 4000), IntSize(1080, 2340)))
    }

    @Test
    fun boxTurnsWithTheScreen() {
        assertEquals(IntSize(800, 400), MirrorFit.turnBox(IntSize(400, 800), IntSize(2340, 1080)))
        assertEquals(IntSize(400, 800), MirrorFit.turnBox(IntSize(400, 800), IntSize(1080, 2340)))
    }
}
