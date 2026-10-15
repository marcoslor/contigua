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
    private const val KEY_PENDING_QR = "pending_qr"
    private const val KEY_ONBOARDING_DONE = "onboarding_done"
    private const val KEY_BATTERY_REQUESTED = "battery_requested"
    private const val KEY_NOTIFY_SHARED = "notify_shared"

    /**
     * A scanned Mac QR (review R2): the phone pins the Mac by `f` and answers
     * the Mac over TLS with `pair.qr` HMAC of `s`. Kept only until it is served
     * once or expires with the QR (5 minutes).
     */
    data class PendingQr(
        val clientId: String,
        val name: String,
        /** The Mac's point fingerprint (64 lowercase hex). */
        val macFp: String,
        /** One-time secret (32 lowercase hex), consumed by the shell server. */
        val secret: String,
        /** Local epoch millis of the scan. */
        val at: Long,
    )

    /** Where the QR expires on the phone side, matching the Mac's sheet. */
    const val PENDING_QR_TTL_MS = 5 * 60 * 1000L

    data class PairedMac(
        val clientId: String,
        val name: String,
        /** v2: the Mac cert's point fingerprint (64 lowercase hex), not a key. */
        val macFp: String,
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

    /**
     * The per-phone opt-in for sharing notifications and the media session with a
     * connected Mac. Default OFF (privacy); the grant and forwarding only start
     * while this is true.
     */
    fun isNotifyShared(ctx: Context): Boolean = sp(ctx).getBoolean(KEY_NOTIFY_SHARED, false)

    fun setNotifyShared(ctx: Context, value: Boolean) =
        sp(ctx).edit().putBoolean(KEY_NOTIFY_SHARED, value).apply()

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
            // v2 only: entries without a pin are v1 leftovers and are dropped
            // (docs/design/e2ee.md §7 — the forced re-pair, no reverse path).
            val pin = Json.str(m["macFp"]) ?: return@mapNotNull null
            if (pin.length != 64) return@mapNotNull null
            PairedMac(id, Json.str(m["name"]) ?: "Mac", pin.lowercase(), Json.long(m["lastConnected"]) ?: 0)
        }
    }

    fun addPaired(ctx: Context, mac: PairedMac) {
        val next = paired(ctx).filterNot { it.clientId == mac.clientId } + mac
        save(ctx, next)
    }

    fun forget(ctx: Context, clientId: String) {
        save(ctx, paired(ctx).filterNot { it.clientId == clientId })
    }

    /** The scanned-but-unanswered QR; null when none or expired. */
    fun pendingQr(ctx: Context): PendingQr? {
        val raw = sp(ctx).getString(KEY_PENDING_QR, null) ?: return null
        val obj = runCatching { Json.asObject(Json.parse(raw)) }.getOrNull() ?: return null
        val clientId = Json.str(obj["clientId"]) ?: return null
        val fp = Json.str(obj["macFp"]) ?: return null
        val secret = Json.str(obj["secret"]) ?: return null
        val at = Json.long(obj["at"]) ?: 0
        val qr = PendingQr(clientId, Json.str(obj["name"]) ?: "Mac", fp, secret, at)
        return if (System.currentTimeMillis() - at in 0..PENDING_QR_TTL_MS) qr else null
    }

    fun setPendingQr(ctx: Context, qr: PendingQr) {
        val json = Json.encode(mapOf(
            "clientId" to qr.clientId,
            "name" to qr.name,
            "macFp" to qr.macFp,
            "secret" to qr.secret,
            "at" to qr.at,
        ))
        sp(ctx).edit().putString(KEY_PENDING_QR, json).apply()
    }

    /** The QR was answered (or the sheet gave up): drop the secret from storage. */
    fun clearPendingQr(ctx: Context) {
        sp(ctx).edit().remove(KEY_PENDING_QR).apply()
    }

    private fun save(ctx: Context, macs: List<PairedMac>) {
        val json = Json.encode(
            macs.map {
                mapOf(
                    "clientId" to it.clientId,
                    "name" to it.name,
                    "macFp" to it.macFp,
                    "lastConnected" to it.lastConnected,
                )
            },
        )
        sp(ctx).edit().putString(KEY_PAIRED, json).apply()
    }

    /** The payload pushed to the shell service via setPairedClients. */
    fun serviceStateJson(ctx: Context): String {
        val self = runCatching {
            val id = dev.pocketdeck.e2ee.PhoneIdentity.ensure(ctx)
            mapOf("certPem" to id.certPem, "keyP8" to id.keyP8)
        }.getOrNull()
        val qr = pendingQr(ctx)
        val pendingQr = qr?.let {
            mapOf("clientId" to it.clientId, "name" to it.name, "macFp" to it.macFp,
                  "secret" to it.secret, "at" to it.at)
        }
        return Json.encode(
            mapOf(
                "deviceId" to deviceId(ctx),
                "deviceName" to deviceName(ctx),
                "clients" to paired(ctx).map { mapOf("clientId" to it.clientId, "name" to it.name, "macFp" to it.macFp) },
                "self" to self,
                "pendingQr" to pendingQr,
            ),
        )
    }
}
