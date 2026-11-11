package app.contigua.app

/**
 * The notifications the listener forwarded, mapped to the action the phone's
 * own notification carries (`contentIntent`). Bounded: the oldest entry is
 * dropped when the map is full, and an entry goes away with its notification.
 * Pure Kotlin so the eviction rules are JVM-tested; [NotifyIntents] wraps it
 * with the Android type.
 */
class BoundedIdMap<V>(private val max: Int = 200) {

    init {
        require(max > 0) { "max must be positive" }
    }

    private val entries = LinkedHashMap<String, V>()

    @Synchronized
    fun put(id: String, value: V) {
        if (id.isEmpty()) return
        // Re-putting an id refreshes it: the newest copy is the current one.
        entries.remove(id)
        entries[id] = value
        while (entries.size > max) {
            val oldest = entries.keys.firstOrNull() ?: break
            entries.remove(oldest)
        }
    }

    @Synchronized
    fun get(id: String): V? = entries[id]

    @Synchronized
    fun remove(id: String): V? = entries.remove(id)

    @Synchronized
    fun clear() = entries.clear()

    @Synchronized
    fun size(): Int = entries.size
}
