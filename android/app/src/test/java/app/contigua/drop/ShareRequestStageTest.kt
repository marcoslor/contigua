package app.contigua.drop

import android.content.Context
import android.content.ContextWrapper
import androidx.test.core.app.ApplicationProvider
import org.junit.Assert.assertEquals
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import java.io.File

/**
 * The staging folder must be computed from the app's package and the real
 * storage root, not asked of the Context or of Environment: in the uid-2000
 * shell process `getExternalMediaDirs()` and
 * `Environment.getExternalStorageDirectory()` both reach system services that
 * refuse the app package under that uid (emulator boot 3; files.md §4), which
 * killed the whole SEND step before it could log. `/storage/emulated/0` is the
 * real path of `/sdcard`, the same root DeckService gives the file browser.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class ShareRequestStageTest {

    private class RefusingContext(base: Context) : ContextWrapper(base) {
        override fun getExternalMediaDirs(): Array<File> =
            throw SecurityException("package does not match caller's uid")
    }

    @Test
    fun theStageDirIsTheAppsExternalMediaFolderWithoutAskingForMediaDirs() {
        val app = ApplicationProvider.getApplicationContext<Context>()
        val expected = File("/storage/emulated/0",
                            "Android/media/${app.packageName}/shared")
        assertEquals(expected, ShareRequest.stageDir(RefusingContext(app)))
    }
}
