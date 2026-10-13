package dev.pocketdeck.server

/**
 * Folds device-state reads and platform events into the protocol's `state`
 * stream: one emission per real change (the protocol says "sent on change", and
 * the first emission is the post-`welcome` state).
 *
 * The sources overlap — a keyguard callback can repeat the same value, and a
 * sticky battery broadcast arrives once at registration — so dedupe lives here,
 * next to the values it compares.
 */
internal class DeviceStateTracker(private val emit: (DeviceState) -> Unit) {

    private val lock = Object()
    private var last: DeviceState? = null

    /** The last emitted state, or null before the first emission. */
    val current: DeviceState? get() = synchronized(lock) { last }

    /** Emits [state] unless it equals the previous one. */
    fun update(state: DeviceState) {
        synchronized(lock) {
            if (state == last) return
            last = state
            emit(state)
        }
    }

    /** A keyguard event: only `locked` changes. */
    fun onLockChanged(locked: Boolean) =
        update(DeviceState(locked, current?.battery ?: 0, current?.charging ?: false))

    /** A battery event: only the battery fields change. */
    fun onBatteryChanged(battery: Int, charging: Boolean) =
        update(DeviceState(current?.locked ?: false, battery, charging))
}
