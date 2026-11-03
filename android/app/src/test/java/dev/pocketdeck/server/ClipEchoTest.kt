package dev.pocketdeck.server

import android.net.Uri
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/**
 * The echo rule (SHARE-2/16): the app writes its own clip, and the shell's
 * image poll must never sync that write back to the Mac.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class ClipEchoTest {

    @Test
    fun ourOwnProviderUriIsNeverSyncedBack() {
        assertTrue(isOurClip(Uri.parse("content://dev.pocketdeck.fileprovider/clip/clip-1.png")))
        assertFalse(isOurClip(Uri.parse("content://media/external/images/media/1")))
        assertFalse(isOurClip(null))
    }
}
