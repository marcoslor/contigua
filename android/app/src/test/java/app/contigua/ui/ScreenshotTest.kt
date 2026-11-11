package app.contigua.ui

import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.size
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.onRoot
import androidx.compose.ui.unit.dp
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.github.takahirom.roborazzi.ExperimentalRoborazziApi
import com.github.takahirom.roborazzi.captureRoboImage
import com.github.takahirom.roborazzi.captureScreenRoboImage
import app.contigua.R
import app.contigua.ui.theme.ContiguaTheme
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

/**
 * Roborazzi screenshots at phone size (412×915 dp). A fixed static color scheme
 * from the seed is used so pixels do not depend on the device's wallpaper.
 */
@RunWith(AndroidJUnit4::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [34], qualifiers = "w412dp-h915dp-420dpi")
class ScreenshotTest {

    @get:Rule
    val compose = createComposeRule()

    // ---- onboarding ----------------------------------------------------

    @Test
    fun onboardingWelcomeLight() = shoot("onboarding_1_welcome_light", dark = false, page = 0, shizuku = ShizukuUiState.NOT_INSTALLED)

    @Test
    fun onboardingWelcomeDark() = shoot("onboarding_1_welcome_dark", dark = true, page = 0, shizuku = ShizukuUiState.NOT_INSTALLED)

    @Test
    fun onboardingShizukuNotInstalledLight() =
        shoot("onboarding_2_shizuku_not_installed_light", false, 1, ShizukuUiState.NOT_INSTALLED)

    @Test
    fun onboardingShizukuNotInstalledDark() =
        shoot("onboarding_2_shizuku_not_installed_dark", true, 1, ShizukuUiState.NOT_INSTALLED)

    @Test
    fun onboardingShizukuNotRunningLight() =
        shoot("onboarding_2_shizuku_not_running_light", false, 1, ShizukuUiState.NOT_RUNNING)

    @Test
    fun onboardingShizukuNotRunningDark() =
        shoot("onboarding_2_shizuku_not_running_dark", true, 1, ShizukuUiState.NOT_RUNNING)

    @Test
    fun onboardingShizukuPermissionLight() =
        shoot("onboarding_2_shizuku_permission_light", false, 1, ShizukuUiState.PERMISSION_NEEDED)

    @Test
    fun onboardingShizukuPermissionDark() =
        shoot("onboarding_2_shizuku_permission_dark", true, 1, ShizukuUiState.PERMISSION_NEEDED)

    @Test
    fun onboardingShizukuReadyLight() =
        shoot("onboarding_2_shizuku_ready_light", false, 1, ShizukuUiState.READY)

    @Test
    fun onboardingShizukuReadyDark() =
        shoot("onboarding_2_shizuku_ready_dark", true, 1, ShizukuUiState.READY)

    @Test
    fun onboardingNotificationsLight() =
        shoot("onboarding_3_notifications_light", false, 2, ShizukuUiState.READY)

    @Test
    fun onboardingNotificationsDark() =
        shoot("onboarding_3_notifications_dark", true, 2, ShizukuUiState.READY)

    @Test
    fun onboardingKeepRunningOnLight() =
        shootNotifications("onboarding_keep_running_on_light", dark = false, KeepRunningState.ON_EXEMPT)

    @Test
    fun onboardingKeepRunningOnDark() =
        shootNotifications("onboarding_keep_running_on_dark", dark = true, KeepRunningState.ON_EXEMPT)

    @Test
    fun onboardingKeepRunningRestrictedLight() =
        shootNotifications("onboarding_keep_running_restricted_light", dark = false, KeepRunningState.ON_RESTRICTED)

    @Test
    fun onboardingKeepRunningRestrictedDark() =
        shootNotifications("onboarding_keep_running_restricted_dark", dark = true, KeepRunningState.ON_RESTRICTED)

    @Test
    fun onboardingPairLight() = shoot("onboarding_4_pair_light", false, 3, ShizukuUiState.READY)

    @Test
    fun onboardingPairDark() = shoot("onboarding_4_pair_dark", true, 3, ShizukuUiState.READY)

    // ---- home ----------------------------------------------------------

    @Test
    fun homeReadyLight() = shootHome("home_ready_light", dark = false, state = homeState())

