package dev.pocketdeck.server

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The `drop.start` fields SHARE-17 adds (docs/PROTOCOL.md "Drop Mac → phone"):
 * the package of the window the drop landed on, and the batch position.
 */
class DropPolicyTest {

    private fun start(extra: Map<String, Any?> = emptyMap()): Map<String, Any?> = mapOf(
        "t" to "drop.start", "id" to 7L, "name" to "report.pdf", "mime" to "application/pdf",
        "size" to 1024L, "sha256" to "a".repeat(64),
    ) + extra

    private fun refusal(extra: Map<String, Any?>): DropPolicy.Rejected? =
        runCatching { DropPolicy.parse(start(extra)) }.exceptionOrNull() as? DropPolicy.Rejected

    @Test
    fun aTargetIsAPackageName() {
        assertEquals("com.example.app",
            DropPolicy.parse(start(mapOf("target" to "com.example.app"))).desk.target)
        assertEquals("com.example.app_2",
            DropPolicy.parse(start(mapOf("target" to "com.example.app_2"))).desk.target)
        assertNull("a drop without a target keeps today's chooser",
            DropPolicy.parse(start()).desk.target)
    }

    @Test
    fun junkTargetsAreRefused() {
        for (bad in listOf(
            "", " ", "com.example app", "com..app", ".com.app", "com.app.",
            "-com.app", "com.app/evil", "com.app;id", "com.example\n.app", "cøm.example",
        )) {
            val refused = refusal(mapOf("target" to bad))
            assertTrue("accepted '$bad'", refused != null)
            assertEquals("bad_request", refused!!.code)
        }
    }

    @Test
    fun theTargetIsAtMost255Bytes() {
        val longest = "a." + "b".repeat(253)
        assertEquals(255, longest.length)
        assertEquals(longest, DropPolicy.parse(start(mapOf("target" to longest))).desk.target)
        val tooLong = "a." + "b".repeat(254)
        assertEquals("bad_request", refusal(mapOf("target" to tooLong))?.code)
    }

    @Test
    fun batchFieldsDefaultToOne() {
        val transfer = DropPolicy.parse(start())
        assertEquals(1, transfer.desk.index)
        assertEquals(1, transfer.desk.count)
    }

    @Test
    fun batchFieldsMustBeInsideTheBatch() {
        val transfer = DropPolicy.parse(start(mapOf("index" to 2, "count" to 3)))
        assertEquals(2, transfer.desk.index)
        assertEquals(3, transfer.desk.count)
        for ((index, count) in listOf(0 to 3, 4 to 3, 1 to 0, 2 to 1, 1 to -1,
                                      1 to DropPolicy.MAX_BATCH_FILES + 1)) {
            assertEquals("index $index of $count", "bad_request",
                refusal(mapOf("index" to index, "count" to count))?.code)
        }
    }
}
