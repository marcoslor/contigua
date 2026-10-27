package dev.pocketdeck.server

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

/**
 * The stream table's ownership rule (B2 round 2): an insert hands back what it
 * displaced. The display layer closes that value outside its lock; a silent
 * overwrite leaked an encoder, a virtual display and its drain thread.
 */
class StreamTableTest {

    @Test
    fun putHandsBackWhatItDisplaced() {
        val table = StreamTable<String>()
        assertNull("a first insert displaces nothing", table.put(1, "first"))
        assertEquals("the map holds the newest stream", "first", table.get(1))
        assertEquals("the displaced stream is handed back", "first", table.put(1, "second"))
        assertEquals("second", table.get(1))
        assertNull("another id is independent", table.put(2, "other"))
        assertEquals("second", table.get(1))
    }

    @Test
    fun takeRemovesAndHandsBack() {
        val table = StreamTable<Int>()
        table.put(7, 70)
        assertEquals(70, table.take(7))
        assertNull(table.get(7))
        assertNull("a second take has nothing to hand back", table.take(7))
    }

    /**
     * The display layer's use of the rule: an insert that displaces a value
     * closes it once, outside the lock, and the table still serves the new one.
     * The displaced close must not run while the table is locked (the real
     * close stops an encoder and joins a thread).
     */
    @Test
    fun aDisplacedValueIsClosedOutsideTheTableLock() {
        class Closeable(val id: String) {
            val closes = AtomicInteger()
            fun close() {
                closes.incrementAndGet()
            }
        }
        val table = StreamTable<Closeable>()
        val first = Closeable("first")
        table.put(3, first)
        val second = Closeable("second")
        val displaced = table.put(3, second)
        // What AndroidDisplayLayer.put does with the result:
        displaced?.close()
        assertEquals(1, first.closes.get())
        assertEquals("the newest is still served", second, table.get(3))
        assertEquals(0, second.closes.get())
    }

    /** Two threads racing an insert for one id: neither value is lost silently. */
    @Test
    fun concurrentInsertsNeverOverwriteSilently() {
        val table = StreamTable<String>()
        val start = CountDownLatch(1)
        val displaced = java.util.Collections.synchronizedList(ArrayList<String>())
        val threads = (1..2).map { i ->
            Thread {
                start.await(5, TimeUnit.SECONDS)
                table.put(1, "stream-$i")?.let { displaced.add(it) }
            }.also { it.isDaemon = true; it.start() }
        }
        start.countDown()
        for (t in threads) t.join(5_000)
        // The winner is in the table and the loser was handed back.
        assertEquals(1, displaced.size)
        assertEquals("the table holds exactly one of them", 1, listOf("stream-1", "stream-2").count { table.get(1) == it })
    }
}
