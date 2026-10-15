package dev.pocketdeck.app

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class QrPairingTest {

    private val fp = "20ac3461fdd5af5cc0b6c0c7ca6cf2df8edb8eb1322096c3fc9e06297e97dc41"
    private val secret = "0123456789abcdef0123456789abcdef"

    @Test
    fun `valid pairing uri parses client, name, mac fingerprint and secret`() {
        val result = QrPairing.parse("pocketdeck://pair?c=1a2b3c4d&n=Marcos%27s%20MacBook&f=$fp&s=$secret")
        assertEquals(
            QrPairing.Result.Pairing("1a2b3c4d", "Marcos's MacBook", fp, secret),
            result,
        )
    }

    @Test
    fun `plus decodes to space in the name`() {
        val result = QrPairing.parse("pocketdeck://pair?c=1a2b&n=Marcos+MacBook&f=$fp&s=$secret")
        assertEquals(QrPairing.Result.Pairing("1a2b", "Marcos MacBook", fp, secret), result)
    }

    @Test
    fun `uppercase hex is normalised`() {
        val upper = "0123456789ABCDEF".repeat(2)
        val upperFp = "20AC3461FDD5AF5CC0B6C0C7CA6CF2DF8EDB8EB1322096C3FC9E06297E97DC41"
        val result = QrPairing.parse("pocketdeck://pair?c=1a2b&n=Mac&f=$upperFp&s=$upper")
        assertEquals(QrPairing.Result.Pairing("1a2b", "Mac", fp, secret), result)
    }

    @Test
    fun `missing name falls back to Mac`() {
        val result = QrPairing.parse("pocketdeck://pair?c=1a2b&f=$fp&s=$secret")
        assertEquals(QrPairing.Result.Pairing("1a2b", "Mac", fp, secret), result)
    }

    @Test
    fun `missing client id is malformed`() {
        assertEquals(QrPairing.Result.Malformed, QrPairing.parse("pocketdeck://pair?n=Mac&f=$fp&s=$secret"))
    }

    @Test
    fun `missing fingerprint is malformed`() {
        assertEquals(QrPairing.Result.Malformed, QrPairing.parse("pocketdeck://pair?c=1a2b&n=Mac&s=$secret"))
    }

    @Test
    fun `missing secret is malformed`() {
        assertEquals(QrPairing.Result.Malformed, QrPairing.parse("pocketdeck://pair?c=1a2b&n=Mac&f=$fp"))
    }

    @Test
    fun `v1-shaped keys are no longer accepted`() {
        // The v1 QR carried `k`; v2 refuses it (no v1 path left, fixed decision).
        val key = "0123456789abcdef".repeat(4)
        assertEquals(QrPairing.Result.Malformed, QrPairing.parse("pocketdeck://pair?c=1a2b&n=Mac&k=$key"))
    }

    @Test
    fun `short fingerprint is rejected`() {
        assertEquals(QrPairing.Result.BadKey, QrPairing.parse("pocketdeck://pair?c=1a2b&f=" + "ab".repeat(15) + "&s=$secret"))
    }

    @Test
    fun `short secret is rejected`() {
        assertEquals(QrPairing.Result.BadKey, QrPairing.parse("pocketdeck://pair?c=1a2b&f=$fp&s=" + "cd".repeat(8)))
    }

    @Test
    fun `non-hex secret is rejected`() {
        assertEquals(QrPairing.Result.BadKey, QrPairing.parse("pocketdeck://pair?c=1a2b&f=$fp&s=" + "zz".repeat(16)))
    }

    @Test
    fun `other uris are not pairing codes`() {
        assertEquals(QrPairing.Result.NotPairing, QrPairing.parse("https://example.com/pair?c=1a2b&f=$fp&s=$secret"))
        assertEquals(QrPairing.Result.NotPairing, QrPairing.parse("pocketdeck://settings?c=1a2b&f=$fp&s=$secret"))
        assertEquals(QrPairing.Result.NotPairing, QrPairing.parse("not a uri at all"))
    }

    @Test
    fun `mac payload with encoded ampersand name parses`() {
        // Exact shape PairingQRPayload produces on the Mac (QRPairing.swift).
        val uri = "pocketdeck://pair?c=5f0c1d2e-0000-4000-8000-abcdefabcdef" +
            "&n=Mac%20%26%20Co%20%2B%201%20%3D%202&f=$fp&s=$secret"
        assertEquals(
            QrPairing.Result.Pairing("5f0c1d2e-0000-4000-8000-abcdefabcdef", "Mac & Co + 1 = 2", fp, secret),
            QrPairing.parse(uri),
        )
    }

    @Test
    fun `any fingerprint length difference invalidates the payload`() {
        val tooShort = QrPairing.parse("pocketdeck://pair?c=1a2b&f=" + fp.dropLast(1) + "&s=$secret")
        assertTrue(tooShort is QrPairing.Result.BadKey)
    }
}
