package dev.pocketdeck.app

import android.content.ClipboardManager
import android.content.Context
import androidx.test.core.app.ApplicationProvider
import dev.pocketdeck.server.ClipImagePolicy
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import java.io.ByteArrayInputStream
import java.io.File

/**
 * The app-owned clipboard item (boot 5: a shell-set URI clip fails the
 * ClipboardService owner check; the app's own does not). One URI-only item,
 * the image's MIME, our provider, and only the newest file kept.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class ClipImageWriterTest {

    private val context: Context = ApplicationProvider.getApplicationContext()
    private val clipboard: ClipboardManager
        get() = context.getSystemService(ClipboardManager::class.java)
    private val dir: File get() = File(context.cacheDir, "clip")

    @Before
    fun clear() {
        dir.deleteRecursively()
        clipboard.clearPrimaryClip()
    }

    private fun write(mime: String = "image/png", bytes: ByteArray = byteArrayOf(1, 2, 3)): Boolean =
        ClipImageWriter.write(context, mime, ByteArrayInputStream(bytes))

    @Test
    fun oneUriOnlyItemWithTheMimeAndOurAuthority() {
        assertTrue(write())

        val clip = clipboard.primaryClip!!
        assertEquals(1, clip.itemCount)
        assertNull("a plain field must paste nothing", clip.getItemAt(0).text)
        assertEquals("dev.pocketdeck.fileprovider", clip.getItemAt(0).uri!!.authority)
        assertEquals("image/png", clip.description.getMimeType(0))
    }

    @Test
    fun onlyTheNewestClipFileIsKept() {
        assertTrue(write(bytes = byteArrayOf(1)))
        val first = clipboard.primaryClip!!.getItemAt(0).uri!!
        assertTrue(write(bytes = byteArrayOf(2)))
        val second = clipboard.primaryClip!!.getItemAt(0).uri!!

        assertNotEquals(first, second)
        val files = dir.listFiles().orEmpty().filter { it.isFile }
        assertEquals(1, files.size)
        assertEquals(files.single().name, second.lastPathSegment)
        assertFalse(File(dir, first.lastPathSegment!!).exists())
    }

    @Test
    fun anOverCapImageOrBadMimeWritesNothing() {
        assertFalse(write(bytes = ByteArray(ClipImagePolicy.MAX_BYTES + 1)))
        assertFalse(write(mime = "text/plain", bytes = byteArrayOf(1)))

        assertNull(clipboard.primaryClip)
        assertTrue(dir.listFiles().orEmpty().isEmpty())
    }
}
