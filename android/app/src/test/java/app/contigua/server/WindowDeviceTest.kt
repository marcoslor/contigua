package app.contigua.server

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Test

/**
 * WIN-75: one virtual device, made with the first window display and closed
 * with the last. Every state/event pair of [windowDeviceStep], then the holder
 * that performs the two platform calls.
 */
class WindowDeviceTest {

    private val closed = WindowDeviceState.Closed
    private fun open(vararg s: Int) = WindowDeviceState.Open(s.toSet())

    // ---- the pure rule: Closed ------------------------------------------

    @Test
    fun `WIN-75 a closed device is made for the first window`() {
        assertEquals(closed to listOf(WindowDeviceAction.Make), windowDeviceStep(closed, WindowDeviceEvent.Acquire(1)))
    }

    @Test
    fun `WIN-75 a made device opens with its first holder`() {
        assertEquals(
            open(1) to listOf(WindowDeviceAction.UseDevice(1)),
            windowDeviceStep(closed, WindowDeviceEvent.Made(1, ok = true)),
        )
    }

    @Test
    fun `WIN-75 a device that cannot be made sends the window the plain route`() {
        assertEquals(
            closed to listOf(WindowDeviceAction.UsePlain(1)),
            windowDeviceStep(closed, WindowDeviceEvent.Made(1, ok = false)),
        )
    }

    @Test
    fun `WIN-75 a closed device ignores release, lost and stop`() {
        for (event in listOf(WindowDeviceEvent.Release(1), WindowDeviceEvent.Lost, WindowDeviceEvent.Stop)) {
            assertEquals(event.wire, closed to emptyList<WindowDeviceAction>(), windowDeviceStep(closed, event))
        }
    }

    // ---- the pure rule: Open --------------------------------------------

    @Test
    fun `WIN-75 a second window shares the device`() {
        assertEquals(
            open(1, 2) to listOf(WindowDeviceAction.UseDevice(2)),
            windowDeviceStep(open(1), WindowDeviceEvent.Acquire(2)),
        )
    }

    @Test
    fun `WIN-75 an open device is never made again`() {
        assertEquals(open(1) to emptyList<WindowDeviceAction>(), windowDeviceStep(open(1), WindowDeviceEvent.Made(2, ok = true)))
        assertEquals(open(1) to emptyList<WindowDeviceAction>(), windowDeviceStep(open(1), WindowDeviceEvent.Made(2, ok = false)))
    }

    @Test
    fun `WIN-75 a holder that is not the last leaves the device open`() {
        assertEquals(open(2) to emptyList<WindowDeviceAction>(), windowDeviceStep(open(1, 2), WindowDeviceEvent.Release(1)))
    }

    @Test
    fun `WIN-75 the last holder closes the device`() {
        assertEquals(closed to listOf(WindowDeviceAction.Close), windowDeviceStep(open(1), WindowDeviceEvent.Release(1)))
    }

    @Test
    fun `WIN-75 a stream that holds nothing changes nothing`() {
        assertEquals(open(1) to emptyList<WindowDeviceAction>(), windowDeviceStep(open(1), WindowDeviceEvent.Release(9)))
    }

    @Test
    fun `WIN-75 a lost device closes and forgets its holders`() {
        assertEquals(closed to listOf(WindowDeviceAction.Close), windowDeviceStep(open(1, 2), WindowDeviceEvent.Lost))
    }

    @Test
    fun `WIN-75 a stop closes the device`() {
        assertEquals(closed to listOf(WindowDeviceAction.Close), windowDeviceStep(open(1, 2), WindowDeviceEvent.Stop))
    }

    // ---- the holder ------------------------------------------------------

    private class Fake(val id: Int)

    private val made = mutableListOf<Fake>()
    private val closedDevices = mutableListOf<Fake>()
    private val logs = mutableListOf<String>()
    private var failMake = false

    private val holder = WindowDevices(
        make = {
            if (failMake) DeviceMake.Failed("no_association") else DeviceMake.Made(Fake(made.size + 1).also { made.add(it) })
        },
        close = { closedDevices.add(it) },
        log = { logs.add(it) },
    )

    @Test
    fun `WIN-75 two windows share one device, and the last close closes it`() {
        val first = holder.acquire(1)
        val second = holder.acquire(2)
        assertSame(first, second)
        assertEquals(1, made.size)
        holder.release(1)
        assertEquals(emptyList<Fake>(), closedDevices)
        holder.release(2)
        assertEquals(listOf(first), closedDevices)
        assertEquals(WindowDeviceState.Closed, holder.current)
    }

    @Test
    fun `WIN-75 a device that cannot be made answers the plain route and logs its reason`() {
        failMake = true
        assertNull(holder.acquire(1))
        assertEquals(WindowDeviceState.Closed, holder.current)
        assertEquals(listOf("windowdevice: not made reason=no_association"), logs)
        // A plain window's release is no holder's.
        holder.release(1)
        assertEquals(emptyList<Fake>(), closedDevices)
    }

    @Test
    fun `WIN-75 after a lost device the next window makes a new one`() {
        val first = holder.acquire(1)
        holder.lost()
        assertEquals(listOf(first), closedDevices)
        val next = holder.acquire(1)
        assertEquals(2, made.size)
        assertSame(made[1], next)
        // The old stream's late release must not close the new device's holder set.
        holder.release(2)
        assertEquals(WindowDeviceState.Open(setOf(1)), holder.current)
    }

    @Test
    fun `WIN-75 a stop closes the device and later releases are ignored`() {
        val first = holder.acquire(1)
        holder.stop()
        holder.release(1)
        assertEquals(listOf(first), closedDevices)
    }

    @Test
    fun `WIN-75 the log carries states and counts only`() {
        holder.acquire(7)
        holder.release(7)
        assertEquals(
            listOf(
                "windowdevice: Closed --made--> Open holders=1",
                "windowdevice: Open --release--> Closed holders=0",
            ),
            logs,
        )
    }
}
