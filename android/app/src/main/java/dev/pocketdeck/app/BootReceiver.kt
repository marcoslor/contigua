package dev.pocketdeck.app

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import rikka.shizuku.Shizuku

/** Restart the deck after a reboot or an app update, when the user enabled it. */
class BootReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent) {
        val action = intent.action ?: return
        if (action != Intent.ACTION_BOOT_COMPLETED && action != Intent.ACTION_MY_PACKAGE_REPLACED) return
        if (!startsAtBoot(Prefs.isEnabled(context), Shizuku.pingBinder())) return
        DeckForegroundService.start(context)
    }
}

/**
 * "Keep running in the background" on is what survives a reboot; off means the
 * service lives only with the app's task, so a reboot never starts it.
 */
internal fun startsAtBoot(enabled: Boolean, shizukuRunning: Boolean): Boolean =
    enabled && shizukuRunning
