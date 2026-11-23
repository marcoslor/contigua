package app.contigua.server

import android.app.KeyguardManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.hardware.display.DisplayManager
import android.os.BatteryManager
import android.os.Binder
import android.os.Handler
import android.os.HandlerThread
import android.os.Parcel
import java.lang.reflect.Proxy

/**
 * Event-driven device state for the shell process. Nothing here polls.
 *
 * The lock state comes from the hidden
 * `IWindowManager.addKeyguardLockedStateListener`; when a build has no such call
 * the screen/user-present broadcasts are used instead, re-reading
 * `KeyguardManager`. The shell process' own context turns out not to receive
 * broadcasts on current Android builds, so the app process relays the battery
 * (and, as a last resort, the keyguard state) over AIDL — see
 * `DeckService.setBatteryState` — while the sticky `ACTION_BATTERY_CHANGED`
 * receiver here is kept as a direct source where it does work.
 *
 * Every source feeds one [DeviceStateTracker], so repeated callbacks, sticky
 * replays and two sources reporting the same value cannot produce a duplicate
 * `state`.
 */
internal class AndroidDeviceState(
    private val ctx: Context,
    private val initialBattery: () -> Pair<Int, Boolean>,
    private val log: (String) -> Unit,
) {

    private val tracker = DeviceStateTracker { state -> onChange?.invoke(state) }

    @Volatile private var onChange: ((DeviceState) -> Unit)? = null
    @Volatile private var battery = 0
    @Volatile private var charging = false

    private var thread: HandlerThread? = null
    private var receiver: BroadcastReceiver? = null
    private var keyguardProxy: Any? = null
    private var windowManager: Any? = null
    private var hiddenKeyguard = false
    private var started = false
    /** Display 0's power changes (`state.screen`); event driven, never polled. */
    private var displayListener: DisplayManager.DisplayListener? = null

    /** Registers the listeners and emits the current state once. */
    fun start(onChange: (DeviceState) -> Unit): AutoCloseable {
        if (started) return AutoCloseable { stop() }
        started = true
        this.onChange = onChange
        val (level, chg) = initialBattery()
        battery = level
        charging = chg
        val t = HandlerThread("contigua-devstate").also { it.start() }
        thread = t
        val h = Handler(t.looper)
        receiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context?, intent: Intent?) {
                when (intent?.action) {
                    Intent.ACTION_BATTERY_CHANGED -> {
                        val (percent, chargingNow) = batteryOf(intent)
                        log("state: battery event $percent% charging=$chargingNow")
                        tracker.onBatteryChanged(percent, chargingNow)
                    }
                    // Screen-broadcast fallback for the lock state.
                    else -> {
                        val locked = locked()
                        log("state: ${intent?.action} -> locked=$locked")
                        tracker.onLockChanged(locked, LockSource.BROADCAST)
                    }
                }
            }
        }
        registerBattery(h)
        hiddenKeyguard = registerKeyguardListener()
        if (!hiddenKeyguard) registerScreenFallback(h)
        registerDisplayListener(h)
        tracker.update(DeviceState(locked(), battery, charging, screen = ScreenState.read(ctx), lockSource = LockSource.INITIAL_READ))
        return AutoCloseable { stop() }
    }

    fun stop() {
        if (!started) return
        started = false
        onChange = null
        val r = receiver
        receiver = null
        if (r != null) runCatching { ctx.unregisterReceiver(r) }
        removeKeyguardListener()
        removeDisplayListener()
        runCatching { thread?.quitSafely() }
        thread = null
    }

    /** A battery event relayed by the app process (see `IDeckService`). */
    fun onBatteryEvent(percent: Int, charging: Boolean) {
        log("state: battery relay $percent% charging=$charging")
        tracker.onBatteryChanged(percent, charging)
    }

    /**
     * A keyguard event relayed by the app process. Only used when this process
     * has no hidden window-manager listener: otherwise the accurate source wins.
     */
    fun onLockEvent(locked: Boolean) {
        if (!hiddenKeyguard) tracker.onLockChanged(locked, LockSource.APP_RELAY)
    }

    // ------------------------------------------------------------------

    private fun registerBattery(h: Handler) {
        // The app process owns the authoritative value (its context receives the
        // broadcasts); this direct registration is a bonus source where it works.
        val filter = IntentFilter(Intent.ACTION_BATTERY_CHANGED)
        val sticky = runCatching { ctx.registerReceiver(receiver, filter, null, h) }
        sticky.exceptionOrNull()?.let {
            log("state: battery receiver registration failed: $it")
            return
        }
        if (sticky.getOrNull() == null) {
            log("state: battery broadcasts not visible here; the app process relays them")
        }
    }

    /**
     * The hidden listener is the accurate source: the window manager tells us
     * every keyguard locked-state change, no screen event needed.
     */
    private fun registerKeyguardListener(): Boolean {
        val wm = Hidden.proxy("android.view.IWindowManager", "window")
            ?: return listenerUnavailable("no window manager binder")
        val iface = Hidden.iface(KEYGUARD_LISTENER_IFACE)
            ?: return listenerUnavailable("no listener interface on this build")
        val add = Hidden.method(Hidden.iface("android.view.IWindowManager"), "addKeyguardLockedStateListener", iface)
            ?: return listenerUnavailable("no addKeyguardLockedStateListener")
        // The listener is an AIDL callback: system_server marshals it through
        // asBinder() and calls transact() on us. A reflective proxy cannot be a
        // Binder, so the proxy's asBinder() returns a binder that parses the one
        // callback method (`onKeyguardLockedStateChanged(boolean)`, transaction 1).
        val carrier = object : Binder() {
            override fun onTransact(code: Int, data: Parcel, reply: Parcel?, flags: Int): Boolean {
                if (code == TRANSACTION_KEYGUARD_LOCKED_STATE) {
                    data.enforceInterface(iface.name)
                    val locked = data.readInt() != 0
                    log("state: keyguard event locked=$locked")
                    tracker.onLockChanged(locked, LockSource.KEYGUARD_LISTENER)
                    return true
                }
                return super.onTransact(code, data, reply, flags)
            }
        }
        val proxy = Proxy.newProxyInstance(iface.classLoader, arrayOf(iface)) { _, method, _ ->
            if (method.name == "asBinder") carrier else null
        }
        val registered = runCatching { add.invoke(wm, proxy) }
        registered.exceptionOrNull()?.let { return listenerUnavailable(it.toString()) }
        windowManager = wm
        keyguardProxy = proxy
        log("state: lock events from the window manager listener")
        return true
    }

    private fun listenerUnavailable(why: String): Boolean {
        log("state: window manager listener unavailable ($why)")
        return false
    }

    private fun removeKeyguardListener() {
        val wm = windowManager ?: return
        val proxy = keyguardProxy
        windowManager = null
        keyguardProxy = null
        val iface = Hidden.iface(KEYGUARD_LISTENER_IFACE) ?: return
        val remove = Hidden.method(Hidden.iface("android.view.IWindowManager"), "removeKeyguardLockedStateListener", iface)
            ?: return
        if (proxy != null) runCatching { remove.invoke(wm, proxy) }
    }

    /** No hidden listener: re-read the keyguard whenever the screen state changes. */
    private fun registerScreenFallback(h: Handler) {
        val filter = IntentFilter().apply {
            addAction(Intent.ACTION_SCREEN_ON)
            addAction(Intent.ACTION_SCREEN_OFF)
            addAction(Intent.ACTION_USER_PRESENT)
        }
        val result = runCatching { ctx.registerReceiver(receiver, filter, null, h) }
        result.exceptionOrNull()?.let {
            log("state: screen broadcast registration failed: $it")
            return
        }
        log("state: lock events from screen broadcasts (no window manager listener)")
    }

    /**
     * Display 0's own power state, for `state.screen`. A display listener is
     * the event source (no polling): phone-mode mirrors are the only thing that
     * reads it, and the panel changes far less often than a poll would tick.
     */
    private fun registerDisplayListener(h: Handler) {
        val dm = ctx.getSystemService(Context.DISPLAY_SERVICE) as? DisplayManager ?: run {
            log("state: no display manager; screen state is read on change only")
            return
        }
        val listener = object : DisplayManager.DisplayListener {
            override fun onDisplayAdded(displayId: Int) = Unit
            override fun onDisplayRemoved(displayId: Int) = Unit
            override fun onDisplayChanged(displayId: Int) {
                if (displayId != android.view.Display.DEFAULT_DISPLAY) return
                val screen = ScreenState.read(ctx) ?: return
                log("state: display 0 -> screen=${screen.wire}")
                tracker.onScreenChanged(screen)
            }
        }
        runCatching { dm.registerDisplayListener(listener, h) }
            .onSuccess { displayListener = listener }
            .onFailure { log("state: display listener unavailable ($it)") }
    }

    private fun removeDisplayListener() {
        val listener = displayListener ?: return
        displayListener = null
        runCatching {
            (ctx.getSystemService(Context.DISPLAY_SERVICE) as? DisplayManager)
                ?.unregisterDisplayListener(listener)
        }
    }

    private fun locked(): Boolean = runCatching {
        (ctx.getSystemService(Context.KEYGUARD_SERVICE) as? KeyguardManager)?.isDeviceLocked ?: false
    }.getOrDefault(false)

    private fun batteryOf(intent: Intent): Pair<Int, Boolean> {
        val level = intent.getIntExtra(BatteryManager.EXTRA_LEVEL, -1)
        val scale = intent.getIntExtra(BatteryManager.EXTRA_SCALE, -1)
        val percent = if (level >= 0 && scale > 0) level * 100 / scale else battery
        val status = intent.getIntExtra(BatteryManager.EXTRA_STATUS, -1)
        val chg = status == BatteryManager.BATTERY_STATUS_CHARGING || status == BatteryManager.BATTERY_STATUS_FULL
        return percent to chg
    }

    private companion object {
        /**
         * The keyguard locked-state callback interface (`IWindowManager.aidl`
         * imports it from `com.android.internal.policy`); one oneway method, so
         * its callback transaction is 1.
         */
        const val KEYGUARD_LISTENER_IFACE = "com.android.internal.policy.IKeyguardLockedStateListener"
        const val TRANSACTION_KEYGUARD_LOCKED_STATE = 1
    }
}
