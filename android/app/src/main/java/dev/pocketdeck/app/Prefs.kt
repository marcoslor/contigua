package dev.pocketdeck.app

import android.content.Context
import dev.pocketdeck.proto.Crypto
import dev.pocketdeck.proto.Json

/** Small owned store for the app process: identity, paired clients, enable flag. */
object Prefs {

    private const val FILE = "pocketdeck"
    private const val KEY_ENABLED = "enabled"
    private const val KEY_DEVICE_ID = "device_id"
    private const val KEY_DEVICE_NAME = "device_name"
    private const val KEY_PAIRED = "paired"
    private const val KEY_ONBOARDING_DONE = "onboarding_done"
    private const val KEY_BATTERY_REQUESTED = "battery_requested"

    data class PairedMac(
        val clientId: String,
        val name: String,
        val keyHex: String,
        /** Local epoch millis of the last successful pairing, 0 if unknown. */
        val lastConnected: Long = 0,
    )

    private fun sp(ctx: Context) = ctx.getSharedPreferences(FILE, Context.MODE_PRIVATE)

    fun isEnabled(ctx: Context): Boolean = sp(ctx).getBoolean(KEY_ENABLED, false)

    fun setEnabled(ctx: Context, value: Boolean) = sp(ctx).edit().putBoolean(KEY_ENABLED, value).apply()

    fun isOnboardingDone(ctx: Context): Boolean = sp(ctx).getBoolean(KEY_ONBOARDING_DONE, false)

    fun setOnboardingDone(ctx: Context, value: Boolean) =
        sp(ctx).edit().putBoolean(KEY_ONBOARDING_DONE, value).apply()

    fun isBatteryRequested(ctx: Context): Boolean = sp(ctx).getBoolean(KEY_BATTERY_REQUESTED, false)

    fun setBatteryRequested(ctx: Context, value: Boolean) =
        sp(ctx).edit().putBoolean(KEY_BATTERY_REQUESTED, value).apply()

    /** Stable random 16-hex id advertised over mDNS. */
    fun deviceId(ctx: Context): String {
        val sp = sp(ctx)
        sp.getString(KEY_DEVICE_ID, null)?.let { if (it.length == 16) return it }
        val id = Crypto.toHex(Crypto.randomBytes(8))
        sp.edit().putString(KEY_DEVICE_ID, id).apply()
        return id
    }

    /** Also the mDNS instance name and the `name` in `welcome`. */
    fun deviceName(ctx: Context): String =
        DeviceName.resolve(sp(ctx).getString(KEY_DEVICE_NAME, null), DeviceName.model()) { DeviceName.system(ctx) }

    fun paired(ctx: Context): List<PairedMac> {
        val raw = sp(ctx).getString(KEY_PAIRED, null) ?: return emptyList()
        val list = runCatching { Json.asList(Json.parse(raw)) }.getOrNull() ?: return emptyList()
        return list.mapNotNull { entry ->
            val m = Json.asObject(entry) ?: return@mapNotNull null
            val id = Json.str(m["clientId"]) ?: return@mapNotNull null
            val key = Json.str(m["key"]) ?: return@mapNotNull null
            PairedMac(id, Json.str(m["name"]) ?: "Mac", key, Json.long(m["lastConnected"]) ?: 0)
        }
    }

    fun addPaired(ctx: Context, mac: PairedMac) {
        val next = paired(ctx).filterNot { it.clientId == mac.clientId } + mac
        save(ctx, next)
    }

    fun forget(ctx: Context, clientId: String) {
        save(ctx, paired(ctx).filterNot { it.clientId == clientId })
    }

    private fun save(ctx: Context, macs: List<PairedMac>) {
        val json = Json.encode(
            macs.map {
                mapOf(
                    "clientId" to it.clientId,
                    "name" to it.name,
                    "key" to it.keyHex,
                    "lastConnected" to it.lastConnected,
                )
            },
        )
        sp(ctx).edit().putString(KEY_PAIRED, json).apply()
    }

    /** The payload pushed to the shell service via setPairedClients. */
    fun serviceStateJson(ctx: Context): String = Json.encode(
        mapOf(
            "deviceId" to deviceId(ctx),
            "deviceName" to deviceName(ctx),
            "clients" to paired(ctx).map { mapOf("clientId" to it.clientId, "name" to it.name, "key" to it.keyHex) },
        ),
    )
}
