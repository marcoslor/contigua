package dev.pocketdeck.direct

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * DIRECT-15 (R-PRIV-1): no log line carries the key, its passphrase or the
 * service-specific info. The one line that names the key carries an 8-hex hash
 * prefix and a length.
 */
class DirectLogHygieneTest {

    @Test
    fun theMachinesLogsCarryNoKeyMaterial() {
        val hex = "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"
        val key = DirectKey.parse(hex)!!
        val passphrase = DirectKey.passphrase(key)
        val ssi = Ssi.hex(key, Ssi.window(1_700_000_000))
        val log = mutableListOf<String>()

        val handler = DirectKeyHandler(
            DirectKeys(object : DirectKeyStore {
                private var stored: ByteArray? = null
                override fun get(clientId: String): ByteArray? = stored?.copyOf()
                override fun put(clientId: String, key: ByteArray) {
                    stored = key.copyOf()
                }
                override fun remove(clientId: String) {
                    stored = null
                }
            }),
            {},
            { log.add(it) },
        )
        handler.onWireKey("c1", hex)
        handler.onWireKey("c1", "bad")

        val machine = AwareLink(AwareGates(true, true, true, true), { log.add(it) })
        machine.transition(AwareLinkEvent.SwitchOn)
        machine.transition(AwareLinkEvent.Attached)
        machine.transition(AwareLinkEvent.SessionLive(true))
        machine.transition(AwareLinkEvent.PermissionDenied)

        val text = log.joinToString("\n")
        assertTrue(text, text.isNotEmpty())
        assertFalse("the key bytes are never logged", text.contains(hex))
        assertFalse("the passphrase is never logged", text.contains(passphrase))
        assertFalse("the service-specific info is never logged", text.contains(ssi))
    }
}
