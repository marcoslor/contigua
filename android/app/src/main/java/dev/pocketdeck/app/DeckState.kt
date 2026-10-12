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
    @Volatile var port: Int = -1
    @Volatile var connectedMac: String? = null
    @Volatile var windows: Int = 0
    @Volatile var paired: List<Prefs.PairedMac> = emptyList()
    @Volatile var pending: PendingPairing? = null

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
