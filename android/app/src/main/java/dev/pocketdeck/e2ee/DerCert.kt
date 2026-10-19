package dev.pocketdeck.e2ee

import java.math.BigInteger
import java.security.KeyPair
import java.security.Signature
import java.security.interfaces.ECPublicKey
import java.util.Date

/**
 * Minimal deterministic DER builder producing a self-signed X.509 v3 cert for
 * the device's TLS identity (docs/design/e2ee.md §2). Android has no Conscrypt
 * cert builder and BouncyCastle is refused as a dependency, so this builds the
 * small DER subset by hand: P-256 key, ECDSA-with-SHA256 signature, extensions
 * SAN(IP, non-critical — subject is present), EKU(server+client),
 * BC(critical, end-entity). Validity uses the ±1 day margin the phase-1 spikes
 * found necessary under BoringSSL's evaluator — the caller passes both dates.
 *
 * The TBSCertificate is deterministic for the same inputs (pinned test); the
 * ECDSA signature value varies with its random k, as every cert authority's.
 */
object DerCert {

    // DER tags
    private const val TAG_SEQUENCE = 0x30
    private const val TAG_SET = 0x31
    private const val TAG_INTEGER = 0x02
    private const val TAG_BIT_STRING = 0x03
    private const val TAG_OCTET_STRING = 0x04
    private const val TAG_OID = 0x06
    private const val TAG_UTF8_STRING = 0x0C
    private const val TAG_UTC_TIME = 0x17
    private const val TAG_GENERALIZED_TIME = 0x18
    private const val TAG_BOOLEAN = 0x01
    private const val TAG_NULL = 0x05

    // OIDs
    private val OID_ECDSA_WITH_SHA256 = oid(1, 2, 840, 10045, 4, 3, 2)   // ecdsa-with-SHA256
    private val OID_EC_PUBLIC_KEY = oid(1, 2, 840, 10045, 2, 1)          // id-ecPublicKey
    private val OID_PRIME256V1 = oid(1, 2, 840, 10045, 3, 1, 7)          // secp256r1 (prime256v1)
    private val OID_CN = oid(2, 5, 4, 3)                                 // commonName
    private val OID_SUBJECT_ALT_NAME = oid(2, 5, 29, 17)                 // subjectAltName
    private val OID_EXT_KEY_USAGE = oid(2, 5, 29, 37)                    // extendedKeyUsage
    private val OID_BASIC_CONSTRAINTS = oid(2, 5, 29, 19)                // basicConstraints
    private val OID_SERVER_AUTH = oid(1, 3, 6, 1, 5, 5, 7, 3, 1)         // id-kp-serverAuth
    private val OID_CLIENT_AUTH = oid(1, 3, 6, 1, 5, 5, 7, 3, 2)         // id-kp-clientAuth

    fun build(cn: String, keyPair: KeyPair, serial: Int, notBefore: Date, notAfter: Date): ByteArray =
        buildComplete(cn, keyPair, serial, notBefore, notAfter).der

    /** The certificate bytes plus its TBSCertificate, for pinned vectors. */
    class Built(val der: ByteArray, val tbs: ByteArray)

