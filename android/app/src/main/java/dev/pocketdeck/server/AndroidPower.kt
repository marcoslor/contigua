package dev.pocketdeck.server

import android.content.Context
import android.os.PowerManager
import android.os.SystemClock
import android.view.Display
import java.lang.reflect.Method

/**
 * Battery/keep-awake policy. It pokes the *streaming* displays' display groups:
 * `userActivity(displayId)` + `wakeUpWithDisplayId(displayId)` when a window
 * opens and on a timer while streams are unpaused, alongside a PARTIAL wake lock.
 *
 * `wakeUpWithDisplayId` wakes the power group of that display's display group
 * (`PowerManagerService.wakeUpWithDisplayId`). AOSP gives an `OWN_DISPLAY_GROUP`
 * virtual display a group of its own, so only that group wakes and the physical
 * panel stays off. Builds that ignore the flag (Samsung One UI puts the VD in
 * group 0, verified on SM-S936B) make the same call wake the panel and show its
 * lock screen, which is what [DarkPanelPolicy] handles: the group is woken as
 * before and the physical panel is then powered off through SurfaceFlinger, so
 * the VD renders while the phone shows nothing. The override is lifted when the
 * last stream goes away (`POWER_MODE_NORMAL` + `goToSleep`), when the user
 * presses the power button, and by the platform itself on its next state change.
 *
 * The code never unlocks and never dismisses the keyguard; it only ever names the
 * streaming display's own group, plus the panel's power mode on builds that
 * cannot separate the two.
 *
 * `debug.pocketdeck.force_panel_off=1` forces the panel-dark path (used by the
 * emulator checks, where AOSP would give the VD its own group).
 */
internal class AndroidPower(private val ctx: Context, private val log: (String) -> Unit) : Power {

    private val lock = Object()
    private val policyLock = Object()
    private val activeDisplays = ArrayList<Int>()
    private var lastActivityMs = 0L
    private var timerRunning = false
    private var timerThread: Thread? = null
    private var wakeLock: PowerManager.WakeLock? = null
    private var loggedNoWakeUp = false

    /** Set from the keep-alive step: only safe to wake on input when the panel is not shared. */
    @Volatile private var groupOnly = false

    /** Set from the keep-alive step: true while we keep the streaming group lit ourselves. */
    @Volatile private var keepLit = false

    /** True while the panel override is ours; cleared by restore, checked before each apply. */
    @Volatile private var darkEpisode = false

    private val panel = PanelPower(log)
    private val policy = DarkPanelPolicy(forced = Hidden.systemProperty(FORCE_PANEL_OFF) == "1")

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

    /** `goToSleep(long, int, int)` — puts the display group we woke back to sleep. */
    private val goToSleepMethod: Method? =
        Hidden.method(powerManagerClass, "goToSleep", Hidden.T_LONG, Hidden.T_INT, Hidden.T_INT)

    /** `PowerManager.WAKE_REASON_APPLICATION`, read reflectively; 2 is its stable value. */
    private val wakeReasonApplication: Int = runCatching {
        PowerManager::class.java.getField("WAKE_REASON_APPLICATION").getInt(null)
    }.getOrDefault(2)

    /** `PowerManager.GO_TO_SLEEP_REASON_APPLICATION`, read reflectively; 0 is its stable value. */
    private val sleepReasonApplication: Int = runCatching {
        PowerManager::class.java.getField("GO_TO_SLEEP_REASON_APPLICATION").getInt(null)
    }.getOrDefault(0)

