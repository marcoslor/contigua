package dev.pocketdeck.app

import java.util.concurrent.CopyOnWriteArrayList

/**
 * Process-wide observable state shared by the foreground service and the UI.
 * Kept deliberately simple: both live in the app process, so a singleton beats
 * a second binder.
 */
object DeckState {

    data class PendingPairing(val requestId: String, val macName: String, val code: String)

    @Volatile var enabled: Boolean = false
    @Volatile var shizukuRunning: Boolean = false
    @Volatile var shizukuGranted: Boolean = false
    /** The foreground service exists in this process (not "the switch is on"). */
    @Volatile var serviceRunning: Boolean = false
    @Volatile var port: Int = -1
    @Volatile var connectedMac: String? = null
    /** The paired client id of [connectedMac]; null when nothing is connected. */
    @Volatile var connectedClientId: String? = null
    @Volatile var windows: Int = 0
    @Volatile var paired: List<Prefs.PairedMac> = emptyList()
    @Volatile var pending: PendingPairing? = null

    /**
     * The notification gate is open: the Mac asked (`notify.enable`) and the
     * phone's listener grant is live. Relayed from the shell service; the
     * listener's bridge reads it.
     */
    @Volatile var notifyForward: Boolean = false

    /**
     * The Mac asked for notifications but the listener grant is missing: the
     * home shows the notification-access attention item.
     */
    @Volatile var notifyNoAccess: Boolean = false

    private val listeners = CopyOnWriteArrayList<() -> Unit>()

    fun addListener(listener: () -> Unit) {
        listeners.add(listener)
        listener()
    }

    fun removeListener(listener: () -> Unit) {
        listeners.remove(listener)
    }

    fun notifyChanged() {
        for (l in listeners) l()
    }
}
