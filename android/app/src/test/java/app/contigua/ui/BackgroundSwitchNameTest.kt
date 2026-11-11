package app.contigua.ui

import androidx.compose.foundation.layout.Column
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.ui.Modifier
import androidx.compose.ui.test.assertCountEquals
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onNodeWithText
import androidx.test.ext.junit.runners.AndroidJUnit4
import app.contigua.ui.theme.ContiguaTheme
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.annotation.Config

/**
 * CONV-PD-07: one name per thing. The background switch is met in onboarding
 * and again on the home within a minute, so both render the home's words.
 */
@RunWith(AndroidJUnit4::class)
@Config(sdk = [34])
class BackgroundSwitchNameTest {

    @get:Rule
    val compose = createComposeRule()

    private val name = "Keep running in the background"

    @Test
    fun `onboarding and the home use one name for the background switch`() {
        compose.setContent {
            ContiguaTheme(darkTheme = false, dynamicColor = false) {
                Surface(modifier = Modifier, color = MaterialTheme.colorScheme.background) {
                    Column {
                        OnboardingScreen(
                            state = DeckUiState(enabled = true, shizuku = ShizukuUiState.READY),
                            onGetShizuku = {},
                            onOpenShizuku = {},
                            onAllowShizuku = {},
                            onAllowNotifications = {},
                            onKeepRunning = {},
                            onOpenBatterySettings = {},
                            onScanQr = {},
                            onFinished = {},
                            initialPage = 2,
                            autoAdvance = false,
                        )
                        HomeScreen(
                            state = DeckUiState(
                                onboardingDone = true,
                                enabled = true,
                                shizukuInstalled = true,
                                shizukuRunning = true,
                                shizukuGranted = true,
                                port = 4711,
                                shizuku = ShizukuUiState.READY,
                                status = mapStatus(
                                    StatusInput(
                                        enabled = true,
                                        shizukuRunning = true,
                                        shizukuGranted = true,
                                        port = 4711,
                                        connectedMac = null,
                                    ),
                                ),
                            ),
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
        }
        compose.waitForIdle()

        compose.onAllNodesWithText(name).assertCountEquals(2)
        compose.onNodeWithText("Let Contigua run in the background").assertDoesNotExist()
    }
}
