package app.contigua.server

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * A drop's batch (SHARE-17): files arrive one at a time and the phone shares
 * them once, after the last one lands, and only up to the share cache's five.
 */
class ShareBatchTest {

    private val first = File("/sdcard/Download/Contigua/one.pdf")
    private val second = File("/sdcard/Download/Contigua/two.pdf")
    private val third = File("/sdcard/Download/Contigua/three.pdf")

    private class Calls {
        val shared = mutableListOf<Pair<List<File>, String?>>()
    }

    private fun batch(): Pair<ShareBatch, Calls> {
        val calls = Calls()
        return ShareBatch { files, target -> calls.shared += files.map { it.first } to target } to calls
    }

    @Test
    fun theShareWaitsForTheLastFile() {
        val (batch, calls) = batch()
        batch.landed(first, "application/pdf", "com.example.app", 1, 3)
        batch.landed(second, "application/pdf", "com.example.app", 2, 3)
        assertTrue(calls.shared.isEmpty())
        batch.landed(third, "application/pdf", "com.example.app", 3, 3)
        assertEquals(1, calls.shared.size)
        assertEquals(listOf(first, second, third), calls.shared.single().first)
        assertEquals("com.example.app", calls.shared.single().second)
    }

    @Test
    fun oneFileIsSharedAtOnce() {
        val (batch, calls) = batch()
        batch.landed(first, "image/png", null, 1, 1)
        assertEquals(listOf(first) to null, calls.shared.single())
    }

    @Test
    fun sixFilesAreSavedButNeverShared() {
        val (batch, calls) = batch()
        for (index in 1..6) {
            batch.landed(first, "application/pdf", "com.example.app", index, 6)
        }
        assertTrue("a batch over the share cache's cap is never offered", calls.shared.isEmpty())
    }

    @Test
    fun aNewTargetStartsANewBatch() {
        val (batch, calls) = batch()
        batch.landed(first, "application/pdf", "com.example.app", 1, 2)
        batch.landed(second, "application/pdf", "com.example.other", 2, 2)
        batch.landed(third, "application/pdf", "com.example.other", 1, 1)
        assertEquals(listOf(third) to "com.example.other", calls.shared.single())
    }
}
