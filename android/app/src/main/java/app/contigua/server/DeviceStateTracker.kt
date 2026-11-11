package app.contigua.server

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

    /** Emits [state] unless it equals the previous one; true when it emitted. */
    fun update(state: DeviceState): Boolean {
        synchronized(lock) {
            if (state == last) return false
            last = state
            emit(state)
            return true
        }
    }

    /** A keyguard event: only `locked` changes. */
    fun onLockChanged(locked: Boolean) =
        update(DeviceState(locked, current?.battery ?: 0, current?.charging ?: false, current?.dnd, current?.ringer,
            current?.screen, current?.secure, current?.volume, current?.volumeMax))

    /** A battery event: only the battery fields change. */
    fun onBatteryChanged(battery: Int, charging: Boolean) =
        update(DeviceState(current?.locked ?: false, battery, charging, current?.dnd, current?.ringer,
            current?.screen, current?.secure, current?.volume, current?.volumeMax))

    /** A display-0 power change: only `screen` changes. */
    fun onScreenChanged(screen: ScreenState?) =
        update(DeviceState(current?.locked ?: false, current?.battery ?: 0, current?.charging ?: false,
            current?.dnd, current?.ringer, screen, current?.secure, current?.volume, current?.volumeMax))

    /** The display-0 secure surface changed while a phone window is open. */
    fun onSecureChanged(secure: Boolean) =
        update(DeviceState(current?.locked ?: false, current?.battery ?: 0, current?.charging ?: false,
            current?.dnd, current?.ringer, current?.screen, secure, current?.volume, current?.volumeMax))
}
