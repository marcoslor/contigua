package app.contigua.app

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * The forwarded-id map behind a Mac banner click (docs/design/notify.md): the
 * oldest entry goes when it is full, a removed notification takes its entry
 * with it, and an id the phone never issued finds nothing.
 */
class BoundedIdMapTest {

    @Test
    fun `put and get round-trip`() {
        val map = BoundedIdMap<String>(3)
        map.put("a", "A")
        assertEquals("A", map.get("a"))
        assertEquals(1, map.size())
    }

    @Test
    fun `remove drops only that id`() {
        val map = BoundedIdMap<String>(3)
        map.put("a", "A")
        map.put("b", "B")
        assertEquals("A", map.remove("a"))
        assertNull(map.get("a"))
        assertEquals("B", map.get("b"))
    }

    @Test
    fun `the oldest entry is evicted at the bound`() {
        val map = BoundedIdMap<String>(2)
        map.put("a", "A")
        map.put("b", "B")
        map.put("c", "C")
        assertEquals(2, map.size())
        assertNull(map.get("a"))
        assertEquals("B", map.get("b"))
        assertEquals("C", map.get("c"))
    }

    @Test
    fun `re-putting an id refreshes it`() {
        val map = BoundedIdMap<String>(2)
        map.put("a", "A")
        map.put("b", "B")
        map.put("a", "A2")
        map.put("c", "C")
        assertEquals("A2", map.get("a"))
        assertNull(map.get("b"))
    }

    @Test
    fun `unknown id and empty id are no-ops`() {
        val map = BoundedIdMap<String>(2)
        assertNull(map.get("nope"))
        map.put("", "ignored")
        assertEquals(0, map.size())
    }

    @Test
    fun `clear empties the map`() {
        val map = BoundedIdMap<String>(2)
        map.put("a", "A")
        map.clear()
        assertEquals(0, map.size())
        assertNull(map.get("a"))
    }
}
