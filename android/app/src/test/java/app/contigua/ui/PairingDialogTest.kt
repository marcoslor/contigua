package app.contigua.ui

import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.unit.dp
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.test.ext.junit.runners.AndroidJUnit4
import app.contigua.ui.theme.ContiguaTheme
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.annotation.Config
import org.robolectric.shadows.ShadowDialog

/**
 * The pairing prompt on a gesture-nav phone: a floating card with 16 dp side
 * margins and 16 dp above the navigation-bar inset, not a bottom sheet under
 * the gesture handle. The dialog is edge-to-edge, so the card's window
 * coordinates are screen coordinates.
 */
@RunWith(AndroidJUnit4::class)
@Config(sdk = [34], qualifiers = "w411dp-h891dp-xxhdpi")
class PairingDialogTest {

    @get:Rule
    val compose = createComposeRule()

    @Test
    fun `the card floats 16dp above the navigation bar inset`() {
        var screenHeightDp = 0f
        compose.setContent {
            screenHeightDp = LocalConfiguration.current.screenHeightDp.toFloat()
            ContiguaTheme(darkTheme = false, dynamicColor = false) {
                PairingDialog(
                    pending = PendingPairingUi("req-1", "Studio Mac", "482913"),
                    onAnswer = {},
                    navigationBars = WindowInsets(0.dp, 0.dp, 0.dp, 48.dp),
                )
            }
        }
        compose.waitForIdle()

        val card = compose.onNodeWithTag("pairingCard").fetchSemanticsNode().boundsInWindow
        val decor = ShadowDialog.getLatestDialog()!!.window!!.decorView
        val location = IntArray(2).also { decor.getLocationOnScreen(it) }
        val cardBottomDp = (location[1] + card.bottom) / compose.density.density
        val expected = screenHeightDp - 48f - 16f

        // The reported bug: the sheet reaches under the gesture handle.
        assertTrue(
            "card bottom $cardBottomDp must stay above the nav inset and 16dp",
            cardBottomDp <= expected + 1f,
        )
        // And the wanted design: exactly 16dp above the inset, not centred.
        assertEquals(expected, cardBottomDp, 1f)
    }
}
