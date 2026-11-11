package app.contigua.e2ee

import java.security.MessageDigest
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec

/**
 * Commit / nonce / reveal pairing code (docs/design/e2ee.md §4, R1). Pure
 * JVM math: the phone commits to a fresh nonce `Np` before the Mac releases
 * `Nm`, both sides mix in the TLS exporter plus the two certificate point
 * fingerprints, and the Mac checks the commitment at reveal time (error
 * `pair_commit` on a mismatch).
 */
object PairingCodeV2 {
    private const val COMMIT_LABEL = "pd-commit-v2"
    private const val CODE_LABEL = "pd-code-v2"
    private const val QR_LABEL = "pd-qr-v2"

    fun sha256(data: ByteArray): ByteArray = MessageDigest.getInstance("SHA-256").digest(data)

    fun concat(vararg parts: ByteArray): ByteArray {
        var n = 0
        for (p in parts) n += p.size
        val out = ByteArray(n)
        var pos = 0
        for (p in parts) { p.copyInto(out, pos); pos += p.size }
        return out
    }

    /** hex(SHA-256("pd-commit-v2" || Np || phoneFP || macFP)) */
    fun commit(Np: ByteArray, phoneFp: ByteArray, macFp: ByteArray): ByteArray =
        sha256(concat(COMMIT_LABEL.toByteArray(Charsets.UTF_8), Np, phoneFp, macFp))

    /**
     * code = uint64_be(SHA-256("pd-code-v2" || exporter || macFP || phoneFP
     *                           || Nm || Np)[0..8]) mod 1_000_000
     */
    fun code(exporter: ByteArray, macFp: ByteArray, phoneFp: ByteArray, Nm: ByteArray, Np: ByteArray): Int {
        val h = sha256(concat(CODE_LABEL.toByteArray(Charsets.UTF_8), exporter, macFp, phoneFp, Nm, Np))
        val v = java.nio.ByteBuffer.wrap(h).getLong()
        return java.lang.Long.remainderUnsigned(v, 1_000_000L).toInt()
    }

    fun codeHex(value: Int): String = "%06d".format(value)

    /** HMAC-SHA256(S, "pd-qr-v2" || exporter || phoneFP) for the QR auth path. */
    fun qrHmac(secret: ByteArray, exporter: ByteArray, phoneFp: ByteArray): ByteArray {
        val mac = Mac.getInstance("HmacSHA256")
        mac.init(SecretKeySpec(secret, "HmacSHA256"))
        return mac.doFinal(concat(QR_LABEL.toByteArray(Charsets.UTF_8), exporter, phoneFp))
    }

    fun hex(bytes: ByteArray): String = TlsExporter.toHex(bytes)
}
