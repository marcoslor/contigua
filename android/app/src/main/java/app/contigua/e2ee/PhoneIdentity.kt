package app.contigua.e2ee

import android.content.Context
import app.contigua.proto.Json
import java.io.File
import java.security.KeyPair
import java.security.KeyPairGenerator
import java.security.SecureRandom
import java.security.cert.X509Certificate
import java.security.spec.ECGenParameterSpec
import java.util.Base64
import java.util.Date
import javax.security.auth.x500.X500Principal

/**
 * The phone's v2 TLS identity (docs/design/e2ee.md §2): an in-memory software
 * P-256 key + self-signed cert, generated once per provisioning and persisted
 * in the app's own private files dir (mode 0600, FBE-encrypted at rest). The
 * private key never leaves the device; it is passed to the shell UID service
 * over the existing AIDL (`setPairedClients`'s "self" field).
 *
 * Storage lives in app data only; the shell (UID 2000) never reads this file.
 */
object PhoneIdentity {

    data class Identity(val certPem: String, val keyP8: String)

    private const val FILE = "identity_v2.json"
    private const val CN = "Contigua Phone"

    /** Read the persisted identity, generating it on first run. */
    fun ensure(ctx: Context): Identity {
        load(ctx)?.let { return it }
        val id = generate()
        save(ctx, id)
        return id
    }

    fun load(ctx: Context): Identity? {
        return try {
            val text = ctx.openFileInput(FILE).use { it.readBytes().toString(Charsets.UTF_8) }
            val obj = Json.parseObject(text)
            val cert = Json.str(obj["certPem"]) ?: return null
            val key = Json.str(obj["keyP8"]) ?: return null
            if (cert.isBlank() || key.isBlank()) null else Identity(cert, key)
        } catch (e: Exception) {
            null
        }
    }

    private fun save(ctx: Context, id: Identity) {
        val text = Json.encode(mapOf("certPem" to id.certPem, "keyP8" to id.keyP8))
        ctx.openFileOutput(FILE, Context.MODE_PRIVATE).use {
            it.write(text.toByteArray(Charsets.UTF_8))
        }
        // MODE_PRIVATE already creates 0600; be explicit for the security
        // review that checks the mode bits on the private path.
        runCatching {
            File(ctx.filesDir, FILE).setReadable(false, false)
            File(ctx.filesDir, FILE).setReadable(true, true)
            File(ctx.filesDir, FILE).setWritable(false, false)
            File(ctx.filesDir, FILE).setWritable(true, true)
        }
    }

    /**
     * Replace the identity with a fresh key and certificate. Only the person's
     * Paired Macs ▸ Forget All Macs… does this: every Mac's pin then fails, and
     * the shell service sees a different fingerprint (docs/specs/pairing.md
     * PAIR-20). A plain relaunch never rotates it.
     */
    fun rotate(ctx: Context): Identity {
        val id = generate()
        save(ctx, id)
        return id
    }

    private fun generate(): Identity {
        val kpg = KeyPairGenerator.getInstance("EC")
        kpg.initialize(ECGenParameterSpec("secp256r1"))
        val pair: KeyPair = kpg.generateKeyPair()
        val now = Date()
        val serial = SecureRandom().nextInt(Int.MAX_VALUE - 1) + 1
        val built = DerCert.buildComplete(
            CN, pair, serial,
            Date(now.time - DAY_MS),
            NOT_AFTER,
        )
        val certDer = built.der
        val certPem = pem("CERTIFICATE", certDer)
        val pkcs8 = pair.private.encoded ?: error("private key has no PKCS#8 encoding")
        val keyP8 = pem("PRIVATE KEY", pkcs8)
        return Identity(certPem, keyP8)
    }

    private fun pem(label: String, der: ByteArray): String {
        val b64 = Base64.getEncoder().encodeToString(der)
        val wrapped = b64.chunked(64).joinToString("\n")
        return "-----BEGIN $label-----\n$wrapped\n-----END $label-----"
    }

    private val DAY_MS = 24L * 60L * 60L * 1000L

    /**
     * RFC 5280's "no well-defined expiration" date (review L-5): the identity
     * lives as long as the app's data, and a pinned leaf must never expire on
     * the Mac. New identities only — an existing one is never regenerated.
     * 9999 needs a GeneralizedTime in DER; [DerCert.time] picks it.
     */
    private val NOT_AFTER: Date = java.util.Calendar
        .getInstance(java.util.TimeZone.getTimeZone("UTC"))
        .apply {
            clear()
            set(9999, java.util.Calendar.DECEMBER, 31, 23, 59, 59)
        }.time
}
