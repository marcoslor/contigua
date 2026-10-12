package dev.pocketdeck.app

import java.net.URI
import java.net.URLDecoder

/**
 * Parses the Mac's pairing QR into a client id, name and one-time key. The Mac
 * writes `pocketdeck://pair?c=<clientId>&n=<url-encoded name>&k=<64 hex>`
 * (docs/UX.md, "Pairing model").
 *
 * Pure (no Android types) so the whole accept/reject matrix is JVM-testable.
 */
object QrPairing {

    /** A pairing key is 32 bytes of hex (docs/PROTOCOL.md auth key). */
    const val KEY_HEX_LENGTH = 64

    private const val SCHEME = "pocketdeck"
    private const val HOST = "pair"

    sealed interface Result {
        data class Pairing(val clientId: String, val name: String, val keyHex: String) : Result

        /** Not a PocketDeck pairing URI at all. */
        data object NotPairing : Result

        /** Our URI, but `c`/`k` are missing or empty. */
        data object Malformed : Result

        /** `c` and `k` are present but `k` is not [KEY_HEX_LENGTH] hex characters. */
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
        val key = params["k"]?.takeIf { it.isNotBlank() } ?: return Result.Malformed
        if (!isHex(key, KEY_HEX_LENGTH)) return Result.BadKey

        val name = params["n"]?.takeIf { it.isNotBlank() } ?: "Mac"
        return Result.Pairing(clientId, name, key.lowercase())
    }

    private fun parseQuery(raw: String?): Map<String, String> {
        if (raw.isNullOrEmpty()) return emptyMap()
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
