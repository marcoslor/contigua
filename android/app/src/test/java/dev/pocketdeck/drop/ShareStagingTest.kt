package dev.pocketdeck.drop

import android.os.ParcelFileDescriptor
import dev.pocketdeck.server.DropPolicy
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import java.io.File
import java.io.RandomAccessFile
import java.util.concurrent.atomic.AtomicLong

/**
 * The shell side of the fd hand-off (boot 5: the app could stat a shell-written
 * file but not open it). Only a bare name staged for a pending share is
 * opened, for at most 60 s, and the copy is unlinked once the fd exists.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class ShareStagingTest {

    @get:Rule
    val tmp = TemporaryFolder()

    private val now = AtomicLong(1_000)

    private fun staging() = ShareStaging(ttlMs = 60_000, clock = { now.get() })

    private fun staged(name: String, bytes: ByteArray): File =
        File(tmp.root, name).apply { writeBytes(bytes) }

    private fun read(fd: ParcelFileDescriptor): ByteArray =
        ParcelFileDescriptor.AutoCloseInputStream(fd).use { it.readBytes() }

    @Test
    fun aStagedFileOpensAndItsBytesComeThroughTheFd() {
        val source = staged("report.pdf", byteArrayOf(1, 2, 3))
        val staging = staging()
        staging.expect("report.pdf", source)

        val bytes = staging.open("report.pdf")?.let { read(it) }

        assertTrue(bytes!!.contentEquals(byteArrayOf(1, 2, 3)))
        assertFalse("the shell copy is unlinked once the reader has the fd", source.exists())
    }

    @Test
    fun anUnknownNameIsRefused() {
        assertNull(staging().open("report.pdf"))
    }

    @Test
    fun aPathOrDotDotOrHiddenNameIsRefused() {
        val staging = staging()
        for (name in listOf("../report.pdf", "a/report.pdf", ".report.pdf", "a\\report.pdf")) {
            assertNull(name, staging.open(name))
        }
    }

    @Test
    fun anExpiredNameIsRefusedAndSwept() {
        val source = staged("report.pdf", byteArrayOf(1))
        val staging = staging()
        staging.expect("report.pdf", source)
        now.addAndGet(60_001)

        assertNull(staging.open("report.pdf"))
        staging.sweep()
        assertFalse(source.exists())
    }

    @Test
    fun aFileOverTheCapIsRefused() {
        val source = File(tmp.root, "big.bin")
        RandomAccessFile(source, "rw").use { it.setLength(DropPolicy.MAX_FILE_BYTES + 1) }
        val staging = staging()
        staging.expect("big.bin", source)

        assertNull(staging.open("big.bin"))
        assertFalse(source.exists())
    }
}
