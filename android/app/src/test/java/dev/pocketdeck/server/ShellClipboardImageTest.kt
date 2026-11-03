package dev.pocketdeck.server

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import java.io.File

/**
 * The clipboard image URI is built here, in the shell service process, not by
 * FileProvider's static helper and not from Environment's storage root: both
 * ask system services that refuse a caller which is not the app's own uid
 * ("package does not match caller's uid", emulator boot 3; files.md §4). The
 * drop folder is the one the receiver writes, /sdcard/Download/PocketDeck, and
 * the URI must be exactly the one `<external-path name="downloads"
 * path="Download/PocketDeck"/>` maps in the app process, so the app's provider
 * still serves it.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class ShellClipboardImageTest {

    private val drop = File(DropPolicy.DIRECTORY)

    @Test
    fun aFileInTheDropFolderGetsTheProvidersOwnMapping() {
        val file = File(drop, "Clipboard 1.png")
        assertEquals("content://dev.pocketdeck.fileprovider/downloads/Clipboard%201.png",
                     imageUri(file)?.toString())
    }

    @Test
    fun aFileOutsideTheDropFolderGetsNoUri() {
        assertNull(imageUri(File(drop.parentFile, "elsewhere.png")))
        assertNull(imageUri(File(drop, "sub/x.png")))
        assertNull(imageUri(File(drop, "../elsewhere.png")))
    }
}
