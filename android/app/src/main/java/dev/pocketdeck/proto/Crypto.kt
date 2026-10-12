package dev.pocketdeck.proto

import java.security.SecureRandom
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec

/** Hex + HMAC helpers used by the handshake (pure JVM, no Android). */
object Crypto {

    private val random = SecureRandom()

    fun randomBytes(n: Int): ByteArray = ByteArray(n).also { random.nextBytes(it) }

    fun toHex(bytes: ByteArray): String {
        val sb = StringBuilder(bytes.size * 2)
        for (b in bytes) {
            val v = b.toInt() and 0xFF
            sb.append(HEX[v ushr 4])
            sb.append(HEX[v and 0x0F])
        }
        return sb.toString()
    }

    fun fromHex(hex: String): ByteArray {
        require(hex.length % 2 == 0) { "hex length must be even" }
        val out = ByteArray(hex.length / 2)
        for (i in out.indices) {
            val hi = Character.digit(hex[i * 2], 16)
            val lo = Character.digit(hex[i * 2 + 1], 16)
            require(hi >= 0 && lo >= 0) { "invalid hex: $hex" }
            out[i] = ((hi shl 4) or lo).toByte()
        }
        return out
    }

    /** HMAC-SHA256 as lowercase hex, key = the 32 raw key bytes. */
    fun hmacSha256Hex(key: ByteArray, message: ByteArray): String {
        val mac = Mac.getInstance("HmacSHA256")
        mac.init(SecretKeySpec(key, "HmacSHA256"))
        return toHex(mac.doFinal(message))
    }

    fun constantTimeEquals(a: String, b: String): Boolean {
        if (a.length != b.length) return false
        var diff = 0
        for (i in a.indices) diff = diff or (a[i].code xor b[i].code)
        return diff == 0
    }

    private val HEX = "0123456789abcdef".toCharArray()
}
