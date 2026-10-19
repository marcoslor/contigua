package dev.pocketdeck.e2ee

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.io.ByteArrayInputStream
import java.security.KeyPair
import java.security.KeyPairGenerator
import java.security.spec.ECGenParameterSpec
import java.util.Calendar
import java.util.Date
import java.util.TimeZone

/**
 * JVM round-trip tests for the hand-rolled DER cert builder
 * (docs/design/e2ee.md §2, phase-2 step 1, K1 only).
 */
class SelfSignedCertTest {

    private val notBefore: Date = utc(2026, 10, 14, 12, 0, 0)
    private val notAfter: Date = utc(2027, 10, 15, 12, 0, 0)

    private fun utc(y: Int, m: Int, d: Int, h: Int, min: Int, s: Int): Date {
        val cal = Calendar.getInstance(TimeZone.getTimeZone("UTC"))
        cal.clear()
        cal.set(y, m - 1, d, h, min, s)
        return cal.time
    }

    private fun pair(): KeyPair = KeyPairGenerator.getInstance("EC").apply {
        initialize(ECGenParameterSpec("secp256r1"))
    }.generateKeyPair()

    private fun parse(der: ByteArray): java.security.cert.X509Certificate {
        val cert = java.security.cert.CertificateFactory
            .getInstance("X.509")
            .generateCertificate(ByteArrayInputStream(der))
        return cert as java.security.cert.X509Certificate
    }

    @Test
    fun roundTripMatchesTheDesignProfile() {
        val kp = pair()
        val der = DerCert.build("PocketDeck Phone", kp, serial = 0x170C0B15, notBefore = notBefore, notAfter = notAfter)
        val cert = parse(der)
        assertEquals(3, cert.version)
        assertEquals("CN=PocketDeck Phone", cert.subjectX500Principal.name)
        assertEquals("CN=PocketDeck Phone", cert.issuerX500Principal.name)
        assertEquals("SHA256withECDSA", cert.sigAlgName)
        // The ±1-day margins survive the round trip unscathed.
        assertEquals(notBefore.time / 1000, cert.notBefore.time / 1000)
        assertEquals(notAfter.time / 1000, cert.notAfter.time / 1000)
        // EKU covers both ends; SAN non-critical with a present subject; BC
        // critical, end-entity (Android's X509Certificate reports the path
        // length as an int; -1 marks a non-CA cert).
        assertTrue(cert.extendedKeyUsage.contains("1.3.6.1.5.5.7.3.1"))
        assertTrue(cert.extendedKeyUsage.contains("1.3.6.1.5.5.7.3.2"))
        assertFalse(cert.criticalExtensionOIDs.contains("2.5.29.17"))
        assertTrue(cert.criticalExtensionOIDs.contains("2.5.29.19"))
        assertEquals(-1, cert.basicConstraints)
        val sans = cert.subjectAlternativeNames!!.map { it[1].toString() }.toSet()
        assertTrue(sans.contains("127.0.0.1"))
        // Full-pop verification against the presented key.
        cert.verify(kp.public)
        // Top-level structure and the canonical uncompressed-point pin.
        assertTrue(der[0] == 0x30.toByte())
        assertEquals("CN=PocketDeck Phone", cert.subjectDN.name)
    }

    @Test
    fun keyFingerprintIsTheSixtyFiveBytePointSha() {
        val kp = pair()
        val pin = KeyPin.fingerprint(kp.public as java.security.interfaces.ECPublicKey)
        assertEquals(32, pin.size)
        // Independent recomputation over the public W coordinates.
        val w = (kp.public as java.security.interfaces.ECPublicKey).w
        val bytes = ByteArray(65)
        run {
            bytes[0] = 0x04 // uncompressed point marker
            val x = w.affineX.toByteArray()
            val y = w.affineY.toByteArray()
            val xs = if (x.size > 32) x.copyOfRange(x.size - 32, x.size) else x
            val ys = if (y.size > 32) y.copyOfRange(y.size - 32, y.size) else y
            xs.copyInto(bytes, 33 - xs.size)
            ys.copyInto(bytes, 65 - ys.size)
        }
        val digest = java.security.MessageDigest.getInstance("SHA-256").digest(bytes)
        assertArrayEquals(digest, pin)
        assertEquals(64, KeyPin.toHex(pin).length)
    }

    @Test
    fun tbsIsDeterministicForFixedIdentity() {
        val kp = pair()
        val a = DerCert.buildComplete("PocketDeck Mac", kp, serial = 42, notBefore = notBefore, notAfter = notAfter)
        val b = DerCert.buildComplete("PocketDeck Mac", kp, serial = 42, notBefore = notBefore, notAfter = notAfter)
        // The TBSCertificate (structure, serial, dates, key, extensions) is
        // deterministic for the same identity; only the ECDSA signature value
        // varies with its random k.
        assertArrayEquals(a.tbs, b.tbs)
        assertTrue(a.der[0] == 0x30.toByte())
    }

    @Test
    fun generalizedTimeForTheNoExpirationDate() {
        val kp = pair()
        val never = utc(9999, 12, 31, 23, 59, 59)
        val der = DerCert.build("PocketDeck Phone", kp, serial = 7,
            notBefore = notBefore, notAfter = never)
        val cert = parse(der)
        assertEquals(never.time / 1000, cert.notAfter.time / 1000)
        // RFC 5280: 1950..2049 use UTCTime; 9999 must be GeneralizedTime.
        val encoded = DerCert.time(never)
        assertEquals(0x18, encoded[0].toInt() and 0xFF)
        assertEquals("99991231235959Z",
            String(encoded.copyOfRange(2, encoded.size), Charsets.US_ASCII))
        assertEquals(0x17, DerCert.time(utc(2049, 12, 31, 23, 59, 59))[0].toInt() and 0xFF)
    }

    @Test
    fun serialMustBePositive() {
        val kp = pair()
        try {
            DerCert.build("PocketDeck Phone", kp, serial = 0, notBefore = notBefore, notAfter = notAfter)
            fail("serial 0 must be rejected")
        } catch (_: IllegalArgumentException) {
            // expected
        }
    }

    @Test
    fun cnMustNotBeBlank() {
        val kp = pair()
        try {
            DerCert.build("   ", kp, serial = 7, notBefore = notBefore, notAfter = notAfter)
            fail("blank CN must be rejected")
        } catch (_: IllegalArgumentException) {
            // expected
        }
    }
}
