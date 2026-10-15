package dev.pocketdeck.e2ee

import java.security.MessageDigest
import java.security.interfaces.ECPublicKey
import java.security.spec.ECPoint

/**
 * The certificate pin: SHA-256 over the 65-byte uncompressed EC point
 * `04||X||Y` (docs/design/e2ee.md §1). This is the canonical fingerprint on all
 * three stacks — Apple re-encodes certs and BoringSSL/SunJSSE may normalize,
 * but the raw P-256 point is stable; the QR, the pairing code inputs and the
 * pin stores all use this value.
 */
object KeyPin {

    /** Returns the 32-byte point pin for the given P-256 public key. */
    fun fingerprint(pub: ECPublicKey): ByteArray = digest(encodePoint(pub.w))

    /** Uncompressed point `04||X||Y`, exactly 65 bytes for P-256. */
    fun encodePoint(w: ECPoint): ByteArray {
        val x = leftPad(w.affineX.toByteArray(), 32)
        val y = leftPad(w.affineY.toByteArray(), 32)
        val out = ByteArray(65)
        out[0] = 0x04
        x.copyInto(out, 1)
        y.copyInto(out, 33)
        return out
    }

    fun digest(bytes: ByteArray): ByteArray = MessageDigest.getInstance("SHA-256").digest(bytes)

    fun toHex(bytes: ByteArray): String {
        val sb = StringBuilder(bytes.size * 2)
        for (b in bytes) {
            val v = b.toInt() and 0xFF
            sb.append(HEX[v ushr 4])
            sb.append(HEX[v and 0x0F])
        }
        return sb.toString()
    }

    private fun leftPad(v: ByteArray, len: Int): ByteArray {
        // BigInteger.byte[] is signed 2's complement; P-256 coordinates are
        // non-negative, drop the sign byte and pad on the left.
        val src = if (v.size > len && v[0] == 0.toByte()) v.copyOfRange(1, v.size) else v
        val out = ByteArray(len)
        src.copyInto(out, if (src.size <= len) len - src.size else 0)
        return out
    }

    private const val HEX = "0123456789abcdef"
}
