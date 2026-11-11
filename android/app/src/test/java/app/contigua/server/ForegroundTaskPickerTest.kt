package app.contigua.server

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The pure side of "Continue on Mac": which task is the foreground app on the
 * phone's screen, and what must never be moved (docs/ROADMAP.md #9).
 */
class ForegroundTaskPickerTest {

    private fun task(
        id: Int,
        pkg: String,
        displayId: Int = 0,
        isHome: Boolean = false,
        isSystemUi: Boolean = false,
        activity: String? = null,
    ) = SystemTask(taskId = id, pkg = pkg, activity = activity, displayId = displayId,
        isHome = isHome, isSystemUi = isSystemUi)

    private val own = Session.OWN_PACKAGE

    @Test
    fun `picks the newest app task on the screen`() {
        val picked = ForegroundTaskPicker.pick(
            listOf(
                task(7, "com.example.reader"),
                task(3, "com.example.mail"),
            ),
            own,
        )
        assertEquals(7, picked?.taskId)
        assertEquals("com.example.reader", picked?.pkg)
    }

    @Test
    fun `skips the surfaces above and picks the next one`() {
        val picked = ForegroundTaskPicker.pick(
            listOf(
                task(9, "com.android.systemui", isSystemUi = true),
                task(10, own),
                task(11, "com.example.notes"),
            ),
            own,
        )
        assertEquals(11, picked?.taskId)
    }

    @Test
    fun `never moves our own app`() {
        assertFalse(ForegroundTaskPicker.isContinuable(task(1, own), own))
        // The phone-mode launcher lives in our package; one rule covers both.
        assertFalse(ForegroundTaskPicker.isContinuable(task(2, own, activity = "app.contigua.launcher.LauncherActivity"), own))
    }

    @Test
    fun `never moves the launcher home task by its flag`() {
        // A home task is recognized by the flag, whatever the launcher's package is.
        for (pkg in listOf("com.android.launcher3", "com.google.android.apps.nexuslauncher")) {
            assertTrue(ForegroundTaskPicker.isContinuable(task(5, pkg), own))  // a launcher app NOT opened as home
            assertFalse(ForegroundTaskPicker.isContinuable(task(5, pkg, isHome = true), own))
        }
    }

    @Test
    fun `never moves SystemUI or the keyguard`() {
        assertFalse(ForegroundTaskPicker.isContinuable(task(5, "com.android.systemui", isSystemUi = true), own))
    }

    @Test
    fun `never moves a task without a package`() {
        assertFalse(ForegroundTaskPicker.isContinuable(task(6, ""), own))
    }

    @Test
    fun `tasks on our displays are not the screen`() {
        assertEquals(
            4,
            ForegroundTaskPicker.pick(listOf(task(2, "com.example.notes", displayId = 101), task(4, "com.example.maps")), own)?.taskId,
        )
    }

    @Test
    fun `nothing continuable on the screen is null`() {
        assertEquals(null, ForegroundTaskPicker.pick(listOf(task(1, "com.android.systemui", isSystemUi = true)), own))
        assertEquals(null, ForegroundTaskPicker.pick(emptyList(), own))
    }
}
