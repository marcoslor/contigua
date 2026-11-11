package app.contigua.app

import android.content.Context
import android.os.Build
import android.provider.Settings

/**
 * What the phone calls itself: the name from Settings > About phone (what the
 * user sees in Bluetooth and hotspot lists), not the model code.
 */
internal object DeviceName {

    /**
     * A name the user chose in Contigua wins. The stored value is the current
     * shape, so it is used as it is.
     */
    fun resolve(stored: String?, model: String, systemName: () -> String?): String {
        if (!stored.isNullOrBlank()) return stored
        return systemName()?.trim()?.takeIf { it.isNotEmpty() } ?: model
    }

    /** `device_name`, then `bluetooth_name`; either may be unset or unreadable. */
    fun system(ctx: Context): String? = listOf(
        { Settings.Global.getString(ctx.contentResolver, Settings.Global.DEVICE_NAME) },
        { Settings.Secure.getString(ctx.contentResolver, "bluetooth_name") },
    ).firstNotNullOfOrNull { read -> runCatching(read).getOrNull()?.trim()?.takeIf { it.isNotEmpty() } }

    fun model(): String = Build.MODEL ?: "Android"
}
