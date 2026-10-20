package dev.pocketdeck.server

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The `dumpsys window` shape below is taken from the API 36 emulator rig: the
 * flag names sit on their own `fl=` line, and a SystemUI window is titled
 * without a package. The parser must not depend on the old hex form alone.
 */
class SecureDumpTest {

    private fun dump(display0: String?, window: String): String = """
WINDOW MANAGER DISPLAY CONTENTS (dumpsys window displays)
  Display: mDisplayId=0 (organized)
    mCurrentFocus=${display0 ?: "null"}
  Display: mDisplayId=2
    mCurrentFocus=Window{feed01 u0 com.android.systemui/.Foo}

WINDOW MANAGER WINDOWS (dumpsys window windows)
  Window #0 Window{43ab7e3 u0 ScreenDecorOverlayBottom}:
    mAttrs={(0,0)(fillxwrap) gr=BOTTOM CENTER_VERTICAL}
      fl=NOT_FOCUSABLE NOT_TOUCHABLE NOT_TOUCH_MODAL
      pfl=SHOW_FOR_ALL_USERS
$window
""".trimIndent()

    private val shade = """
  Window #5 Window{f17b197 u0 NotificationShade}:
    mAttrs={(0,0)(fillxfill) gr=TOP CENTER_VERTICAL}
      fl=NOT_FOCUSABLE LAYOUT_IN_SCREEN
    pfl=SHOW_FOR_ALL_USERS
"""

    @Test
    fun `the focus line of a secondary display is not the mirror`() {
        val text = dump("Window{f17b197 u0 NotificationShade}", shade)
        assertEquals(false, SecureDump.focusedSecure(text))
    }

    @Test
    fun `a secure focused window is secure`() {
        val text = dump(
            "Window{f17b197 u0 NotificationShade}",
            shade.replace("fl=NOT_FOCUSABLE LAYOUT_IN_SCREEN", "fl=SECURE LAYOUT_IN_SCREEN"),
        )
        assertEquals(true, SecureDump.focusedSecure(text))
    }

    @Test
    fun `the numeric flag form is still understood`() {
        val text = dump(
            "Window{f17b197 u0 com.android.settings/.Settings}",
            """
  Window #5 Window{f17b197 u0 com.android.settings/.Settings}:
    mAttrs={(-1,-1) gr=TOP fl=0x00002000 fmt=-1}
""",
        )
        assertEquals(true, SecureDump.focusedSecure(text))
    }

    @Test
    fun `no display 0 focus is unreadable, not secure`() {
        assertEquals(null, SecureDump.focusedSecure(dump(null, shade)))
    }

    @Test
    fun `the bouncer line is read only when it says true`() {
        assertTrue(SecureDump.bouncerShowing("  isBouncerShowing(): true\n"))
        assertFalse(SecureDump.bouncerShowing("  isBouncerShowing(): false\n"))
    }
}