    @Test
    fun homeReadyDark() = shootHome("home_ready_dark", dark = true, state = homeState())

    @Test
    fun homeConnectedLight() =
        shootHome("home_connected_light", false, homeState(connectedMac = "Studio Mac", liveClientId = "1a2b3c4d", windows = 2))

    @Test
    fun homeConnectedDark() =
        shootHome("home_connected_dark", true, homeState(connectedMac = "Studio Mac", liveClientId = "1a2b3c4d", windows = 2))

    @Test
    fun homeKeepRunningRestrictedLight() =
        shootHome("home_keep_running_restricted_light", false, homeState(batteryExempt = false))

    @Test
    fun homeKeepRunningRestrictedDark() =
        shootHome("home_keep_running_restricted_dark", true, homeState(batteryExempt = false))

    @Test
    fun homeConnectedRowSaysConnectedNow() {
        shootHome("home_connected_row_light", dark = false, state = homeState(connectedMac = "Studio Mac", liveClientId = "1a2b3c4d"))
        compose.onNodeWithText("Connected now").fetchSemanticsNode()
        compose.onNodeWithText("Last connected 5 minutes ago").fetchSemanticsNode()
    }

    @Test
    fun homeShizukuNotRunningLight() =
        shootHome("home_shizuku_not_running_light", false, homeState(shizukuRunning = false))

    @Test
    fun homeShizukuNotRunningDark() =
        shootHome("home_shizuku_not_running_dark", true, homeState(shizukuRunning = false))

    @Test
    fun homeNotificationAccessDark() =
        shootHome("home_notify_access_dark", true, homeState(notifyNoAccess = true))

    @Test
    fun homeNotificationAccessLight() =
        shootHome("home_notify_access_light", false, homeState(notifyNoAccess = true))

    /** A phone without Shizuku: its own words and its own control (misses.md M6). */
    @Test
    fun homePairNotifyLight() = shootHome("home_pair_notify_light", false, homeState(pairNotifyMissing = true))

    @Test
    fun homePairNotifyDark() = shootHome("home_pair_notify_dark", true, homeState(pairNotifyMissing = true))

    @Test
    fun homeShizukuNotInstalledLight() = shootHome(
        "home_shizuku_not_installed_light", false,
        homeState(shizukuRunning = false).copy(shizukuInstalled = false, shizuku = ShizukuUiState.NOT_INSTALLED),
    )

    @Test
    fun homeShizukuNotInstalledDark() = shootHome(
        "home_shizuku_not_installed_dark", true,
        homeState(shizukuRunning = false).copy(shizukuInstalled = false, shizuku = ShizukuUiState.NOT_INSTALLED),
    )

    // ---- pairing dialog ------------------------------------------------

    @Test
    fun pairingDialogLight() = shootPairingDialog("pairing_dialog_light", dark = false)

    @Test
    fun pairingDialogDark() = shootPairingDialog("pairing_dialog_dark", dark = true)

    // ---- app icon (docs/DESIGN.md §3) ----------------------------------

    @Test
    fun appIcon() = shootIcon("app_icon", monochrome = false)

    @Test
    fun appIconMonochrome() = shootIcon("app_icon_monochrome", monochrome = true)

    // --------------------------------------------------------------------

    private fun shoot(name: String, dark: Boolean, page: Int, shizuku: ShizukuUiState) {
        val state = DeckUiState(
            enabled = true,
            shizuku = shizuku,
            shizukuInstalled = shizuku != ShizukuUiState.NOT_INSTALLED,
            shizukuRunning = shizuku == ShizukuUiState.READY || shizuku == ShizukuUiState.PERMISSION_NEEDED,
            shizukuGranted = shizuku == ShizukuUiState.READY,
            notificationsGranted = false,
            batteryRequested = false,
        )
        capture(name, dark) {
            OnboardingScreen(
                state = state,
                onGetShizuku = {},
                onOpenShizuku = {},
                onAllowShizuku = {},
                onAllowNotifications = {},
                onKeepRunning = {},
                onOpenBatterySettings = {},
                onScanQr = {},
                onFinished = {},
                initialPage = page,
                autoAdvance = false,
            )
        }
    }