    fun buildComplete(cn: String, keyPair: KeyPair, serial: Int, notBefore: Date, notAfter: Date): Built {
        require(cn.isNotBlank()) { "cn must not be blank" }
        require(serial > 0) { "serial must be positive" }
        val pub = keyPair.public as ECPublicKey
        val point = KeyPin.encodePoint(pub.w)
        val ekuValue = OID_SERVER_AUTH + OID_CLIENT_AUTH
        val sanValue = sanIpValue()
        val ekuSeq = derSeq(ekuValue)
        val bcValue = emptyBytes()
        val extensions = derSeq(
            derExt(OID_SUBJECT_ALT_NAME, false, sanValue),
            derExt(OID_EXT_KEY_USAGE, false, ekuSeq),
            // end-entity BC: DEFAULT FALSE is omitted in canonical DER
            derExt(OID_BASIC_CONSTRAINTS, true, bcValue),
        )
        val signatureAlgo = derSeq(OID_ECDSA_WITH_SHA256 + nullBytes())
        val tbs = derSeq(
            derContext(0xA0, integer(BigInteger.valueOf(2))) +
                integer(BigInteger.valueOf(serial.toLong())) +
                signatureAlgo +
                name(cn) +
                derSeq(time(notBefore) + time(notAfter)) +
                name(cn) +
                derSeq(derSeq(OID_EC_PUBLIC_KEY + OID_PRIME256V1) + bitString(point)) +
                derContext(0xA3, extensions),
        )
        val signature = sign(keyPair.private, tbs)
        return Built(derSeq(tbs + signatureAlgo + bitString(signature)), tbs)
    }

    // ---------- structure ----------

    private fun derExt(oidBytes: ByteArray, critical: Boolean, value: ByteArray): ByteArray {
        // DER omits the BOOLEAN when it equals the DEFAULT (false) — canonical.
        val prefix = if (critical) booleanBytes(0xFF) else byteArrayOf()
        return derSeq(oidBytes + prefix + octetString(value))
    }

    /** subjectAltName value: SEQUENCE { [7] IMPLICIT 4-octet IP } */
    private fun sanIpValue(): ByteArray = derSeq(byteArrayOf(0x87.toByte(), 4, 127, 0, 0, 1))

    /** Name ::= RDNSequence: SEQUENCE { SET { SEQUENCE { OID commonName, UTF8String } } } */
    private fun name(cn: String): ByteArray = derSeq(tlv(TAG_SET, derSeq(OID_CN + utf8(cn))))

    // ---------- ECDSA ----------

    private fun sign(privateKey: java.security.PrivateKey, data: ByteArray): ByteArray {
        val sig = Signature.getInstance("SHA256withECDSA")
        sig.initSign(privateKey)
        sig.update(data)
        val out = sig.sign()
        // X.509 wants SEQUENCE { INTEGER r, INTEGER s }; every provider we use
        // (SunEC on the JVM, Conscrypt on-device) emits that shape already. If a
        // future provider switches to bare P1363 (r||s) the failure is loud
        // rather than a silently unreadable cert.
        require(out[0] == TAG_SEQUENCE.toByte()) { "ECDSA signature not DER SEQUENCE" }
        return out
    }

    // ---------- DER primitives ----------

    private fun lengthBytes(len: Int): ByteArray = when {
        len < 0x80 -> byteArrayOf(len.toByte())
        len < 0x100 -> byteArrayOf(0x81.toByte(), len.toByte())
        len < 0x10000 -> byteArrayOf(0x82.toByte(), (len ushr 8).toByte(), (len and 0xFF).toByte())
        else -> byteArrayOf(0x83.toByte(), (len ushr 16).toByte(), ((len ushr 8) and 0xFF).toByte(), (len and 0xFF).toByte())
    }

    private fun tlv(tag: Int, content: ByteArray): ByteArray = byteArrayOf(tag.toByte()) + lengthBytes(content.size) + content

    /** SEQUENCE { parts } — variadic for call-site clarity; DER is the concat. */
    private fun derSeq(vararg parts: ByteArray): ByteArray {
        var content = byteArrayOf()
        for (p in parts) content += p
        return tlv(TAG_SEQUENCE, content)
    }

    private fun emptyBytes(): ByteArray = derSeq(byteArrayOf())

    /** Context-specific constructed wrapper ([0], [3] — matches [RFC 5280] OPTIONAL/default fields). */
    private fun derContext(tag: Int, content: ByteArray): ByteArray = tlv(tag, content)

    private fun integer(value: BigInteger): ByteArray {
        var bytes = value.toByteArray()
        if (bytes.size > 1 && bytes[0] == 0.toByte() && bytes[1].toInt() and 0x80 == 0) {
            bytes = bytes.copyOfRange(1, bytes.size) // drop redundant sign byte
        }
        return tlv(TAG_INTEGER, bytes)
    }

