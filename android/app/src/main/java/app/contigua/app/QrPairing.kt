package app.contigua.app

import java.net.URI
import java.net.URLDecoder

/**
 * Parses the Mac's pairing QR into its v2 payload (review R2):
 * `contigua://pair?c=<clientId>&n=<url-encoded name>&f=<macFP 64 hex>&s=<secret 32 hex>`.
 * The phone pins the Mac by `f` and answers the Mac over the TLS connection
 * with `pair.qr` HMAC of `s` (docs/design/e2ee.md §6); `s` lives only in RAM
 * until the shell server consumes it.
 *
 * Pure (no Android types) so the whole accept/reject matrix is JVM-testable.
 */
object QrPairing {

    /** A fingerprint is 32 bytes of hex; the one-time secret is 16 bytes. */
    const val FP_HEX_LENGTH = 64
    const val SECRET_HEX_LENGTH = 32

    private const val SCHEME = "contigua"
    private const val HOST = "pair"

    sealed interface Result {
        data class Pairing(
            val clientId: String,
            val name: String,
            /** The Mac's certificate point fingerprint (the pin the phone keeps). */
            val macFpHex: String,
            /** The one-time secret: its HMAC proves the scan. */
            val secretHex: String,
        ) : Result

        /** Not a Contigua pairing URI at all. */
        data object NotPairing : Result

        /** Our URI, but a required parameter is missing or empty. */
        data object Malformed : Result

        /** Parameters present but `f`/`s` are not well-formed hex of the right length (v1 keys land here too). */
        data object BadKey : Result
    }

    fun parse(raw: String): Result {
        val uri = try {
            URI(raw.trim())
        } catch (e: Exception) {
            return Result.NotPairing
        }
        if (!SCHEME.equals(uri.scheme, ignoreCase = true)) return Result.NotPairing
        if (!HOST.equals(uri.host, ignoreCase = true)) return Result.NotPairing

        val params = parseQuery(uri.rawQuery)
        val clientId = params["c"]?.takeIf { it.isNotBlank() } ?: return Result.Malformed
        val fp = params["f"]?.takeIf { it.isNotBlank() } ?: return Result.Malformed
        val secret = params["s"]?.takeIf { it.isNotBlank() } ?: return Result.Malformed
        if (!isHex(fp, FP_HEX_LENGTH) || !isHex(secret, SECRET_HEX_LENGTH)) return Result.BadKey

        val name = params["n"]?.takeIf { it.isNotBlank() } ?: "Mac"
        return Result.Pairing(clientId, name, fp.lowercase(), secret.lowercase())
    }

    /**
     * L-2: the exported `contigua://pair` link must not replace a pending QR
     * that came from a different Mac while it is still fresh. `null` (no
     * pending, or an expired one) accepts; the same fingerprint refreshes.
     *
     * Pure so the rule is pinned without Android (the caller passes the store's
     * current entry plus the wall clock).
     */
    fun mayReplacePending(
        existingFpHex: String?,
        existingAtMs: Long,
        incomingFpHex: String,
        nowMs: Long,
        ttlMs: Long,
    ): Boolean {
        if (existingFpHex == null) return true
        if (nowMs - existingAtMs !in 0..ttlMs) return true
        return existingFpHex.equals(incomingFpHex, ignoreCase = true)
    }

    private fun parseQuery(raw: String?): Map<String, String> {        if (raw.isNullOrEmpty()) return emptyMap()
        val out = LinkedHashMap<String, String>()
        for (pair in raw.split('&')) {
            if (pair.isEmpty()) continue
            val eq = pair.indexOf('=')
            val key = if (eq < 0) pair else pair.substring(0, eq)
            val value = if (eq < 0) "" else pair.substring(eq + 1)
            out[decode(key)] = decode(value)
        }
        return out
    }

    private fun decode(value: String): String =
        runCatching { URLDecoder.decode(value, "UTF-8") }.getOrDefault(value)

    private fun isHex(value: String, length: Int): Boolean {
        if (value.length != length) return false
        return value.all { it in '0'..'9' || it in 'a'..'f' || it in 'A'..'F' }
    }
}
