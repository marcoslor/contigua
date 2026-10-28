package dev.pocketdeck.ui

/**
 * The pure half of the UI: the shape of the state the screens render, and the
 * input → card-state mapping from docs/DESIGN.md §2. No Android types live here
 * so the mappings are JVM-testable.
 */

/** The status-card states in docs/DESIGN.md §2. */
enum class StatusState { READY, CONNECTED, NEEDS_ATTENTION, ERROR }

/** Why the card needs an action; drives the fix button. */
enum class AttentionKind {
    NONE,
    CONNECTIONS_OFF,
    SHIZUKU_NOT_RUNNING,
    SHIZUKU_PERMISSION,
    /** The Mac asked for notifications but this phone's listener grant is missing. */
    NOTIFY_ACCESS,
    /** A pairing prompt is waiting and this phone's notification permission is denied. */
    PAIR_NOTIFY,
    RETRY,
}

data class DeckStatus(
    val state: StatusState,
    val attention: AttentionKind,
    /** Ready, but only while the app's task lives (background switch off). */
    val untilTaskClosed: Boolean = false,
)

/** The inputs the status card depends on. */
data class StatusInput(
    val enabled: Boolean,
    val shizukuRunning: Boolean,
    val shizukuGranted: Boolean,
    val port: Int,
    val connectedMac: String?,
    /** The master gate; false also means "needs attention" while the service runs. */
    val allowConnections: Boolean = true,
    /** The Mac asked for notifications and the phone's listener grant is missing. */
    val notifyNoAccess: Boolean = false,
    /** A pairing prompt is pending and POST_NOTIFICATIONS is denied: its notification cannot show. */
    val pairNotifyMissing: Boolean = false,
)

/**
 * Status card mapping. Allow connections off and a broken Shizuku are both
 * "needs attention"; the background switch being off is only information. Only
 * a running server with nothing connected is "ready".
 */
fun mapStatus(input: StatusInput): DeckStatus = when {
    !input.allowConnections ->
        DeckStatus(StatusState.NEEDS_ATTENTION, AttentionKind.CONNECTIONS_OFF)
    !input.shizukuRunning -> DeckStatus(StatusState.NEEDS_ATTENTION, AttentionKind.SHIZUKU_NOT_RUNNING)
    !input.shizukuGranted -> DeckStatus(StatusState.NEEDS_ATTENTION, AttentionKind.SHIZUKU_PERMISSION)
    input.notifyNoAccess -> DeckStatus(StatusState.NEEDS_ATTENTION, AttentionKind.NOTIFY_ACCESS)
    // A prompt the person cannot see anywhere but the foreground: the home
    // names the permission that would show it (PAIR-6, M8).
    input.pairNotifyMissing -> DeckStatus(StatusState.NEEDS_ATTENTION, AttentionKind.PAIR_NOTIFY)
    input.connectedMac != null -> DeckStatus(StatusState.CONNECTED, AttentionKind.NONE)
    !input.enabled -> DeckStatus(StatusState.READY, AttentionKind.NONE, untilTaskClosed = true)
    input.port > 0 -> DeckStatus(StatusState.READY, AttentionKind.NONE)
    else -> DeckStatus(StatusState.ERROR, AttentionKind.RETRY)
}

/** The Shizuku onboarding row's four states (docs/UX.md step 2). */
enum class ShizukuUiState { NOT_INSTALLED, NOT_RUNNING, PERMISSION_NEEDED, READY }

fun shizukuUiState(installed: Boolean, running: Boolean, granted: Boolean): ShizukuUiState = when {
    !installed -> ShizukuUiState.NOT_INSTALLED
    !running -> ShizukuUiState.NOT_RUNNING
    !granted -> ShizukuUiState.PERMISSION_NEEDED
    else -> ShizukuUiState.READY
}

/** The onboarding pager's four steps. */
enum class OnboardingStep { WELCOME, SHIZUKU, NOTIFICATIONS, PAIR }

data class OnboardingInput(
    val shizukuRunning: Boolean,
    val shizukuGranted: Boolean,
    val notificationsGranted: Boolean,
    val batteryRequested: Boolean,
    val pairedCount: Int,
)

/**
 * Whether a step's condition is already true. Welcome never auto-advances (its
 * action is the **Get started** button); the pair step completes as soon as one
 * Mac is paired.
 */
fun isOnboardingComplete(step: OnboardingStep, input: OnboardingInput): Boolean = when (step) {
    OnboardingStep.WELCOME -> false
    OnboardingStep.SHIZUKU -> input.shizukuRunning && input.shizukuGranted
    OnboardingStep.NOTIFICATIONS -> input.notificationsGranted && input.batteryRequested
    OnboardingStep.PAIR -> input.pairedCount > 0
}

data class PairedMacUi(
    val clientId: String,
    val name: String,
    val lastConnected: Long,
    /** True while this Mac has a live session; the row then says "Connected now". */
    val connected: Boolean = false,
)

data class PendingPairingUi(val requestId: String, val macName: String, val code: String)

data class DeckUiState(
    val onboardingDone: Boolean = false,
    val enabled: Boolean = false,
    val allowConnections: Boolean = true,
    val allowPairings: Boolean = true,
    /** The Mac asked for notifications but this phone's listener grant is missing. */
    val notifyNoAccess: Boolean = false,
    val shizukuInstalled: Boolean = false,
    val shizukuRunning: Boolean = false,
    val shizukuGranted: Boolean = false,
    val port: Int = -1,
    val connectedMac: String? = null,
    val windows: Int = 0,
    val paired: List<PairedMacUi> = emptyList(),
    val pending: PendingPairingUi? = null,
    val notificationsGranted: Boolean = false,
    val batteryRequested: Boolean = false,
    val wifiName: String? = null,
    val shizuku: ShizukuUiState = ShizukuUiState.NOT_INSTALLED,
    val status: DeckStatus = DeckStatus(StatusState.ERROR, AttentionKind.NONE),
) {
    val onboarding: OnboardingInput
        get() = OnboardingInput(shizukuRunning, shizukuGranted, notificationsGranted, batteryRequested, paired.size)
}
