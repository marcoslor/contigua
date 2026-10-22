package dev.pocketdeck.server

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.abs

class MirrorFrameTest {
    /** Displays the checks run on: portrait phones, a landscape one (a turned phone). */
    private val screens = listOf(
        IntSize(1080, 2340),
        IntSize(1080, 2400),
        IntSize(1440, 3120),
        IntSize(720, 1600),
        IntSize(2340, 1080),
    )

    /** Boxes the Mac asks for: window sizes, and a huge one. */
    private val boxes = listOf(IntSize(608, 1344), IntSize(400, 800), IntSize(4000, 4000))

    /** A tiny box: a frame of a few hundred pixels cannot match the aspect as closely as a window's. */
    private val tinyBox = IntSize(333, 741)

    private fun aspectError(frame: IntSize, screen: IntSize): Double =
        abs((frame.w.toDouble() / frame.h) / (screen.w.toDouble() / screen.h) - 1.0)

    /** The smallest aspect error any frame on the grid, inside the box, can have: the encoder's best. */
    private fun bestError(box: IntSize, screen: IntSize, align: Int): Double {
        val aspect = screen.w.toDouble() / screen.h
        var best = Double.MAX_VALUE
        for (h in align..minOf(box.h, screen.h) step align) {
            for (w in align..minOf(box.w, screen.w) step align) {
                best = minOf(best, abs((w.toDouble() / h) / aspect - 1.0))
            }
        }
        return best
    }

    /** What a frame may cost over the grid's best for the area it keeps (the content rect crops the rest). */
    private fun slack(align: Int): Double = if (align >= 64) 0.03 else 0.025

    @Test
    fun `the picked frame is on the encoder's grid, inside the box and near the screen's aspect`() {
        for (align in listOf(2, 16, 64)) {
            for (screen in screens) {
                for (box in boxes) {
                    val frame = MirrorFrame.pick(box, screen, IntSize(align, align), Int.MAX_VALUE, Int.MAX_VALUE)
                    val where = "align $align screen ${screen.w}x${screen.h} box ${box.w}x${box.h} -> ${frame.w}x${frame.h}"
                    assertEquals(where, 0, frame.w % align)
                    assertEquals(where, 0, frame.h % align)
                    assertTrue(where, frame.w <= minOf(box.w, screen.w))
                    assertTrue(where, frame.h <= minOf(box.h, screen.h))
                    // As close as the grid allows, give or take what the frame's area costs.
                    val error = aspectError(frame, screen)
                    assertTrue(where + " aspect error $error, best ${bestError(box, screen, align)}",
                        error <= bestError(box, screen, align) + slack(align))
                    if (align <= 16) assertTrue(where + " aspect error $error", error <= 0.01)
                }
            }
        }
    }

    @Test
    fun `a tiny box still gets a legal frame within a few percent of the aspect`() {
        for (align in listOf(2, 16, 64)) {
            for (screen in screens) {
                val frame = MirrorFrame.pick(tinyBox, screen, IntSize(align, align), Int.MAX_VALUE, Int.MAX_VALUE)
                val where = "align $align screen ${screen.w}x${screen.h} -> ${frame.w}x${frame.h}"
                assertEquals(where, 0, frame.w % align)
                assertEquals(where, 0, frame.h % align)
                val error = aspectError(frame, screen)
                assertTrue(where + " aspect error $error, best ${bestError(tinyBox, screen, align)}",
                    error <= bestError(tinyBox, screen, align) + slack(align))
            }
        }
    }

    @Test
    fun `an independent width and height alignment is read, not assumed to be 16`() {
        // The codec may take 2-pixel steps in width and 16 in height: the frame keeps both.
        val frame = MirrorFrame.pick(IntSize(608, 1344), IntSize(1080, 2340), IntSize(2, 16), Int.MAX_VALUE, Int.MAX_VALUE)
        assertEquals(0, frame.w % 2)
        assertEquals(0, frame.h % 16)
        assertTrue(aspectError(frame, IntSize(1080, 2340)) <= 0.01)
    }

    @Test
    fun `the picker keeps the box's size rather than a tiny exact-ratio frame`() {
        // 6:13 has an exact 16-grid frame at 96x208; the box allows a far bigger one.
        val frame = MirrorFrame.pick(IntSize(608, 1344), IntSize(1080, 2340), IntSize(16, 16), Int.MAX_VALUE, Int.MAX_VALUE)
        assertTrue("frame ${frame.w}x${frame.h} is too small", frame.w * frame.h >= 0.75 * 608 * 1344)
    }

    @Test
    fun `the picker takes the next legal size when the encoder refuses the first`() {
        val refused = IntSize(592, 1280)
        val frame = MirrorFrame.pick(IntSize(608, 1344), IntSize(1080, 2340), IntSize(16, 16), Int.MAX_VALUE, Int.MAX_VALUE) {
            w, h -> IntSize(w, h) != refused
        }
        assertTrue(frame != refused)
        assertEquals(0, frame.w % 16)
        assertTrue(aspectError(frame, IntSize(1080, 2340)) <= 0.01)
    }

    @Test
    fun `the encoder's ceiling caps the frame`() {
        val frame = MirrorFrame.pick(IntSize(1080, 2340), IntSize(1080, 2340), IntSize(16, 16), 720, 1600)
        assertTrue(frame.w <= 720)
        assertTrue(frame.h <= 1600)
        assertTrue(aspectError(frame, IntSize(1080, 2340)) <= 0.01)
    }

    @Test
    fun `the content rect is inside the frame, centred, and keeps the screen's aspect`() {
        for (align in listOf(2, 16, 64)) {
            for (screen in screens) {
                for (box in boxes) {
                    val frame = MirrorFrame.pick(box, screen, IntSize(align, align), Int.MAX_VALUE, Int.MAX_VALUE)
                    val rect = MirrorFrame.contentIn(frame, screen)
                    val where = "align $align screen ${screen.w}x${screen.h} frame ${frame.w}x${frame.h} rect $rect"
                    assertTrue(where, rect.x >= 0 && rect.y >= 0)
                    assertTrue(where, rect.x + rect.w <= frame.w && rect.y + rect.h <= frame.h)
                    assertTrue(where, rect.w == frame.w || rect.h == frame.h)
                    assertTrue(where, abs(rect.x - (frame.w - rect.w) / 2) <= 1)
                    assertTrue(where, abs(rect.y - (frame.h - rect.h) / 2) <= 1)
                    // One pixel of rounding per side at most.
                    val ratio = (rect.w.toDouble() / rect.h) / (screen.w.toDouble() / screen.h)
                    assertTrue(where + " rect aspect $ratio", abs(ratio - 1.0) <= 2.0 / minOf(rect.w, rect.h))
                }
            }
        }
    }

    @Test
    fun `a frame of the screen's own aspect is all picture`() {
        assertEquals(IntRect(0, 0, 1080, 2340), MirrorFrame.contentIn(IntSize(1080, 2340), IntSize(1080, 2340)))
    }

    @Test
    fun `a box smaller than the alignment still gives a legal frame`() {
        val frame = MirrorFrame.pick(IntSize(10, 10), IntSize(1080, 2340), IntSize(16, 16), Int.MAX_VALUE, Int.MAX_VALUE)
        assertEquals(0, frame.w % 16)
        assertEquals(0, frame.h % 16)
    }
}
