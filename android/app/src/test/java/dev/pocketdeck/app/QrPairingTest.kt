package dev.pocketdeck.app

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class QrPairingTest {

    private val key = "0123456789abcdef".repeat(4)

    @Test
    fun `valid pairing uri parses client, url-encoded name and key`() {
        val result = QrPairing.parse("pocketdeck://pair?c=1a2b3c4d&n=Marcos%27s%20MacBook&k=$key")
        assertEquals(QrPairing.Result.Pairing("1a2b3c4d", "Marcos's MacBook", key), result)
    }

    @Test
    fun `plus decodes to space in the name`() {
        val result = QrPairing.parse("pocketdeck://pair?c=1a2b&n=Marcos+MacBook&k=$key")
        assertEquals(QrPairing.Result.Pairing("1a2b", "Marcos MacBook", key), result)
    }

    @Test
    fun `uppercase hex key is normalised`() {
        val upper = "0123456789ABCDEF".repeat(4)
        val result = QrPairing.parse("pocketdeck://pair?c=1a2b&n=Mac&k=$upper")
        assertEquals(QrPairing.Result.Pairing("1a2b", "Mac", key), result)
    }

    @Test
    fun `missing name falls back to Mac`() {
        val result = QrPairing.parse("pocketdeck://pair?c=1a2b&k=$key")
        assertEquals(QrPairing.Result.Pairing("1a2b", "Mac", key), result)
    }

    @Test
    fun `missing client id is malformed`() {
        assertEquals(QrPairing.Result.Malformed, QrPairing.parse("pocketdeck://pair?n=Mac&k=$key"))
    }

    @Test
    fun `missing key is malformed`() {
        assertEquals(QrPairing.Result.Malformed, QrPairing.parse("pocketdeck://pair?c=1a2b&n=Mac"))
    }

    @Test
    fun `empty key is malformed`() {
        assertEquals(QrPairing.Result.Malformed, QrPairing.parse("pocketdeck://pair?c=1a2b&k="))
    }

    @Test
    fun `short key is rejected`() {
        assertEquals(QrPairing.Result.BadKey, QrPairing.parse("pocketdeck://pair?c=1a2b&k=" + "ab".repeat(16)))
    }

    @Test
    fun `over-long key is rejected`() {
        assertEquals(QrPairing.Result.BadKey, QrPairing.parse("pocketdeck://pair?c=1a2b&k=${key}ff"))
    }

    @Test
    fun `non-hex key is rejected`() {
        assertEquals(QrPairing.Result.BadKey, QrPairing.parse("pocketdeck://pair?c=1a2b&k=" + "zz".repeat(32)))
    }

    @Test
    fun `other uris are not pairing codes`() {
        assertEquals(QrPairing.Result.NotPairing, QrPairing.parse("https://example.com/pair?c=1a2b&k=$key"))
        assertEquals(QrPairing.Result.NotPairing, QrPairing.parse("pocketdeck://settings?c=1a2b&k=$key"))
        assertEquals(QrPairing.Result.NotPairing, QrPairing.parse("not a uri at all"))
    }

    @Test
    fun `mac payload with encoded ampersand name parses`() {
        // Exact shape PairingQRPayload produces on the Mac (QRPairing.swift).
        val uri = "pocketdeck://pair?c=5f0c1d2e-0000-4000-8000-abcdefabcdef" +
            "&n=Mac%20%26%20Co%20%2B%201%20%3D%202&k=$key"
        assertEquals(
            QrPairing.Result.Pairing("5f0c1d2e-0000-4000-8000-abcdefabcdef", "Mac & Co + 1 = 2", key),
            QrPairing.parse(uri),
        )
    }

    @Test
    fun `any hex length difference invalidates the key`() {
        val tooShort = QrPairing.parse("pocketdeck://pair?c=1a2b&k=" + key.dropLast(1))
        assertTrue(tooShort is QrPairing.Result.BadKey)
    }
}
