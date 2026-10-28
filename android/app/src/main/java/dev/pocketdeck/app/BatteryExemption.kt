package dev.pocketdeck.app

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.PowerManager
import android.provider.Settings
import android.util.Log

/**
 * The battery-optimisation exemption: whether PocketDeck has it, and the system
 * screens that can grant it (docs/specs/phone-app.md PHONE-19). The most
 * specific screen first — the exemption dialog — then the app's own battery
 * page, then the system's exemption list. A phone that does not handle the
 * dialog (or a build without the permission for it) still reaches a screen that
 * can grant it, and a failure is logged, never swallowed.
 */
object BatteryExemption {

    private const val TAG = "PocketDeckApp"

    /** True when Android is already leaving the service alone. */
    fun isExempt(ctx: Context): Boolean {
        val power = ctx.getSystemService(Context.POWER_SERVICE) as? PowerManager ?: return false
        return runCatching { power.isIgnoringBatteryOptimizations(ctx.packageName) }.getOrDefault(false)
    }

    /** The screens to try, in order, for [pkg]. */
    fun intents(pkg: String): List<Intent> = listOf(
        Intent(
            Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
            Uri.parse("package:$pkg"),
        ),
        Intent(
            Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
            Uri.parse("package:$pkg"),
        ),
        Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS),
    )

    /**
     * Opens the first screen that works. Returns its action, or null when none
     * could be started (each failure is logged with its own reason).
     */
    fun open(ctx: Context, start: (Intent) -> Unit = { ctx.startActivity(it) }): String? {
        intents(ctx.packageName).forEachIndexed { step, intent ->
            val action = intent.action.orEmpty()
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            val failure = runCatching { start(intent) }.exceptionOrNull()
            if (failure == null) return action
            // A closed set, not the exception's own message: no handler is the
            // phone's answer, anything else is a failure to open.
            val state = if (failure is android.content.ActivityNotFoundException) "no_handler" else "failed"
            Log.i(TAG, "battery screen step=$step state=$state")
        }
        return null
    }
}
