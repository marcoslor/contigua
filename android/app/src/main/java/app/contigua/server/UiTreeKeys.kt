package app.contigua.server

/**
 * One display's table from a node's identity to its `k` (docs/PROTOCOL.md
 * "UI tree" item 9, MCP-71).
 *
 * A node seen again in a later read keeps its key; a new node gets the next
 * unused one (1, 2, …); a key is never given to another node for as long as
 * the table lives, which is as long as its display. At most [capacity]
 * identities are remembered: past it, the ones seen longest ago that are not in
 * the latest read are forgotten, so a forgotten node that returns gets a new
 * key, never an old one.
 *
 * Pure: an identity is whatever the reader hands in (on the phone, the
 * accessibility node's window id and source node id). Thread-safe: two
 * sessions may read the same display.
 */
class UiTreeKeys(private val capacity: Int = CAPACITY) {

    /** Identity → key, in last-seen order: the head was seen longest ago. */
    private val table = LinkedHashMap<Any, Int>()
    private val byKey = HashMap<Int, Any>()
    private var next = 1

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
