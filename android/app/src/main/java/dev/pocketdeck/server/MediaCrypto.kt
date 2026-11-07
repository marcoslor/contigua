package dev.pocketdeck.server

import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.security.MessageDigest
import javax.crypto.Cipher
import javax.crypto.Mac
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

/**
 * P3's media keys and AEAD (docs/design/media-transport.md §2.3, PATH-26).
 *
 * The input is the session's existing 32-byte TLS exporter
 * (`EXPORTER-pocketdeck-pair`), not a new key exchange. HKDF-SHA256 binds the
 * session id, both SPKI pins and the exporter label:
 *
 *   context = sessionId ‖ macPin ‖ phonePin ‖ "EXPORTER-pocketdeck-pair"
 *   PRK     = HKDF-Extract(context, exporter)
 *   c2s/s2c = HKDF-Expand(PRK, "pocketdeck-media-c2s"/"-s2c", 32)
 *
 * Pure JVM: `javax.crypto` plus the pinned HKDF math, so K1 drives every byte
 * without a TLS engine (the pairing spike already proved the exporter itself
 * byte-equal on both ends).
 */
object MediaCrypto {
    const val KEY_BYTES = 32
    const val NONCE_BYTES = 12
    const val EXPORTER_LABEL = "EXPORTER-pocketdeck-pair"

    /** One session's two directions; [keyId] is the first 4 bytes of SHA-256(c2s‖s2c). */
    class Keys(val keyId: Int, val c2s: ByteArray, val s2c: ByteArray) {
        /** Clears both keys; the caller drops the object afterwards. */
        fun clear() {
            c2s.fill(0)
            s2c.fill(0)
        }

        override fun equals(other: Any?): Boolean =
            other is Keys && keyId == other.keyId &&
                c2s.contentEquals(other.c2s) && s2c.contentEquals(other.s2c)

        override fun hashCode(): Int =
            (keyId * 31 + c2s.contentHashCode()) * 31 + s2c.contentHashCode()
    }

    /** The session id is the 32 lowercase hex characters as ASCII, as JSON carries it. */
    fun derive(exporter: ByteArray, sessionId: String, macPin: ByteArray, phonePin: ByteArray): Keys {
        require(exporter.size == KEY_BYTES) { "exporter" }
        require(macPin.size == KEY_BYTES && phonePin.size == KEY_BYTES) { "pins" }
        require(sessionId.length == 32 && sessionId.all { it in "0123456789abcdef" }) { "session id" }
        val context = sessionId.toByteArray(Charsets.US_ASCII) + macPin + phonePin +
            EXPORTER_LABEL.toByteArray(Charsets.US_ASCII)
        val prk = hkdfExtract(context, exporter)
        val c2s = hkdfExpand(prk, "pocketdeck-media-c2s".toByteArray(Charsets.US_ASCII), KEY_BYTES)
        val s2c = hkdfExpand(prk, "pocketdeck-media-s2c".toByteArray(Charsets.US_ASCII), KEY_BYTES)
        val digest = sha256(c2s + s2c)
        val keyId = ByteBuffer.wrap(digest.copyOf(4)).order(ByteOrder.BIG_ENDIAN).int
        prk.fill(0)
        digest.fill(0)
        return Keys(keyId, c2s, s2c)
    }

    /** Seals one inner header+payload into `outer ‖ ciphertext‖tag`. */
    fun seal(key: ByteArray, seq: Long, outer: ByteArray, inner: ByteArray): ByteArray {
        require(key.size == KEY_BYTES) { "key" }
        require(outer.size == MediaDatagram.OUTER_HEADER) { "outer" }
        require(seq > 0) { "seq" }
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(128, nonce(seq)))
        cipher.updateAAD(outer)
        val sealed = cipher.doFinal(inner)
        return outer + sealed
    }

    /**
     * Opens a whole datagram, returning the plaintext inner bytes after the
     * outer header was checked and the tag verified; null on any failure.
     */
    fun open(key: ByteArray, datagram: ByteArray): ByteArray? {
        if (key.size != KEY_BYTES) return null
        val outer = MediaDatagram.parseOuter(datagram) ?: return null
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        return try {
            cipher.init(Cipher.DECRYPT_MODE, SecretKeySpec(key, "AES"),
                GCMParameterSpec(128, nonce(outer.seq)))
            cipher.updateAAD(datagram, 0, MediaDatagram.OUTER_HEADER)
            cipher.doFinal(datagram, MediaDatagram.OUTER_HEADER, outer.ciphertextLen)
        } catch (e: java.security.GeneralSecurityException) {
            null
        }
    }

    /**
     * Opens a datagram and only then advances [replay]: AEAD must verify
     * before a sequence is accepted. If the window moved first, one tampered
     * high-seq datagram would push every valid packet out of the window.
     * Returns the plaintext inner bytes, or null when the tag fails or the
     * sequence is a duplicate/outside the window.
     */
    fun openAndAccept(
        key: ByteArray,
        datagram: ByteArray,
        replay: MediaReplayWindow,
    ): ByteArray? {
        val outer = MediaDatagram.parseOuter(datagram) ?: return null
        val inner = open(key, datagram) ?: return null
        if (!replay.accept(outer.seq)) return null
        return inner
    }

    /** The 96-bit nonce: 4 zero bytes then the per-direction u64 sequence. */
    fun nonce(seq: Long): ByteArray =
        ByteBuffer.allocate(NONCE_BYTES).order(ByteOrder.BIG_ENDIAN).putInt(0).putLong(seq).array()

    /** RFC 5869 §2.2: HKDF-Extract with HMAC-SHA256. */
    fun hkdfExtract(salt: ByteArray, ikm: ByteArray): ByteArray {
        val mac = Mac.getInstance("HmacSHA256")
        mac.init(SecretKeySpec(if (salt.isEmpty()) ByteArray(32) else salt, "HmacSHA256"))
        return mac.doFinal(ikm)
    }

    /** RFC 5869 §2.3: HKDF-Expand with HMAC-SHA256. */
    fun hkdfExpand(prk: ByteArray, info: ByteArray, length: Int): ByteArray {
        require(length in 1..255 * 32) { "length" }
        val mac = Mac.getInstance("HmacSHA256")
        mac.init(SecretKeySpec(prk, "HmacSHA256"))
        val out = ByteArray(length)
        var t = ByteArray(0)
        var offset = 0
        var counter = 1
        while (offset < length) {
            mac.reset()
            mac.update(t)
            mac.update(info)
            mac.update(counter.toByte())
            t = mac.doFinal()
            val take = minOf(t.size, length - offset)
            t.copyInto(out, offset, 0, take)
            offset += take
            counter++
        }
        t.fill(0)
        return out
    }

    /** The replay window a cap needs for one second of full fragments. */
    fun requiredReplayWindow(capBps: Int, seconds: Int = 1): Int {
        require(capBps > 0) { "cap" }
        val perSecond = MediaDatagram.MAX_FRAGMENT * 8L
        val packets = (capBps.toLong() * seconds + perSecond - 1) / perSecond
        // MediaReplayWindow takes a multiple of 64: round the requirement up so
        // the caller can construct it directly (20 Mbit/s needs 2193 -> 2240).
        return ((packets + 63) / 64 * 64).toInt()
    }

    fun sha256(bytes: ByteArray): ByteArray = MessageDigest.getInstance("SHA-256").digest(bytes)
}
