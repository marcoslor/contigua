package app.contigua.ui

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
            onOpenBatterySettings = deck::openBatterySettings,
            onToggleAllowConnections = deck::setAllowConnections,
            onToggleAllowPairings = deck::setAllowPairings,
            onStatusAction = { kind ->
                // The pairing prompt's notification needs the runtime
                // permission; an Activity owns the launcher (PAIR-6).
                if (kind == AttentionKind.PAIR_NOTIFY) {
                    notificationsLauncher.launch(Manifest.permission.POST_NOTIFICATIONS)
                } else {
                    deck.runStatusAction(kind)
                }
            },
            onForget = deck::forget,
            onUndoForget = deck::undoForget,
            onForgetAll = deck::forgetAllMacs,
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
            onKeepRunning = deck::keepRunningOn,
            onOpenBatterySettings = deck::openBatterySettings,
            onScanQr = scanQr,
            onFinished = deck::finishOnboarding,
            snackbarHostState = snackbarHostState,
        )
    }

    state.pending?.let { pending ->
        PairingDialog(pending = pending, onAnswer = deck::answerPairing)
    }
}
