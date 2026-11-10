package dev.pocketdeck.app

import android.content.Context
import dev.pocketdeck.proto.Crypto
import dev.pocketdeck.proto.Json

/** Small owned store for the app process: identity, paired clients, enable flag. */
object Prefs {

    private const val FILE = "pocketdeck"
    private const val KEY_ENABLED = "enabled"
    private const val KEY_ALLOW_CONNECTIONS = "allow_connections"
    private const val KEY_ALLOW_PAIRINGS = "allow_pairings"
    private const val KEY_DEVICE_ID = "device_id"
    private const val KEY_DEVICE_NAME = "device_name"
    private const val KEY_PAIRED = "paired"
    private const val KEY_PENDING_QR = "pending_qr"
    private const val KEY_ONBOARDING_DONE = "onboarding_done"
    private const val KEY_BATTERY_REQUESTED = "battery_requested"
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

    /**
     * The master connection gate (docs/PROTOCOL.md "Error codes"). ON by
     * default; OFF refuses every Mac, paired or not, and drops live sessions.
     * The shell server defaults to refused until the app pushes this value, so
     * an unreadable setting fails closed.
     */
    fun isAllowConnections(ctx: Context): Boolean =
        sp(ctx).getBoolean(KEY_ALLOW_CONNECTIONS, true)

    fun setAllowConnections(ctx: Context, value: Boolean) =
        sp(ctx).edit().putBoolean(KEY_ALLOW_CONNECTIONS, value).apply()

    /** Whether an unknown Mac may start a pairing. Paired Macs are unaffected. */
    fun isAllowPairings(ctx: Context): Boolean =
        sp(ctx).getBoolean(KEY_ALLOW_PAIRINGS, true)

    fun setAllowPairings(ctx: Context, value: Boolean) =
        sp(ctx).edit().putBoolean(KEY_ALLOW_PAIRINGS, value).apply()

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
            // The current record carries the Mac cert's point fingerprint; an
            // entry without a well-formed one is not a record and is ignored.
            val pin = Json.str(m["macFp"]) ?: return@mapNotNull null
            if (pin.length != 64) return@mapNotNull null
            PairedMac(id, Json.str(m["name"]) ?: "Mac", pin.lowercase(), Json.long(m["lastConnected"]) ?: 0)
        }
    }

    /**
     * [macs] with [clientId]'s `lastConnected` moved to [at]; the other rows keep
     * theirs. Pure so the session-start/end bookkeeping is JVM-testable.
     */
    fun stamped(macs: List<PairedMac>, clientId: String, at: Long): List<PairedMac> =
        macs.map { if (it.clientId == clientId) it.copy(lastConnected = at) else it }

    /** A session started or ended: remember when this Mac was last live. */
    fun touchLastConnected(ctx: Context, clientId: String, at: Long) {
        val macs = paired(ctx)
        if (macs.none { it.clientId == clientId }) return
        save(ctx, stamped(macs, clientId, at))
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
        val identityFp = self
            ?.let { dev.pocketdeck.e2ee.IdentityPin.of(it["certPem"] as String) }
            .orEmpty()
        val qr = pendingQr(ctx)
        val pendingQr = qr?.let {
            mapOf("clientId" to it.clientId, "name" to it.name, "macFp" to it.macFp,
                  "secret" to it.secret, "at" to it.at)
        }
        return Json.encode(
            mapOf(
                "deviceId" to deviceId(ctx),
                "deviceName" to deviceName(ctx),
                // The shell compares this with what it holds on every push: a
                // different identity means the app's data was cleared or the
                // person forgot all Macs (docs/design/e2ee.md §10).
                "identityFp" to identityFp,
                "clients" to paired(ctx).map { mapOf("clientId" to it.clientId, "name" to it.name, "macFp" to it.macFp) },
                "self" to self,
                "pendingQr" to pendingQr,
            ),
        )
    }

    /**
     * Paired Macs ▸ Forget All Macs…: a fresh identity and no pairings, so no
     * Mac's pin matches this phone again and every live session is dropped
     * (docs/specs/pairing.md PAIR-20).
     */
    fun forgetAll(ctx: Context) {
        dev.pocketdeck.e2ee.PhoneIdentity.rotate(ctx)
        sp(ctx).edit().remove(KEY_PAIRED).remove(KEY_PENDING_QR).apply()
    }
}
