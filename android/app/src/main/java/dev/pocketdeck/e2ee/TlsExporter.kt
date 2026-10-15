package dev.pocketdeck.e2ee

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
     * Platform acquisition (Android API 29+, minSdk 30). Resolved by
     * reflection so this module still compiles/tests on the JVM where
     * `android.net.ssl.SSLSockets` is absent. Returns null outside Android or
     * when the socket is not supported. The caller (the shell server, on a
     * platform SSLSocket) obtains the 32 RFC bytes after the handshake.
     *
     * Production call site equivalent:
     *   android.net.ssl.SSLSockets.exportKeyingMaterial(sslSocket, LABEL,
     *       emptyContext, 32)
     * guarded by
     *   android.net.ssl.SSLSockets.isSupportedSocket(sslSocket)
     */
    fun tryExportKeyingMaterial(socket: Any): ByteArray? {
        return try {
            val cls = Class.forName("android.net.ssl.SSLSockets")
            val supported = cls.getMethod("isSupportedSocket",
                Class.forName("javax.net.ssl.SSLSocket")).invoke(null, socket) as? Boolean ?: false
            if (!supported) return null
            cls.getMethod("exportKeyingMaterial",
                Class.forName("javax.net.ssl.SSLSocket"), String::class.java,
                ByteArray::class.java, Int::class.javaPrimitiveType)
                .invoke(null, socket, LABEL, ByteArray(0), 32) as? ByteArray
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
