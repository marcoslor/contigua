package dev.pocketdeck.direct

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The wire key and its storage (docs/design/direct-link.md §5, transport
 * DIRECT-9/15): 32 bytes as 64 hex, stored per Mac, rotated and forgotten. The
 * storage port is the seam: the Keystore cipher lives behind it on the phone.
 */
class DirectKeyTest {

    private val client = "c1"
    private val hexA = "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"
    private val hexB = "1f1e1d1c1b1a191817161514131211100f0e0d0c0b0a09080706050403020100"

    private class FakeStore : DirectKeyStore {
        val keys = mutableMapOf<String, ByteArray>()

        override fun get(clientId: String): ByteArray? = keys[clientId]?.copyOf()

        override fun put(clientId: String, key: ByteArray) {
            keys[clientId] = key.copyOf()
        }

        override fun remove(clientId: String) {
            keys.remove(clientId)
        }
    }

    private class Harness {
        val store = FakeStore()
        val keys = DirectKeys(store)
        val acks = mutableListOf<Boolean>()
        val log = mutableListOf<String>()
        val handler = DirectKeyHandler(keys, { acks.add(it) }, { log.add(it) })
    }

    @Test
    fun aValidKeyIsStoredAndAcknowledged() {
        val h = Harness()
        h.handler.onWireKey(client, hexA)
        assertEquals(listOf(true), h.acks)
        assertArrayEquals(DirectKey.parse(hexA), h.keys.key(client))
        assertEquals(32, h.keys.key(client)!!.size)
    }

    @Test
    fun aMalformedKeyIsRefusedWithoutAnOk() {
        val cases = listOf(
            "",
            "00",
            hexA.dropLast(1),
            hexA + "00",
            "z" + hexA.drop(1),
            hexA.replace("0", "g"),
            "not-a-key",
        )
        for (raw in cases) {
            val h = Harness()
            h.handler.onWireKey(client, raw)
            assertEquals("a malformed key is refused: ${raw.length} chars", listOf(false), h.acks)
            assertNull("nothing is stored for a malformed key", h.keys.key(client))
            assertTrue("the refusal names no key material", h.log.all { "key=" !in it })
        }
    }

    @Test
    fun aRefusedKeyNeverReplacesTheStoredOne() {
        val h = Harness()
        h.handler.onWireKey(client, hexA)
        h.handler.onWireKey(client, "zz")
        assertEquals(listOf(true, false), h.acks)
        assertArrayEquals(DirectKey.parse(hexA), h.keys.key(client))
    }

    @Test
    fun aNewKeyRotatesAndForgetRemovesIt() {
        val h = Harness()
        h.handler.onWireKey(client, hexA)
        h.handler.onWireKey(client, hexB)
        assertArrayEquals(DirectKey.parse(hexB), h.keys.key(client))
        h.keys.forget(client)
        assertNull(h.keys.key(client))
    }

    @Test
    fun thePassphraseIsTheBase64OfTheBytes() {
        assertEquals(
            "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=",
            DirectKey.passphrase(DirectKey.parse(hexA)!!),
        )
        assertEquals(44, DirectKey.passphrase(DirectKey.parse(hexB)!!).length)
    }

    @Test
    fun theLogNamesTheKeyOnlyByItsHashPrefixAndLength() {
        val h = Harness()
        h.handler.onWireKey(client, hexA)
        val line = h.log.single()
        val fingerprint = DirectKey.fingerprint(DirectKey.parse(hexA)!!)
        assertEquals(8, fingerprint.length)
        assertTrue(line, line.contains("key=$fingerprint"))
        assertTrue(line, line.contains("len=32"))
        assertFalse(line, line.contains(hexA))
        assertFalse(line, line.contains(hexA.uppercase()))
        assertFalse(line, line.contains(DirectKey.passphrase(DirectKey.parse(hexA)!!)))
    }

    @Test
    fun parseNeedsExactlySixtyFourHexCharacters() {
        assertEquals(32, DirectKey.parse(hexA)!!.size)
        assertEquals(32, DirectKey.parse(hexA.uppercase())!!.size)
        assertNull(DirectKey.parse(null))
        assertNull(DirectKey.parse(hexA + "a"))
        assertNull(DirectKey.parse(hexA.dropLast(1)))
    }
}
