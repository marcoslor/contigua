package dev.pocketdeck.e2ee

import android.net.ssl.SSLSockets
import android.os.Build

import java.nio.ByteBuffer
import java.security.MessageDigest
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec

/**
 * Pure-JVM implementation of the TLS 1.3 exporter (docs/design/e2ee.md §4b).
 * The Mac side computes the same bytes from BoringSSL's keylog `EXPORTER_SECRET`
 * line; the phone side obtains them from `android.net.ssl.SSLSockets
 * .exportKeyingMaterial`. This object pins the RFC 8446 §7.5 math so both
 * stacks agree without a TLS engine in the test.
 */
object TlsExporter {
    const val LABEL = "EXPORTER-pocketdeck-pair"
    const val CONTEXT_EMPTY = ""

    /** `SSLSockets.exportKeyingMaterial` arrived in API 31; minSdk is 30. */
    const val MIN_EXPORT_SDK = 31

    fun exportSupported(sdkInt: Int): Boolean = sdkInt >= MIN_EXPORT_SDK

    /** RFC 8446 §7.5: two HKDF-Expand-Label steps, empty context. */
    fun derive(exporterSecret: ByteArray): ByteArray {
        val emptyHash = sha256(byteArrayOf())
        val inner = expandLabel(exporterSecret, LABEL, emptyHash, 32)
        return expandLabel(inner, "exporter", emptyHash, 32)
    }

    /** HKDF-Expand-Label (RFC 8446 §7.1) with the "tls13 " prefix. */
    fun expandLabel(secret: ByteArray, label: String, hash: ByteArray, length: Int): ByteArray {
        val info = ByteBuffer.allocate(2 + 1 + ("tls13 $label").length + 1 + hash.size)
        info.putShort(length.toShort())
        info.put(("tls13 $label").length.toByte())
        info.put(("tls13 $label").toByteArray(Charsets.UTF_8))
        info.put(hash.size.toByte())
        info.put(hash)
        return hkdfExpand(secret, info.array(), length)
    }

    private fun hkdfExpand(prk: ByteArray, info: ByteArray, length: Int): ByteArray {
        val mac = Mac.getInstance("HmacSHA256")
        mac.init(SecretKeySpec(prk, "HmacSHA256"))
        val out = ByteArray(length)
        var t = ByteArray(0)
        var pos = 0
        var counter: Byte = 1
        while (pos < length) {
            mac.reset()
            mac.update(t)
            mac.update(info)
            mac.update(counter)
            t = mac.doFinal()
            for (i in t.indices) {
                if (pos + i < length) out[pos + i] = t[i]
            }
            pos += t.size
            counter = (counter + 1).toByte()
        }
        return out
    }

    fun sha256(data: ByteArray): ByteArray = MessageDigest.getInstance("SHA-256").digest(data)

    /**
     * Platform acquisition. `SSLSockets.exportKeyingMaterial` is API 31; the
     * app's minSdk is 30, so an API 30 phone MUST NOT reach the call (it would
     * throw `NoSuchMethodError`). It returns null there, and the pairing path
     * fails closed with `pair_exporter`; the Mac says the phone needs a newer
     * Android. On API 31+ the call is guarded by `isSupportedSocket` and any
     * engine refusal is null, never a zero key.
     *
     * The platform call is:
     *   android.net.ssl.SSLSockets.exportKeyingMaterial(sslSocket, LABEL,
     *       emptyContext, 32)
     */
    fun tryExportKeyingMaterial(socket: javax.net.ssl.SSLSocket): ByteArray? {
        if (!exportSupported(Build.VERSION.SDK_INT)) return null
        if (!SSLSockets.isSupportedSocket(socket)) return null
        return try {
            SSLSockets.exportKeyingMaterial(socket, LABEL, ByteArray(0), 32)
        } catch (e: Throwable) {
            null
        }
    }

    fun toHex(bytes: ByteArray): String {
        val sb = StringBuilder(bytes.size * 2)
        for (b in bytes) {
            val v = b.toInt() and 0xFF
            sb.append("0123456789abcdef"[v ushr 4])
            sb.append("0123456789abcdef"[v and 0x0F])
        }
        return sb.toString()
    }
}
