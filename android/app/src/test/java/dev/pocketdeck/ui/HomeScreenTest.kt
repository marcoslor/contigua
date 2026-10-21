package dev.pocketdeck.ui

import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.ui.Modifier
import androidx.compose.ui.test.getUnclippedBoundsInRoot
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.test.ext.junit.runners.AndroidJUnit4
import dev.pocketdeck.ui.theme.PocketDeckTheme
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.annotation.Config

/**
 * The home screen's status card when "Keep running in the background" is off:
 * the service still runs with the task, so the card is information, not a
 * warning with a fix button.
 */
@RunWith(AndroidJUnit4::class)
@Config(sdk = [34])
class HomeScreenTest {

    @get:Rule
    val compose = createComposeRule()

    private fun shoot(state: DeckUiState) {
        compose.setContent {
            PocketDeckTheme(darkTheme = false, dynamicColor = false) {
                Surface(modifier = Modifier, color = MaterialTheme.colorScheme.background) {
                    HomeScreen(
                        state = state,
                        onToggleEnabled = {},
                        onToggleAllowConnections = {},
                        onToggleAllowPairings = {},
                        onToggleNotify = {},
                        onStatusAction = {},
                        onForget = { "" },
                        onUndoForget = {},
                        onPairNew = {},
                        relativeTime = { "5 minutes ago" },
                    )
                }
            }
        }
        compose.waitForIdle()
    }

    private fun state(enabled: Boolean, allowConnections: Boolean = true) = DeckUiState(
        onboardingDone = true,
        enabled = enabled,
        allowConnections = allowConnections,
        shizukuInstalled = true,
        shizukuRunning = true,
        shizukuGranted = true,
        port = 4711,
        wifiName = "Home Wi-Fi",
        shizuku = ShizukuUiState.READY,
        status = mapStatus(
            StatusInput(
                enabled = enabled,
                shizukuRunning = true,
                shizukuGranted = true,
                port = 4711,
                connectedMac = null,
                allowConnections = allowConnections,
            ),
        ),
    )

    @Test
    fun `background off says the service stops with the task`() {
        shoot(state(enabled = false))
        compose.onNodeWithText("Stops when you close PocketDeck from recent apps.").fetchSemanticsNode()
        compose.onNodeWithText("Ready").fetchSemanticsNode()
    }

    @Test
    fun `background off has no turn-on button`() {
        shoot(state(enabled = false))
        compose.onNodeWithText("Turn on").assertDoesNotExist()
    }

    @Test
    fun `the card, the first switch label and the paired title share a left edge`() {
        shoot(state(enabled = true))
        val card = compose.onNodeWithTag("statusCard").getUnclippedBoundsInRoot().left.value
        val row = compose.onNodeWithText("Keep running in the background", useUnmergedTree = true)
            .getUnclippedBoundsInRoot().left.value
        val paired = compose.onNodeWithText("Paired Macs").getUnclippedBoundsInRoot().left.value
        assertEquals("switch row must not be indented inside the card's edge", card, row, 1f)
        assertEquals("Paired Macs title must share the same edge", card, paired, 1f)
    }

    @Test
    fun `the sharing switch says what it shares and why it is off`() {
        shoot(state(enabled = true))
        compose.onNodeWithText("Share notifications and Now Playing").fetchSemanticsNode()
        compose.onNodeWithText("Only while a Mac is connected. Off by default.").fetchSemanticsNode()
    }

    @Test
    fun `connections off still warns and offers turn on`() {
        shoot(state(enabled = true, allowConnections = false))
        compose.onNodeWithText("Connections are off").fetchSemanticsNode()
        compose.onNodeWithText("Turn on").fetchSemanticsNode()
    }
}