    private fun bitString(content: ByteArray): ByteArray = tlv(TAG_BIT_STRING, byteArrayOf(0) + content)

    private fun octetString(content: ByteArray): ByteArray = tlv(TAG_OCTET_STRING, content)

    private fun utf8(value: String): ByteArray = tlv(TAG_UTF8_STRING, value.toByteArray(Charsets.UTF_8))

    private fun booleanBytes(flag: Int): ByteArray = tlv(TAG_BOOLEAN, byteArrayOf(flag.toByte()))

    private fun nullBytes(): ByteArray = tlv(TAG_NULL, byteArrayOf())

    /**
     * RFC 5280 §4.1.2.5: UTCTime for 1950..2049, GeneralizedTime from 2050 on.
     * The phone identity's "no expiration" date (9999) needs the latter; a cert
     * with a 366-day validity (review L-5) uses the former.
     */
    internal fun time(date: Date): ByteArray {
        val cal = utcCalendar(date)
        val year = cal.get(java.util.Calendar.YEAR)
        return if (year in 1950..2049) utcTime(cal) else generalizedTime(cal)
    }

    private fun utcCalendar(date: Date): java.util.Calendar =
        java.util.Calendar.getInstance(java.util.TimeZone.getTimeZone("UTC")).apply { time = date }

    private fun utcTime(cal: java.util.Calendar): ByteArray {
        // YYMMDDHHMMSSZ, always UTC (valid 1950..2049 per RFC 5280 §4.1.2.5.1).
        val text = buildString {
            pad2(cal.get(java.util.Calendar.YEAR) % 100)
            pad2(cal.get(java.util.Calendar.MONTH) + 1)
            pad2(cal.get(java.util.Calendar.DAY_OF_MONTH))
            pad2(cal.get(java.util.Calendar.HOUR_OF_DAY))
            pad2(cal.get(java.util.Calendar.MINUTE))
            pad2(cal.get(java.util.Calendar.SECOND))
            append('Z')
        }
        return tlv(TAG_UTC_TIME, text.toByteArray(Charsets.US_ASCII))
    }

    private fun generalizedTime(cal: java.util.Calendar): ByteArray {
        // YYYYMMDDHHMMSSZ, always UTC (RFC 5280 §4.1.2.5.2).
        val text = buildString {
            append(cal.get(java.util.Calendar.YEAR))
            pad2(cal.get(java.util.Calendar.MONTH) + 1)
            pad2(cal.get(java.util.Calendar.DAY_OF_MONTH))
            pad2(cal.get(java.util.Calendar.HOUR_OF_DAY))
            pad2(cal.get(java.util.Calendar.MINUTE))
            pad2(cal.get(java.util.Calendar.SECOND))
            append('Z')
        }
        return tlv(TAG_GENERALIZED_TIME, text.toByteArray(Charsets.US_ASCII))
    }

    private fun StringBuilder.pad2(v: Int) {
        append(('0' + ((v / 10) % 10)))
        append(('0' + (v % 10)))
    }

    private fun oid(vararg arcs: Int): ByteArray {
        val out = ArrayList<Byte>(arcs.size + 2)
        encodeArc(arcs[0] * 40 + arcs[1], out)
        for (i in 2 until arcs.size) encodeArc(arcs[i], out)
        return tlv(TAG_OID, out.toByteArray())
    }

    private fun encodeArc(v: Int, out: ArrayList<Byte>) {
        val stack = ArrayList<Int>(4)
        var value = v
        do {
            stack.add(value and 0x7F)
            value = value ushr 7
        } while (value > 0)
        stack.reverse()
        stack.forEachIndexed { i, b ->
            // all but the last byte carry the continuation bit
            out.add(((if (i == stack.size - 1) 0 else 0x80) or b).toByte())
        }
    }
}
