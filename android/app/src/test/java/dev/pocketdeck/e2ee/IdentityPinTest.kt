package dev.pocketdeck.e2ee

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Test
import java.security.KeyPair
import java.security.KeyPairGenerator
import java.security.spec.ECGenParameterSpec
import java.util.Base64
import java.util.Date

/**
 * The identity fingerprint the shell service compares on every push
 * (docs/design/e2ee.md §10, PAIR-19): a declared fingerprint is trusted only
 * when it matches the certificate it arrived with.
 */
class IdentityPinTest {

    private fun pemOf(kp: KeyPair): String {
        val der = DerCert.build(
            "PocketDeck Phone",
            kp,
            serial = 7,
            notBefore = Date(System.currentTimeMillis() - 86_400_000L),
            notAfter = Date(System.currentTimeMillis() + 86_400_000L),
        )
        val body = Base64.getEncoder().encodeToString(der).chunked(64).joinToString("\n")
        return "-----BEGIN CERTIFICATE-----\n$body\n-----END CERTIFICATE-----"
    }

    private fun pair(): KeyPair = KeyPairGenerator.getInstance("EC").apply {
        initialize(ECGenParameterSpec("secp256r1"))
    }.generateKeyPair()

    @Test
    fun `the fingerprint is the point pin in hex`() {
        val kp = pair()
        val expected = KeyPin.toHex(KeyPin.fingerprint(kp.public as java.security.interfaces.ECPublicKey))

        assertEquals(expected, IdentityPin.of(pemOf(kp)))
        assertEquals(64, IdentityPin.of(pemOf(kp))!!.length)
    }

    @Test
    fun `a matching declared fingerprint is trusted`() {
        val pem = pemOf(pair())
        val fp = IdentityPin.of(pem)!!

        assertEquals(fp, IdentityPin.verified(fp.uppercase(), pem))
    }

    @Test
    fun `a declared fingerprint for another identity is refused`() {
        val pem = pemOf(pair())
        val other = IdentityPin.of(pemOf(pair()))!!

        assertEquals("", IdentityPin.verified(other, pem))
    }

    @Test
    fun `a missing or malformed declared fingerprint is refused`() {
        val pem = pemOf(pair())

        assertEquals("", IdentityPin.verified("", pem))
        assertEquals("", IdentityPin.verified("0".repeat(63), pem))
        assertEquals("", IdentityPin.verified("z".repeat(64), pem))
    }

    @Test
    fun `a fresh identity has a different fingerprint`() {
        assertNotEquals(IdentityPin.of(pemOf(pair())), IdentityPin.of(pemOf(pair())))
    }

    @Test
    fun `bytes that are not a certificate have no fingerprint`() {
        assertNull(IdentityPin.of("not a certificate"))
        assertNull(IdentityPin.of(""))
    }
}
