package dev.pocketdeck.app

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Android 16 Live Updates (docs/design/notify.md, "Part 2b design"): the
 * promoted-ongoing gate, the ProgressStyle fraction, the chip cap, the
 * chronometer and the one-per-second coalescing.
 */
class NotifyLiveTest {

    @Test
    fun `only a promoted ongoing notification is live`() {
        val promoted = NotifyEvents.FLAG_PROMOTED_ONGOING
        assertTrue(NotifyEvents.promoted(flags = promoted, ongoing = true))
        assertFalse(NotifyEvents.promoted(flags = promoted, ongoing = false))
        assertFalse(NotifyEvents.promoted(flags = 0, ongoing = true))
        // Other flags do not make it promoted.
        assertFalse(NotifyEvents.promoted(flags = 0x100 or 0x2, ongoing = true))
    }

    @Test
    fun `the progress fraction is value over max, clamped`() {
        assertEquals(0.0, NotifyEvents.progressFraction(0, 100)!!, 0.0001)
        assertEquals(0.42, NotifyEvents.progressFraction(42, 100)!!, 0.0001)
        assertEquals(1.0, NotifyEvents.progressFraction(120, 100)!!, 0.0001)
        // A segmented style's max is the sum of its segment lengths.
        assertEquals(0.5, NotifyEvents.progressFraction(50, 25 + 25 + 25 + 25)!!, 0.0001)
        assertNull(NotifyEvents.progressFraction(10, 0))
        assertNull(NotifyEvents.progressFraction(10, -1))
        assertNull(NotifyEvents.progressFraction(-1, 100))
    }

    @Test
    fun `the live field carries progress, a capped chip and a chronometer`() {
        val live = NotifyEvents.liveWire(0.5, "  4 min to arrival  ", 1_700_000_000_000, countDown = true)!!
        assertEquals(0.5, live["progress"] as Double, 0.0001)
        assertEquals(16, (live["chip"] as String).length)
        assertEquals(1_700_000_000_000L, live["chrono"])
        assertEquals(true, live["countDown"])
    }

    @Test
    fun `a blank chip and a non-positive chrono are left out`() {
        val live = NotifyEvents.liveWire(0.25, "   ", 0, countDown = true)!!
        assertEquals(0.25, live["progress"] as Double, 0.0001)
        assertFalse(live.containsKey("chip"))
        assertFalse(live.containsKey("chrono"))
        // countDown without a chrono means nothing.
        assertFalse(live.containsKey("countDown"))
    }

    @Test
    fun `nothing to say is no live field`() {
        assertNull(NotifyEvents.liveWire(null, null, null, countDown = false))
        assertNull(NotifyEvents.liveWire(null, "  ", 0, countDown = true))
    }

    @Test
    fun `the post event carries live and keeps its other fields`() {
        val live = NotifyEvents.liveWire(0.7, "12 min", null, false)!!
        val event = NotifyEvents.notificationEvent(
            id = "0_com.uber_1_null_7", pkg = "com.uber", title = "Ride", text = "Arriving",
            when_ = 5, ongoing = true, live = live,
        )!!
        assertEquals("notify.post", event["t"])
        assertEquals(true, event["ongoing"])
        assertNotNull(event["live"])
        assertEquals(0.7, (event["live"] as Map<*, *>)["progress"] as Double, 0.0001)
    }

    @Test
    fun `a post without live has no live field`() {
        val event = NotifyEvents.notificationEvent("k", "com.a", "t", "x", 1)!!
        assertFalse(event.containsKey("live"))
    }

    @Test
    fun `live updates are coalesced to one per second per id`() {
        val throttle = NotifyLiveThrottle()
        assertTrue(throttle.due("a", 1_000))
        assertFalse(throttle.due("a", 1_100))
        assertFalse(throttle.due("a", 1_999))
        assertEquals(1_000L, throttle.waitMs("a", 1_000))
        assertEquals(1L, throttle.waitMs("a", 1_999))
        assertTrue(throttle.due("a", 2_000))
        // A different id has its own window.
        assertTrue(throttle.due("b", 2_100))
        // Forgetting the id (removed, session over) frees it at once.
        throttle.forget("a")
        assertTrue(throttle.due("a", 2_200))
        throttle.clear()
        assertTrue(throttle.due("a", 2_300))
        assertEquals(1_000L, throttle.waitMs("a", 2_300))
    }
}
