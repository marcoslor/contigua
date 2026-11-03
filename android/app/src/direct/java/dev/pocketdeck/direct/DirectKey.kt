package dev.pocketdeck.direct

import dev.pocketdeck.proto.Crypto
import java.security.MessageDigest
import java.util.Base64

/**
 * The 32-byte NDP key (docs/design/direct-link.md §5, transport DIRECT-9):
 * 64 lowercase hex on the wire, base64 for the platform's passphrase, and an
 * 8-hex SHA-256 prefix as its only log form.
 */
object DirectKey {
    const val BYTES = 32
    const val HEX_LENGTH = BYTES * 2

    /** 32 bytes from exactly 64 hex characters; null for anything else. */
    fun parse(raw: String?): ByteArray? {
        if (raw == null || raw.length != HEX_LENGTH) return null
        val out = ByteArray(BYTES)
        for (i in 0 until BYTES) {
            val hi = Character.digit(raw[i * 2], 16)
            val lo = Character.digit(raw[i * 2 + 1], 16)
            if (hi < 0 || lo < 0) return null
            out[i] = ((hi shl 4) or lo).toByte()
        }
        return out
    }

    fun hex(key: ByteArray): String = Crypto.toHex(key)

    /** The Wi-Fi Aware passphrase is the base64 of the raw bytes (§5). */
    fun passphrase(key: ByteArray): String = Base64.getEncoder().encodeToString(key)

    /** R-PRIV-1's one key line: the first 8 hex of SHA-256(key). */
    fun fingerprint(key: ByteArray): String {
        val digest = MessageDigest.getInstance("SHA-256").digest(key)
        return Crypto.toHex(digest.copyOfRange(0, 4))
    }
}

/**
 * Where the sealed key lives, per Mac. The phone's implementation seals it
 * with a non-exportable Android Keystore key and stores the ciphertext in the
 * app's private prefs; K1 hands in an in-memory fake.
 */
interface DirectKeyStore {
    fun get(clientId: String): ByteArray?
    fun put(clientId: String, key: ByteArray)
    fun remove(clientId: String)
}

/** The key's small pure surface: parse, store, rotate, forget. */
class DirectKeys(private val store: DirectKeyStore) {

    fun store(clientId: String, raw: String): Boolean {
        val key = DirectKey.parse(raw) ?: return false
        return put(clientId, key)
    }

    fun put(clientId: String, key: ByteArray): Boolean =
        runCatching {
            store.put(clientId, key)
            true
        }.getOrDefault(false)

    fun key(clientId: String): ByteArray? = runCatching { store.get(clientId) }.getOrNull()

    fun forget(clientId: String) {
        runCatching { store.remove(clientId) }
    }
}

/**
 * `direct.key` from the Mac (docs/PROTOCOL.md "Direct link"): a malformed key is
 * refused with no `direct.key.ok`, so the Mac regenerates one on the next LAN
 * session. The log line carries the hash prefix and length only.
 */
class DirectKeyHandler(
    private val keys: DirectKeys,
    private val ack: (Boolean) -> Unit,
    private val log: (String) -> Unit = {},
) {
    fun onWireKey(clientId: String, raw: String) {
        val key = DirectKey.parse(raw)
        if (key == null) {
            log("direct key: rejected len=${raw.length}")
            ack(false)
            return
        }
        val stored = keys.put(clientId, key)
        if (stored) log("direct key: stored key=${DirectKey.fingerprint(key)} len=${key.size}")
        else log("direct key: store failed")
        ack(stored)
    }
}
