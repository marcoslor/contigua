package app.contigua.server

/**
 * One display's table from a node's identity to its `k` (docs/PROTOCOL.md
 * "UI tree" item 9, MCP-71).
 *
 * A node seen again in a later read keeps its key; a new node gets the next
 * unused one (1, 2, …); a key is never given to another node for as long as
 * its display lives (see [UiTreeKeyTables]). At most [capacity]
 * identities are remembered: past it, the ones seen longest ago that are not in
 * the latest read are forgotten, so a forgotten node that returns gets a new
 * key, never an old one.
 *
 * Pure: an identity is whatever the reader hands in (on the phone, the
 * accessibility node's window id and source node id). Thread-safe: two
 * sessions may read the same display.
 */
class UiTreeKeys(private val capacity: Int = CAPACITY, first: Int = 1) {

    /** Identity → key, in last-seen order: the head was seen longest ago. */
    private val table = LinkedHashMap<Any, Int>()
    private val byKey = HashMap<Int, Any>()
    private var next = first

    /** The key the next new identity gets: a later table for the display starts here. */
    val nextKey: Int
        @Synchronized get() = next

    /**
     * Keys [identities], one read's rows in order, and returns their keys in
     * the same order. An identity listed twice gets a second, fresh key, so a
     * key is unique within a reply.
     */
    @Synchronized
    fun read(identities: List<Any>): List<Int> {
        val seen = HashSet<Any>(identities.size * 2)
        val out = ArrayList<Int>(identities.size)
        for (raw in identities) {
            val identity = if (seen.add(raw)) raw else Unique()
            val key = table.remove(identity) ?: next++
            table[identity] = key
            byKey[key] = identity
            out.add(key)
        }
        seen.clear()
        val latest = HashSet<Any>(out.size * 2).apply { out.forEach { add(byKey.getValue(it)) } }
        val oldest = table.entries.iterator()
        while (table.size > capacity && oldest.hasNext()) {
            val entry = oldest.next()
            // The latest read sits at the tail; reaching it means it alone is over the cap.
            if (entry.key in latest) break
            byKey.remove(entry.value)
            oldest.remove()
        }
        return out
    }

    /** The identity [key] names while it is remembered, else null. */
    @Synchronized
    fun identity(key: Int): Any? = byKey[key]

    /** A node with no identity of its own, or met twice in one read. */
    private class Unique

    companion object {
        /** Identities remembered per display (CONV-PD-06). */
        const val CAPACITY = 4_096
    }
}

/**
 * The phone's key tables, one per display (MCP-71). A read drops the tables of
 * displays it no longer finds listed, to free their memory; a display's next
 * key outlives its table, because `windowsOnAllDisplays` leaves out a display
 * that is between two windows, and a table started again at 1 would give an
 * old key to another node. A dropped table's nodes get new keys, as evicted
 * ones do.
 */
class UiTreeKeyTables {
    private val tables = HashMap<Int, UiTreeKeys>()

    /** Each dropped display's next key; display ids are not reused while the phone runs. */
    private val resume = HashMap<Int, Int>()

    /** [display]'s table; first drops every table whose display [listed] says is gone. */
    @Synchronized
    fun table(display: Int, listed: (Int) -> Boolean): UiTreeKeys {
        val gone = tables.keys.filterNot(listed)
        for (id in gone) resume[id] = tables.remove(id)!!.nextKey
        return tables.getOrPut(display) { UiTreeKeys(first = resume.remove(display) ?: 1) }
    }
}
