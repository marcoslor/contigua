package app.contigua.server

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * MCP-71 (the phone's half): a row's `k` stays the same in every read of its
 * display for as long as its node exists, and is never given to another node
 * (docs/PROTOCOL.md "UI tree" item 9).
 */
class UiTreeKeysTest {

    @Test
    fun testANodeKeepsItsKeyAcrossReads() { // [MCP-71]
        val keys = UiTreeKeys()
        assertEquals(listOf(1, 2), keys.read(listOf("A", "B")))
        assertEquals(listOf(2, 3), keys.read(listOf("B", "C")))
        assertEquals("C", keys.identity(3))
    }

    @Test
    fun testAKeyIsNeverReused() { // [MCP-71]
        val keys = UiTreeKeys()
        keys.read(listOf("A", "B"))
        keys.read(listOf("B"))
        // A is gone from read 2 and back in read 3: still remembered, still 1.
        assertEquals(listOf(1), keys.read(listOf("A")))
        // 4096 newer identities push A out of the table.
        keys.read((1..UiTreeKeys.CAPACITY).map { "n$it" })
        assertNull(keys.identity(1))
        val again = keys.read(listOf("A")).single()
        assertNotEquals(1, again)
        // Every key the table ever issued is distinct: 1 went to A only.
        assertEquals(UiTreeKeys.CAPACITY + 3, again)
    }

    @Test
    fun testTheLatestReadIsNeverEvicted() { // [MCP-71]
        val keys = UiTreeKeys(capacity = 3)
        keys.read(listOf("A", "B", "C"))
        assertEquals(listOf(4, 5, 6), keys.read(listOf("D", "E", "F")))
        // The table holds the latest read whole even at the cap.
        assertEquals(listOf(4, 5, 6), keys.read(listOf("D", "E", "F")))
        assertNull(keys.identity(1))
    }

    @Test
    fun testOneIdentityTwiceInAReadGetsTwoKeys() { // [MCP-71]
        // `k` is unique within a reply, even for a node the walk met twice.
        val keys = UiTreeKeys()
        val out = keys.read(listOf("A", "A"))
        assertEquals(1, out[0])
        assertNotEquals(out[0], out[1])
    }

    @Test
    fun testADisplayUnlistedForAMomentNeverReusesAKey() { // [MCP-71]
        // windowsOnAllDisplays lists only displays with a window, so a display
        // between two activities drops out of a read of another display. Its
        // table may go, but its next key must not start again at 1.
        val tables = UiTreeKeyTables()
        assertEquals(listOf(1, 2), tables.table(1) { it == 1 }.read(listOf("A", "B")))
        tables.table(2) { it == 2 }.read(listOf("X"))
        assertEquals(listOf(3), tables.table(1) { it == 1 }.read(listOf("C")))
        // Each display numbers its own keys.
        assertEquals(listOf(2), tables.table(2) { true }.read(listOf("Y")))
    }
}
