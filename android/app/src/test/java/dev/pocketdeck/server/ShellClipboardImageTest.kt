package dev.pocketdeck.server

import android.os.Environment
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import java.io.File

/**
 * The clipboard image URI is built here, in the shell service process, not by
 * FileProvider's static helper: that helper asks PackageManager for the app's
 * resources, and a uid-2000 process holding the app's Context is refused
 * ("package does not match caller's uid", measured on the emulator in boot 3).
 * The URI must be exactly the one `<external-path name="downloads"
 * path="Download/PocketDeck"/>` maps, so the app's provider still serves it.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class ShellClipboardImageTest {

    @Test
    fun theUriIsTheProvidersOwnMappingForTheDropFolder() {
        val file = File(Environment.getExternalStorageDirectory(),
                        "Download/PocketDeck/Clipboard 1.png")
        assertEquals("content://dev.pocketdeck.fileprovider/downloads/Clipboard%201.png",
                     imageUri(file)?.toString())
    }

    @Test
    fun aFileOutsideTheDropFolderGetsNoUri() {
        assertNull(imageUri(File(Environment.getExternalStorageDirectory(), "Download/elsewhere.png")))
        assertNull(imageUri(File(Environment.getExternalStorageDirectory(), "Download/PocketDeck/sub/x.png")))
    }
}