    /** The notifications step with the keep-running row in one of its states. */
    private fun shootNotifications(name: String, dark: Boolean, keepRunning: KeepRunningState) {
        val state = DeckUiState(
            enabled = keepRunning != KeepRunningState.OFF,
            keepRunning = keepRunning,
            shizuku = ShizukuUiState.READY,
            shizukuInstalled = true,
            shizukuRunning = true,
            shizukuGranted = true,
            notificationsGranted = false,
            batteryRequested = true,
        )
        capture(name, dark) {
            OnboardingScreen(
                state = state,
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
        }
    }

    private fun homeState(
        connectedMac: String? = null,
        liveClientId: String? = null,
        windows: Int = 0,
        shizukuRunning: Boolean = true,
        notifyNoAccess: Boolean = false,
        pairNotifyMissing: Boolean = false,
        batteryExempt: Boolean = true,
    ): DeckUiState {
        val status = mapStatus(
            StatusInput(
                enabled = true,
                shizukuRunning = shizukuRunning,
                shizukuGranted = shizukuRunning,
                port = if (shizukuRunning) 4711 else -1,
                connectedMac = connectedMac,
                notifyNoAccess = notifyNoAccess,
                pairNotifyMissing = pairNotifyMissing,
            ),
        )
        return DeckUiState(
            onboardingDone = true,
            enabled = true,
            keepRunning = keepRunningState(true, batteryExempt),
            shizukuInstalled = true,
            shizukuRunning = shizukuRunning,
            shizukuGranted = shizukuRunning,
            port = 4711,
            connectedMac = connectedMac,
            windows = windows,
            paired = pairedRows(
                listOf(
                    PairedMacUi("1a2b3c4d", "Studio Mac", 1_700_000_000_000L),
                    PairedMacUi("5e6f7a8b", "Mac Studio", 1_699_000_000_000L),
                ),
                liveClientId,
            ),
            wifiName = "Home Wi-Fi",
            shizuku = shizukuUiState(true, shizukuRunning, shizukuRunning),
            status = status,
        )
    }

    private fun shootHome(name: String, dark: Boolean, state: DeckUiState) {
        capture(name, dark) {
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

    @OptIn(ExperimentalRoborazziApi::class)
    private fun shootPairingDialog(name: String, dark: Boolean) {
        compose.mainClock.autoAdvance = false
        compose.setContent {
            ContiguaTheme(darkTheme = dark, dynamicColor = false) {
                Surface(modifier = Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) {
                    PairingDialog(
                        pending = PendingPairingUi(
                            requestId = "req-1",
                            macName = "Studio Mac",
                            code = "482913",
                        ),
                        onAnswer = {},
                    )
                }
            }
        }
        compose.mainClock.advanceTimeBy(1_200)
        captureScreenRoboImage("src/test/screenshots/$name.png")
    }

    private fun shootIcon(name: String, monochrome: Boolean) {
        val tag = "appIcon"
        compose.mainClock.autoAdvance = false
        compose.setContent {
            ContiguaTheme(darkTheme = false, dynamicColor = false) {
                Surface(color = Color(0xFFFBF8FF)) {
                    Box(
                        modifier = Modifier
                            .size(108.dp)
                            .testTag(tag),
                    ) {
                        if (!monochrome) {
                            Image(
                                painter = painterResource(R.drawable.ic_launcher_background),
                                contentDescription = null,
                                modifier = Modifier.fillMaxSize(),
                            )
                        } else {
                            Box(modifier = Modifier.fillMaxSize().background(Color(0xFF3B4279)))
                        }
                        Image(
                            painter = painterResource(
                                if (monochrome) R.drawable.ic_launcher_monochrome else R.drawable.ic_launcher_foreground,
                            ),
                            contentDescription = null,
                            modifier = Modifier.fillMaxSize(),
                        )
                    }
                }
            }
        }
        compose.mainClock.advanceTimeBy(500)
        compose.onNodeWithTag(tag).captureRoboImage("src/test/screenshots/$name.png")
    }

    private fun capture(name: String, dark: Boolean, content: @Composable () -> Unit) {
        compose.mainClock.autoAdvance = false
        compose.setContent {
            ContiguaTheme(darkTheme = dark, dynamicColor = false) {
                Surface(modifier = Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) {
                    content()
                }
            }
        }
        compose.mainClock.advanceTimeBy(1_200)
        compose.onRoot().captureRoboImage("src/test/screenshots/$name.png")
    }
}
