package dev.pocketdeck.direct

import dev.pocketdeck.proto.Crypto
import java.util.Base64
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec

/**
 * The service-specific info that discovery carries (docs/design/direct-link.md
 * §6, transport DIRECT-10):
 *
 *   ssi = HMAC-SHA256(psk, "pd-nan-v1" || u64_be(window))[0..8]
 *
 * Nothing here is logged: the 8 bytes are auth material, not a name.
 */
object Ssi {
    private val PREFIX = "pd-nan-v1".toByteArray(Charsets.US_ASCII)

    fun window(epochSeconds: Long): Long = epochSeconds / DirectConfig.SSI_WINDOW_SECONDS

    fun bytes(key: ByteArray, window: Long): ByteArray {
        val mac = Mac.getInstance("HmacSHA256")
        mac.init(SecretKeySpec(key, "HmacSHA256"))
        mac.update(PREFIX)
        val packed = ByteArray(8)
        for (i in 0 until 8) packed[i] = (window ushr (56 - 8 * i)).toByte()
        mac.update(packed)
        return mac.doFinal().copyOfRange(0, 8)
    }

    fun hex(key: ByteArray, window: Long): String = Crypto.toHex(bytes(key, window))

    /** The passphrase form for the one line that may name a key (never this). */
    fun passphrase(key: ByteArray): String = Base64.getEncoder().encodeToString(key)
}
