package dev.pocketdeck.server

import android.content.Context
import android.os.PowerManager
import android.os.SystemClock
import java.lang.reflect.Method

/**
 * Battery/keep-awake policy. It only ever pokes the *virtual display's* own
 * display group: the physical panel is never forced on and there is no panel
 * loop (a locked phone's panel is already off).
 *
 *  - `userActivity(displayId)` on input, throttled to at most once per second.
 *  - `wakeUpWithDisplayId(displayId)` on the same throttle: waking an
 *    already-awake group is a no-op, and doing it *per display* keeps the
 *    physical panel — a different display group — off. There is deliberately no
 *    fallback to the global wake-up call: that would light the panel and show
 *    the keyguard.
 *  - the same `userActivity(displayId)` poke on a 30 s timer, only while at
 *    least one stream is unpaused.
 *  - a PARTIAL wake lock only while at least one stream is unpaused.
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
            for (id in displays) userActivity(id)
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
        const val KEEPALIVE_INTERVAL_MS = 30_000L
    }
}
