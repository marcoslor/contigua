package app.contigua.server

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * The `state` stream's dedupe: the keyguard listener can repeat a value, the
 * sticky battery broadcast arrives once at registration, and the protocol says
 * `state` goes out only on change.
 */
class DeviceStateTrackerTest {

    private val emitted = ArrayList<DeviceState>()
    private val tracker = DeviceStateTracker { emitted.add(it) }

    @Test
    fun `the first state is emitted`() {
        tracker.update(DeviceState(true, 55, false))
        assertEquals(listOf(DeviceState(true, 55, false)), emitted)
    }

    @Test
    fun `a repeated lock event is not re-sent`() {
        tracker.update(DeviceState(false, 55, false))
        tracker.onLockChanged(true, LockSource.KEYGUARD_LISTENER)
        tracker.onLockChanged(true, LockSource.KEYGUARD_LISTENER)
        tracker.onLockChanged(true, LockSource.KEYGUARD_LISTENER)
        assertEquals(2, emitted.size)
        assertEquals(DeviceState(true, 55, false, lockSource = LockSource.KEYGUARD_LISTENER), emitted.last())
    }

    @Test
    fun `locking and unlocking each produce exactly one change`() {
        tracker.update(DeviceState(false, 55, false))
        tracker.onLockChanged(true, LockSource.KEYGUARD_LISTENER)
        tracker.onLockChanged(false, LockSource.KEYGUARD_LISTENER)
        assertEquals(
            listOf(
                DeviceState(false, 55, false),
                DeviceState(true, 55, false, lockSource = LockSource.KEYGUARD_LISTENER),
                DeviceState(false, 55, false, lockSource = LockSource.KEYGUARD_LISTENER),
            ),
            emitted,
        )
    }

    @Test
    fun `a repeated battery event is not re-sent`() {
        tracker.update(DeviceState(false, 55, false))
        tracker.onBatteryChanged(55, false)
        assertEquals(1, emitted.size)
    }

    @Test
    fun `battery level and charging each produce one change`() {
        tracker.update(DeviceState(false, 55, false))
        tracker.onBatteryChanged(54, false)
        tracker.onBatteryChanged(54, true)
        tracker.onBatteryChanged(54, true)
        assertEquals(
            listOf(
                DeviceState(false, 55, false),
                DeviceState(false, 54, false),
                DeviceState(false, 54, true),
            ),
            emitted,
        )
    }

    @Test
    fun `the screen changing sends one state and keeps the other fields`() {
        tracker.update(DeviceState(true, 80, true, screen = ScreenState.ON))
        tracker.onScreenChanged(ScreenState.OFF)
        tracker.onScreenChanged(ScreenState.OFF)
        assertEquals(2, emitted.size)
        assertEquals(DeviceState(true, 80, true, screen = ScreenState.OFF), emitted.last())
        tracker.onScreenChanged(ScreenState.ON)
        assertEquals(DeviceState(true, 80, true, screen = ScreenState.ON), emitted.last())
    }

    @Test
    fun `events keep the fields they do not carry`() {
        tracker.update(DeviceState(true, 80, true))
        tracker.onLockChanged(false, LockSource.KEYGUARD_LISTENER)
        assertEquals(DeviceState(false, 80, true, lockSource = LockSource.KEYGUARD_LISTENER), emitted.last())
        tracker.onBatteryChanged(79, false)
        assertEquals(DeviceState(false, 79, false, lockSource = LockSource.KEYGUARD_LISTENER), emitted.last())
    }

    /** MCP-31: every lock change records the source that reported it, and a
     *  change of source alone is a change (PROTOCOL.md `state.lockSource`). */
    @Test
    fun everyLockChangeNamesItsSource() {
        // The read at start is the source until an event replaces it.
        tracker.update(DeviceState(true, 55, false, lockSource = LockSource.INITIAL_READ))
        // The hidden window-manager listener is the accurate source.
        tracker.onLockChanged(false, LockSource.KEYGUARD_LISTENER)
        // A broadcast that repeats the value but comes from a different source is
        // still a change: one state, named `broadcast`.
        tracker.onLockChanged(false, LockSource.BROADCAST)
        // The same value from the same source is not re-sent.
        tracker.onLockChanged(false, LockSource.BROADCAST)
        assertEquals(
            listOf(
                DeviceState(true, 55, false, lockSource = LockSource.INITIAL_READ),
                DeviceState(false, 55, false, lockSource = LockSource.KEYGUARD_LISTENER),
                DeviceState(false, 55, false, lockSource = LockSource.BROADCAST),
            ),
            emitted,
        )
    }
}
