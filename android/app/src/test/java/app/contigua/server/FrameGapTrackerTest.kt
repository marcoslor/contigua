package app.contigua.server

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The press-gap measurement (round 3): the largest gap between consecutive VD
 * frames around the screen-off edge, not the first frame after it (a VD can emit
 * a frame it made before its group slept).
 */
class FrameGapTrackerTest {

    @Test
    fun theReviewersExampleMeasuresTheSilenceAcrossTheEdge() {
        val gaps = FrameGapTracker()
        gaps.onFrame(0)
        gaps.onFrame(400)
        gaps.markEdge(1_000)
        gaps.onFrame(1_900)
        gaps.onFrame(2_300)
        assertEquals("the 1.9 s frame closes a 1500 ms gap", 1_500L, gaps.closeIfDue(4_100))
        assertEquals(4, gaps.framesSeen)
    }

    @Test
    fun theWindowIsClosedByItsDeadlineNotByTheCaller() {
        val gaps = FrameGapTracker()
        gaps.onFrame(400)
        gaps.markEdge(1_000)
        gaps.onFrame(1_900)
        assertNull("inside the window", gaps.closeIfDue(3_999))
        assertEquals(1_500L, gaps.closeIfDue(4_000))
        assertNull("a second close reports nothing", gaps.closeIfDue(5_000))
    }

    @Test
    fun framesOutsideTheWindowAreIgnored() {
        val gaps = FrameGapTracker(beforeMs = 1_000, afterMs = 3_000)
        gaps.onFrame(100)             // before edge − 1 s (1000): not in the window
        gaps.onFrame(900)             // still before it
        gaps.onFrame(1_900)           // the seed
        gaps.markEdge(2_000)
        gaps.onFrame(2_100)           // the only gap in the window
        gaps.onFrame(5_100)           // after edge + 3 s (5000)
        assertEquals("200 ms is the only gap in the window", 200L, gaps.closeIfDue(5_000))
        assertEquals(2, gaps.framesSeen)
    }

    @Test
    fun aStreamThatNeverDrawsAgainStillReportsItsSilence() {
        val gaps = FrameGapTracker()
        gaps.onFrame(0)
        gaps.onFrame(500)
        gaps.markEdge(1_000)
        // Nothing after the edge: the silence from the seed to the window's end
        // (4000) is the gap, so a frozen VD cannot read as a perfect zero.
        assertEquals(3_500L, gaps.closeIfDue(4_000))
        assertEquals("the two frames before the edge are in the window", 2, gaps.framesSeen)
    }

    @Test
    fun aFastStreamHasNoLargeGap() {
        val gaps = FrameGapTracker()
        var t = 0L
        while (t <= 900) { gaps.onFrame(t); t += 100 }
        gaps.markEdge(1_000)
        t = 1_000
        while (t <= 3_900) { gaps.onFrame(t); t += 100 }
        assertEquals(100L, gaps.closeIfDue(4_000))
        assertTrue(gaps.framesSeen > 2)
    }

    @Test
    fun aSecondEdgeStartsACleanMeasurement() {
        val gaps = FrameGapTracker()
        gaps.onFrame(0)
        gaps.markEdge(500)
        gaps.onFrame(2_500)
        assertEquals(2_500L, gaps.closeIfDue(3_600))
        gaps.markEdge(10_000)
        gaps.onFrame(10_100)
        gaps.onFrame(10_200)
        assertEquals("the old gap is gone", 100L, gaps.closeIfDue(13_100))
        assertEquals(2, gaps.framesSeen)
    }
}
