package app.contigua.ui

import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.ui.Modifier
import androidx.compose.ui.test.getUnclippedBoundsInRoot
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performSemanticsAction
import androidx.compose.ui.semantics.SemanticsActions
import androidx.test.ext.junit.runners.AndroidJUnit4
import app.contigua.ui.theme.ContiguaTheme
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
            ContiguaTheme(darkTheme = false, dynamicColor = false) {
                Surface(modifier = Modifier, color = MaterialTheme.colorScheme.background) {
                    HomeScreen(
                        state = state,
                        onToggleEnabled = {},
                        onOpenBatterySettings = {},
                        onToggleAllowConnections = {},
                        onToggleAllowPairings = {},
                        onStatusAction = {},
                        onForget = { "" },
                        onUndoForget = {},
                        onForgetAll = {},
                        onPairNew = {},
                        relativeTime = { "5 minutes ago" },
                    )
                }
            }
        }
        compose.waitForIdle()
    }

    private fun state(
        enabled: Boolean,
        allowConnections: Boolean = true,
        notifyNoAccess: Boolean = false,
        pairNotifyMissing: Boolean = false,
        shizukuInstalled: Boolean = true,
        shizukuRunning: Boolean = true,
        batteryExempt: Boolean = true,
    ) = DeckUiState(
        onboardingDone = true,
        enabled = enabled,
        keepRunning = keepRunningState(enabled, batteryExempt),
        allowConnections = allowConnections,
        shizukuInstalled = shizukuInstalled,
        shizukuRunning = shizukuRunning,
        shizukuGranted = shizukuRunning,
        port = if (shizukuRunning) 4711 else -1,
        wifiName = "Home Wi-Fi",
        shizuku = shizukuUiState(shizukuInstalled, shizukuRunning, shizukuRunning),
        status = mapStatus(
            StatusInput(
                enabled = enabled,
                shizukuRunning = shizukuRunning,
                shizukuGranted = shizukuRunning,
                port = if (shizukuRunning) 4711 else -1,
                connectedMac = null,
                allowConnections = allowConnections,
                notifyNoAccess = notifyNoAccess,
                pairNotifyMissing = pairNotifyMissing,
            ),
        ),
    )

    @Test
    fun `the forget all dialog names the companion device`() {
        // PHONE-18/PHONE-24: the association app windows need is the phone's one
        // lasting change, and the action that removes it says so.
        shoot(state(enabled = true).copy(paired = listOf(PairedMacUi("c1", "Studio", 0L))))
        compose.onNodeWithText("Forget All Macs…").performSemanticsAction(SemanticsActions.OnClick)
        compose.waitForIdle()
        compose.onNodeWithText(
            "Contigua will create a new identity for this phone and remove the companion device it uses " +
                "for app windows. Every Mac must pair again.",
        ).fetchSemanticsNode()
    }

    @Test
    fun `background off says the service stops with the task`() {
        shoot(state(enabled = false))
        compose.onNodeWithText("Stops when you close Contigua from recent apps.").fetchSemanticsNode()
        compose.onNodeWithText("Runs only while Contigua is open.").fetchSemanticsNode()
        compose.onNodeWithText("Ready").fetchSemanticsNode()
    }

    @Test
    fun `background on with the exemption says what it survives`() {
        shoot(state(enabled = true, batteryExempt = true))
        compose.onNodeWithText(
            "Keeps running after you swipe it away and starts when the phone restarts.",
        ).fetchSemanticsNode()
        compose.onNodeWithText("Open battery settings").assertDoesNotExist()
    }

    @Test
    fun `background on without the exemption says what is missing and offers the setting`() {
        shoot(state(enabled = true, batteryExempt = false))
        compose.onNodeWithText("Battery restriction still on — Android may stop it.").fetchSemanticsNode()
        compose.onNodeWithText("Open battery settings").fetchSemanticsNode()
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
    fun `the paired row overflow is named for its Mac`() {
        shoot(
            state(enabled = true).copy(
                paired = listOf(PairedMacUi("client-1", "Studio Mac", 5)),
            ),
        )
        compose.onNodeWithContentDescription("More options for Studio Mac")
            .fetchSemanticsNode()
    }

    @Test
    fun `the phone's home has no notification sharing switch`() {
        // The Mac's per-phone switch is the only one (docs/design/notify.md).
        shoot(state(enabled = true))
        compose.onNodeWithText("Share notifications and Now Playing").assertDoesNotExist()
    }

    @Test
    fun `a missing listener grant while the Mac asked shows the attention item`() {
        shoot(state(enabled = true, notifyNoAccess = true))
        compose.onNodeWithText("Notification access is off").fetchSemanticsNode()
        compose.onNodeWithText("Allow Contigua to read notifications on this phone.").fetchSemanticsNode()
        compose.onNodeWithText("Allow").fetchSemanticsNode()
    }

    @Test
    fun `a pairing prompt with notifications denied shows the attention item`() {
        shoot(state(enabled = true, pairNotifyMissing = true))
        compose.onNodeWithText("Notifications are off").fetchSemanticsNode()
        compose.onNodeWithText("Allow notifications so your Mac can ask to pair.").fetchSemanticsNode()
        compose.onNodeWithText("Allow").fetchSemanticsNode()
    }

    @Test
    fun `connections off still warns and offers turn on`() {
        shoot(state(enabled = true, allowConnections = false))
        compose.onNodeWithText("Connections are off").fetchSemanticsNode()
        compose.onNodeWithText("Turn on").fetchSemanticsNode()
    }

    /**
     * A phone without Shizuku is a different state from a Shizuku that is not
     * running: the one control has to be the one that can fix it (misses.md M6).
     */
    @Test
    fun `a phone without Shizuku offers to get it`() {
        shoot(state(enabled = true, shizukuInstalled = false, shizukuRunning = false))
        compose.onNodeWithText("Shizuku isn't installed").fetchSemanticsNode()
        compose.onNodeWithText("Install Shizuku to use Contigua.").fetchSemanticsNode()
        compose.onNodeWithText("Get Shizuku").fetchSemanticsNode()
        compose.onNodeWithText("Open Shizuku").assertDoesNotExist()
    }
}
