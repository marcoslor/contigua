package dev.pocketdeck.server

import android.content.Context
import android.os.PowerManager
import android.os.SystemClock
import java.lang.reflect.Method

/**
 * Battery/keep-awake policy. It pokes the *virtual display's* display group:
 * `userActivity(displayId)` + `wakeUpWithDisplayId(displayId)` on input, when a
 * window opens, and on a timer while streams are unpaused.
 *
 * On AOSP a `FLAG_OWN_DISPLAY_GROUP` VD has a group of its own, so waking it
 * starts that group's compositor and leaves the physical panel off. Samsung's
 * DisplayManager puts the VD in the panel's group (displayGroupId 0, verified on
 * SM-S936B), so there the same calls wake the *panel* — the phone shows its lock
 * screen while a window streams. That is the trade for a locked phone that still
 * renders; the code never unlocks (no keyguard dismissal, no global wake).
 */
internal class AndroidPower(private val ctx: Context, private val log: (String) -> Unit) : Power {

    private val lock = Object()
    private val activeDisplays = ArrayList<Int>()
    private var lastActivityMs = 0L
    private var timerRunning = false
    private var timerThread: Thread? = null
    private var wakeLock: PowerManager.WakeLock? = null
    private var loggedNoWakeUp = false

    private val powerManager: Any? = Hidden.proxy("android.os.IPowerManager", "power")
    private val powerManagerClass = Hidden.iface("android.os.IPowerManager")

    private val userActivityMethod: Method? =
        Hidden.method(powerManagerClass, "userActivity", Hidden.T_INT, Hidden.T_LONG, Hidden.T_INT, Hidden.T_INT)
            ?: Hidden.method(powerManagerClass, "userActivity", Hidden.T_LONG, Hidden.T_INT, Hidden.T_INT)

    /**
     * `wakeUpWithDisplayId(long, int, String, String, int)` — present on
     * Android 15+. Resolved once; if it is missing we simply never wake anything.
     */
    private val wakeUpDisplayMethod: Method? = Hidden.method(
        powerManagerClass,
        "wakeUpWithDisplayId",
        Hidden.T_LONG,
        Hidden.T_INT,
        String::class.java,
        String::class.java,
        Hidden.T_INT,
    )

    /** `PowerManager.WAKE_REASON_APPLICATION`, read reflectively; 2 is its stable value. */
    private val wakeReasonApplication: Int = runCatching {
        PowerManager::class.java.getField("WAKE_REASON_APPLICATION").getInt(null)
    }.getOrDefault(2)

    override fun onInput(displayId: Int) {
        val t = SystemClock.uptimeMillis()
        val poke = synchronized(lock) {
            if (t - lastActivityMs >= 1000) {
                lastActivityMs = t
                true
            } else {
                false
            }
        }
        if (poke) {
            userActivity(displayId)
            wakeDisplay(displayId)
        }
    }

    override fun setActiveStreams(displayIds: List<Int>) {
        synchronized(lock) {
            val wasActive = activeDisplays.isNotEmpty()
            activeDisplays.clear()
            activeDisplays.addAll(displayIds)
            val isActive = activeDisplays.isNotEmpty()
            if (isActive && !wasActive) {
                acquireWakeLockLocked()
                startTimerLocked()
            } else if (!isActive && wasActive) {
                releaseWakeLockLocked()
                stopTimerLocked()
            }
        }
        // A window just opened: wake its display group right away. On builds where
        // the VD shares the panel's group (Samsung), the group is the panel's, so
        // the phone wakes *locked* — without this a locked phone renders nothing.
        for (id in displayIds) {
            userActivity(id)
            wakeDisplay(id)
        }
    }

    override fun onSessionEnded() {
        setActiveStreams(emptyList())
    }

    // ------------------------------------------------------------------

    private fun userActivity(displayId: Int) {
        val m = userActivityMethod ?: return
        val now = SystemClock.uptimeMillis()
        runCatching {
            if (m.parameterTypes.size == 4) {
                m.invoke(powerManager, displayId, now, 0, 0)
            } else {
                m.invoke(powerManager, now, 0, 0)
            }
        }
    }

    private fun wakeDisplay(displayId: Int) {
        val m = wakeUpDisplayMethod ?: run {
            if (!loggedNoWakeUp) {
                loggedNoWakeUp = true
                log("wakeUpWithDisplayId unavailable: not waking any display")
            }
            return
        }
        val now = SystemClock.uptimeMillis()
        runCatching { m.invoke(powerManager, now, wakeReasonApplication, "pocketdeck", "pocketdeck", displayId) }
    }

    private fun startTimerLocked() {
        if (timerRunning) return
        timerRunning = true
        timerThread = Thread({ keepAliveLoop() }, "pocketdeck-keepalive").also { it.start() }
    }

    private fun stopTimerLocked() {
        timerRunning = false
        lock.notifyAll()
    }

    private fun keepAliveLoop() {
        while (true) {
            synchronized(lock) {
                if (!timerRunning) return
                runCatching { lock.wait(KEEPALIVE_INTERVAL_MS) }
                if (!timerRunning) return
            }
            val displays = synchronized(lock) { activeDisplays.toIntArray() }
            for (id in displays) {
                userActivity(id)
                // The panel going off after the screen timeout would take the VD
                // with it, so the keep-alive wakes the group too.
                wakeDisplay(id)
            }
        }
    }

    private fun acquireWakeLockLocked() {
        if (wakeLock != null) return
        runCatching {
            val pm = ctx.getSystemService(Context.POWER_SERVICE) as PowerManager
            val wl = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "pocketdeck:streams")
            wl.setReferenceCounted(false)
            wl.acquire()
            wakeLock = wl
            log("partial wake lock acquired")
        }
    }

    private fun releaseWakeLockLocked() {
        val wl = wakeLock ?: return
        wakeLock = null
        runCatching { wl.release() }
        log("partial wake lock released")
    }

    private companion object {
        /** Shorter than any screen-off timeout, so a streaming group stays on. */
        const val KEEPALIVE_INTERVAL_MS = 10_000L
    }
}
