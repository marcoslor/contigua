package app.contigua.app

import android.app.Application
import android.app.KeyguardManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.BatteryManager
import android.util.Log
import app.contigua.IDeckService

/**
 * Relays the device state the shell process cannot get itself.
 *
 * The Shizuku user service (UID 2000) turns out not to receive broadcasts on
 * current Android builds — neither the sticky battery nor the screen/keyguard
 * events — so the app process listens here and pushes over AIDL
 * (`IDeckService.setBatteryState` / `setLockedState`). The relay lives in the
 * Application so it is registered as soon as the process exists, independent of
 * the foreground service's lifecycle.
 */
object DeviceStateRelay {

    private const val TAG = "ContiguaApp"

    @Volatile private var app: Context? = null
    @Volatile private var percent = 0
    @Volatile private var charging = false
    @Volatile private var registered = false

    private val receiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            when (intent?.action) {
                Intent.ACTION_BATTERY_CHANGED -> {
                    read(intent)
                    Log.i(TAG, "battery $percent% charging=$charging -> shell service")
                    ShizukuClient.current()?.let { push(it) }
                }
                Intent.ACTION_SCREEN_ON, Intent.ACTION_SCREEN_OFF, Intent.ACTION_USER_PRESENT ->
                    ShizukuClient.current()?.let { pushLocked(it) }
            }
        }
    }

    fun start(ctx: Context) {
        app = ctx.applicationContext
        if (registered) return
        registered = true
        runCatching { ctx.registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED)) }
            .getOrNull()?.let { read(it) }
        runCatching {
            ctx.registerReceiver(
                receiver,
                IntentFilter().apply {
                    addAction(Intent.ACTION_BATTERY_CHANGED)
                    addAction(Intent.ACTION_SCREEN_ON)
                    addAction(Intent.ACTION_SCREEN_OFF)
                    addAction(Intent.ACTION_USER_PRESENT)
                },
            )
        }.onFailure { Log.i(TAG, "device state receiver not registered: ${it.message}") }
    }

    /** The last battery reading; the shell process uses it for `welcome` + the initial state. */
    fun push(service: IDeckService) {
        runCatching { service.setBatteryState(percent, charging) }
    }

    /** The keyguard state, used only when the shell has no window-manager listener. */
    fun pushLocked(service: IDeckService) {
        val locked = runCatching {
            (app?.getSystemService(Context.KEYGUARD_SERVICE) as? KeyguardManager)?.isDeviceLocked ?: false
        }.getOrDefault(false)
        runCatching { service.setLockedState(locked) }
    }

    private fun read(intent: Intent) {
        val level = intent.getIntExtra(BatteryManager.EXTRA_LEVEL, -1)
        val scale = intent.getIntExtra(BatteryManager.EXTRA_SCALE, -1)
        if (level >= 0 && scale > 0) percent = level * 100 / scale
        val status = intent.getIntExtra(BatteryManager.EXTRA_STATUS, -1)
        charging = status == BatteryManager.BATTERY_STATUS_CHARGING ||
            status == BatteryManager.BATTERY_STATUS_FULL
    }
}

/** Registers the state relay before anything else in the process runs. */
class DeckApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        DeviceStateRelay.start(this)
    }
}
