package dev.pocketdeck.drop

import android.content.Context
import android.content.ContextWrapper
import android.os.Environment
import androidx.test.core.app.ApplicationProvider
import org.junit.Assert.assertEquals
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import java.io.File

/**
 * The staging folder must be computed from the app's package, not asked of the
 * Context: `getExternalMediaDirs()` in the uid-2000 shell process threw
 * SecurityException on the emulator (boot 3), which killed the whole SEND step
 * before it could log. The path itself is the app's external media folder, the
 * one folder Android lets both identities read.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class ShareRequestStageTest {

    private class RefusingMediaDirs(base: Context) : ContextWrapper(base) {
        override fun getExternalMediaDirs(): Array<File> =
            throw SecurityException("package does not match caller's uid")
    }

    @Test
    fun theStageDirIsTheAppsExternalMediaFolderWithoutAskingForMediaDirs() {
        val app = ApplicationProvider.getApplicationContext<Context>()
        val expected = File(Environment.getExternalStorageDirectory(),
                            "Android/media/${app.packageName}/shared")
        assertEquals(expected, ShareRequest.stageDir(RefusingMediaDirs(app)))
    }
}
