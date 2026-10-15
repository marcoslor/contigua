package dev.pocketdeck.ui

import android.Manifest
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.material3.SnackbarHostState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.lifecycle.compose.collectAsStateWithLifecycle

/**
 * The app's Compose tree: onboarding until it is finished, home after, with the
 * pairing prompt overlaid whenever one is pending.
 */
@Composable
fun DeckApp(deck: DeckViewModel) {
    val state by deck.state.collectAsStateWithLifecycle()
    val snackbarMessage by deck.snackbar.collectAsStateWithLifecycle()
    val snackbarHostState = remember { SnackbarHostState() }

    val scanQr = rememberQrScanLauncher { raw ->
        if (raw == null) deck.onQrScanFailed() else deck.onQrScanned(raw)
    }
    val notificationsLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestPermission(),
    ) { deck.onNotificationPermissionResult() }

    LaunchedEffect(snackbarMessage) {
        snackbarMessage?.let { message ->
            snackbarHostState.showSnackbar(message)
            deck.consumeSnackbar()
        }
    }

    if (state.onboardingDone) {
        HomeScreen(
            state = state,
            onToggleEnabled = deck::setEnabled,
            onToggleNotify = deck::setNotifyShared,
            onStatusAction = deck::runStatusAction,
            onForget = deck::forget,
            onUndoForget = deck::undoForget,
            onPairNew = scanQr,
            snackbarHostState = snackbarHostState,
        )
    } else {
        OnboardingScreen(
            state = state,
            onGetShizuku = deck::getShizuku,
            onOpenShizuku = deck::openShizuku,
            onAllowShizuku = deck::allowShizuku,
            onAllowNotifications = {
                notificationsLauncher.launch(Manifest.permission.POST_NOTIFICATIONS)
            },
            onIgnoreBattery = deck::ignoreBatteryOptimizations,
            onScanQr = scanQr,
            onFinished = deck::finishOnboarding,
            snackbarHostState = snackbarHostState,
        )
    }

    state.pending?.let { pending ->
        PairingDialog(pending = pending, onAnswer = deck::answerPairing)
    }
}
