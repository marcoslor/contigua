package app.contigua.drop

import android.os.ParcelFileDescriptor
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import java.io.File

/**
 * The trampoline reads only through `openStaged` (boot 5: opening a
 * shell-written path failed inside the app). A null descriptor refuses the
 * whole batch, never a half copy.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class ShareCopiesTest {

    @get:Rule
    val tmp = TemporaryFolder()

    private val cache: File by lazy { tmp.newFolder("cache") }
    private val sources: File by lazy { tmp.newFolder("sources") }

    private fun source(name: String, bytes: ByteArray): File =
        File(sources, name).apply { writeBytes(bytes) }

    private fun opened(file: File): ParcelFileDescriptor =
        ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY)

    private fun target(name: String) = ShareRequest.parse(name, "image/png")!!

    @Test
    fun everyFileIsCopiedThroughOpenStaged() {
        val a = source("a.png", byteArrayOf(1, 2, 3))
        val b = source("b.png", byteArrayOf(4, 5))
        val names = mutableListOf<String>()

        val copies = ShareCopies.copy(
            { name -> names += name; opened(if (name == "a.png") a else b) },
            listOf(target("a.png"), target("b.png")),
            cache,
        )

        assertEquals(listOf("a.png", "b.png"), names)
        assertTrue(copies!![0].readBytes().contentEquals(byteArrayOf(1, 2, 3)))
        assertTrue(copies[1].readBytes().contentEquals(byteArrayOf(4, 5)))
    }

    @Test
    fun aNullDescriptorRefusesTheWholeBatch() {
        val a = source("a.png", byteArrayOf(1))
        var calls = 0

        val copies = ShareCopies.copy(
            { name -> calls += 1; if (name == "a.png") opened(a) else null },
            listOf(target("a.png"), target("b.png")),
            cache,
        )

        assertNull(copies)
        assertEquals("every name is asked for, then the batch is refused", 2, calls)
    }
}