    init {
        log(
            "power: panel power control ${if (panel.available) "ready" else "unavailable"}" +
                if (policy.isForced) " ($FORCE_PANEL_OFF=1: forcing the panel-dark path)" else "",
        )
    }

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
            // Only poke while the keep-alive owns the group: in the stand-down
            // phase the phone is the user's, and a poke would keep its screen
            // from ever timing out.
            if (keepLit) {
                userActivity(displayId)
                // Waking on input is only safe when the VD is not sharing the
                // panel's group; otherwise the keep-alive owns the panel.
                if (groupOnly) wakeDisplay(displayId)
            }
        }
    }

    override fun setActiveStreams(displayIds: List<Int>) {
        var started = false
        var stopped = false
        synchronized(lock) {
            val wasActive = activeDisplays.isNotEmpty()
            activeDisplays.clear()
            activeDisplays.addAll(displayIds)
            val isActive = activeDisplays.isNotEmpty()
            if (isActive && !wasActive) {
                acquireWakeLockLocked()
                startTimerLocked()
                started = true
            } else if (!isActive && wasActive) {
                releaseWakeLockLocked()
                stopTimerLocked()
                stopped = true
            }
        }
        if (started) synchronized(policyLock) { policy.streamsStarted() }
        if (stopped) restoreAfterStop()
        // A window just opened: the keep-alive thread runs a step right away, so
        // the wake (and the panel-off after it) never blocks the session thread.
        synchronized(lock) { lock.notifyAll() }
    }

    override fun onSessionEnded() {
        setActiveStreams(emptyList())
    }

    // ------------------------------------------------------------------

    /**
     * One keep-alive step: read the platform state, decide, apply. Reading the
     * panel state *before* the wake is what tells the policy whether the wake is
     * what turns the panel on.
     */
    private fun keepAliveStep() {
        val ids = synchronized(lock) { activeDisplays.toIntArray() }
        if (ids.isEmpty()) return
        val strategy = policy.strategy(ids.map { DisplayProbe.displayGroupId(it) })
        groupOnly = strategy == PanelStrategy.GROUP_ONLY
        val panelOn = DisplayProbe.state(PANEL_DISPLAY_ID) == Display.STATE_ON
        val plan = synchronized(policyLock) { policy.step(panelOn, strategy) }
        keepLit = plan.wake
        darkEpisode = plan.panelOff
        if (!plan.wake) return
        for (id in ids) {
            userActivity(id)
            // The panel going off after the screen timeout would take the VD with
            // it, so the keep-alive wakes the group too. On the panel's group the
            // wake lights the panel; the panel-off below follows immediately.
            wakeDisplay(id)
        }
        if (plan.panelOff) applyPanelOff(plan.transitional)
    }

    /** Forces the panel dark; [PanelPower] logs the mode transitions. */
    private fun applyPanelOff(transitional: Boolean) {
        if (!darkEpisode) return
        if (!panel.panelOff()) {
            if (!loggedNoPanelControl) {
                loggedNoPanelControl = true
                log("panel off unavailable: the locked phone will show its lock screen while streaming")
            }
            return
        }
        if (!transitional) return
        // The platform's display power controller writes its own power mode while
        // it processes the wake and does not know about ours, so two bounded
        // re-applies make sure a transitional wake cannot leave the panel lit.
        for (delay in REAPPLY_DELAYS_MS) {
            runCatching { Thread.sleep(delay) }
            if (!darkEpisode || synchronized(lock) { activeDisplays.isEmpty() }) return
            panel.panelOff()
        }
    }

    /**
     * The last stream paused/closed or the session ended: hand the phone back to
     * its normal locked-off state. The panel power mode is only restored when the
     * platform believes the panel is on (our override is masking it); otherwise
     * the platform's own mode is already the right one and re-writing NORMAL
     * would flash the panel.
     */
    private fun restoreAfterStop() {
        val owned = synchronized(policyLock) { policy.streamsStopped() }
        if (!owned) return
        // Stop any in-flight apply before handing the panel back.
        darkEpisode = false
        if (DisplayProbe.state(PANEL_DISPLAY_ID) == Display.STATE_ON) {
            panel.panelNormal()
        }
        // goToSleep lets the platform re-apply its own power mode for the
        // transition and leaves the phone asleep and locked. Only ever called
        // when we were the ones who woke the group.
        goToSleep()
    }

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

    private fun goToSleep() {
        val m = goToSleepMethod ?: return
        runCatching {
            m.invoke(powerManager, SystemClock.uptimeMillis(), sleepReasonApplication, 0)
            log("phone back to sleep after the last stream")
        }
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
        // The timer parks until the next 10 s boundary *or* a nudge from
        // setActiveStreams, which is how a new window gets its first step.
        var nextStepAt = 0L
        while (true) {
            synchronized(lock) {
                if (!timerRunning) return
                val waitMs = (nextStepAt - SystemClock.uptimeMillis()).coerceAtLeast(1)
                runCatching { lock.wait(waitMs) }
                if (!timerRunning) return
                nextStepAt = SystemClock.uptimeMillis() + KEEPALIVE_INTERVAL_MS
            }
            runCatching { keepAliveStep() }
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

    private var loggedNoPanelControl = false

    private companion object {
        /** Shorter than any screen-off timeout, so a streaming group stays on. */
        const val KEEPALIVE_INTERVAL_MS = 10_000L

        /** Re-applies after a transitional wake, so a fresh lock screen cannot stay. */
        val REAPPLY_DELAYS_MS = longArrayOf(500, 1_500)

        const val FORCE_PANEL_OFF = "debug.pocketdeck.force_panel_off"

        /** Display 0 is the panel on every phone. */
        const val PANEL_DISPLAY_ID = 0
    }
}
