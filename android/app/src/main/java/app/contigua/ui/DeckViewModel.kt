package app.contigua.ui

import android.Manifest
import android.app.Application
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.net.wifi.WifiManager
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.util.Log
import androidx.core.content.ContextCompat
import androidx.lifecycle.AndroidViewModel
import app.contigua.IDeckService
import app.contigua.R
import app.contigua.app.BatteryExemption
import app.contigua.app.DeckForegroundService
import app.contigua.app.DeckState
import app.contigua.app.KeepRunningAction
import app.contigua.app.Prefs
import app.contigua.app.QrPairing
import app.contigua.app.ShellFailure
import app.contigua.app.ShizukuClient
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import rikka.shizuku.Shizuku
import java.util.concurrent.Executor
import java.util.concurrent.Executors

/**
 * The one shell push (`setPairedClients`): a binder call whose reply can be as
 * slow as the shell service is, so it never runs on the main thread (PAIR-20).
 */
private fun pushToShell(json: String) {
    val service = checkNotNull(ShizukuClient.current()) { "shell service not bound" }
    service.setPairedClients(json)
}

/**
 * The single UI state holder. It observes the foreground service, the Shizuku
 * client and [Prefs], and exposes one [StateFlow]; composables only render and
 * call back into here, never touch Android services directly.
 */
class DeckViewModel(
    app: Application,
    /** Runs the identity rotation and the shell push off the main thread. */
    private val background: Executor = Executors.newSingleThreadExecutor { r ->
        Thread(r, "contigua-pairing-push").apply { isDaemon = true }
    },
    /** The shell push; a test hands in a recorder instead of the binder. */
    private val push: (String) -> Unit = ::pushToShell,
) : AndroidViewModel(app) {

    private val _state = MutableStateFlow(DeckUiState())
    val state: StateFlow<DeckUiState> = _state.asStateFlow()

    private val _snackbar = MutableStateFlow<String?>(null)
    val snackbar: StateFlow<String?> = _snackbar.asStateFlow()

    private val handler = Handler(Looper.getMainLooper())

    /** Client ids removed from the list but still on disk until Undo expires. */
    private val pendingForgets = LinkedHashMap<String, Runnable>()

    /** Forget All is rotating the identity off the main thread: list empty now. */
    private var forgettingAll = false

    private val deckListener: () -> Unit = { refresh() }

    private val shizukuClientListener: (IDeckService?) -> Unit = { refresh() }

    /**
     * The one keep-running action (PHONE-19). The onboarding button and the
     * home switch both go through it; the exemption is asked only while it is
     * missing, and a failed request is reported, never swallowed.
     */
    private val keepRunning = KeepRunningAction(
        isExempt = { BatteryExemption.isExempt(getApplication<Application>()) },
        store = { Prefs.setEnabled(getApplication<Application>(), it) },
        startService = { DeckForegroundService.start(getApplication<Application>()) },
        requestExemption = {
            val ctx = getApplication<Application>()
            val opened = BatteryExemption.open(ctx)
            // "Asked once" only when a screen really opened: a missing screen
            // must not count as a completed onboarding step (PHONE-19).
            if (opened != null) Prefs.setBatteryRequested(ctx, true)
            opened != null
        },
    )

    private val shizukuPermissionListener = Shizuku.OnRequestPermissionResultListener { requestCode, grantResult ->
        if (requestCode == REQUEST_SHIZUKU) {
            val ctx = getApplication<Application>()
            DeckState.shizukuGranted = grantResult == PackageManager.PERMISSION_GRANTED
            if (DeckState.shizukuGranted) DeckForegroundService.start(ctx)
            refresh()
        }
    }

    init {
        DeckState.addListener(deckListener)
        ShizukuClient.addListener(shizukuClientListener)
        runCatching { Shizuku.addRequestPermissionResultListener(shizukuPermissionListener) }
        refresh()
        // The service runs while the app's task exists; the background switch
        // only decides whether it also outlives the task and starts at boot.
        DeckForegroundService.start(getApplication())
    }

    override fun onCleared() {
        DeckState.removeListener(deckListener)
        ShizukuClient.removeListener(shizukuClientListener)
        runCatching { Shizuku.removeRequestPermissionResultListener(shizukuPermissionListener) }
        handler.removeCallbacksAndMessages(null)
        pendingForgets.clear()
        super.onCleared()
    }

    // ---- state ---------------------------------------------------------

    fun refresh() {
        val ctx = getApplication<Application>()
        val enabled = Prefs.isEnabled(ctx)
        val running = ShizukuClient.hasBinder()
        // Shizuku keeps a grant across a restart of its server: a check it
        // cannot answer yet is the last known answer, never "denied" — that is
        // what asked the person to allow Contigua again after their server
        // came back (PHONE-20).
        val granted = ShizukuClient.permission() ?: DeckState.shizukuGranted
        val installed = isInstalled(ctx, SHIZUKU_PACKAGE)
        val notificationsGranted =
            ContextCompat.checkSelfPermission(ctx, Manifest.permission.POST_NOTIFICATIONS) ==
                PackageManager.PERMISSION_GRANTED
        val port = DeckState.port
        val connected = DeckState.connectedMac
        // Forget All empties the list before the background rotation lands, so
        // the row goes the moment the person confirms (PAIR-20).
        val paired = if (forgettingAll) {
            emptyList()
        } else {
            Prefs.paired(ctx).filterNot { pendingForgets.containsKey(it.clientId) }
        }

        val allowConnections = Prefs.isAllowConnections(ctx)
        _state.value = DeckUiState(
            onboardingDone = Prefs.isOnboardingDone(ctx),
            enabled = enabled,
            keepRunning = keepRunningState(enabled, BatteryExemption.isExempt(ctx)),
            allowConnections = allowConnections,
            allowPairings = Prefs.isAllowPairings(ctx),
            notifyNoAccess = DeckState.notifyNoAccess,
            shizukuInstalled = installed,
            shizukuRunning = running,
            shizukuGranted = granted,
            port = port,
            connectedMac = connected,
            windows = DeckState.windows,
            paired = pairedRows(
                paired.map { PairedMacUi(it.clientId, it.name, it.lastConnected) },
                DeckState.connectedClientId,
            ),
            pending = DeckState.pending?.let { PendingPairingUi(it.requestId, it.macName, it.code) },
            versionSentence = DeckState.versionSentence,
            notificationsGranted = notificationsGranted,
            batteryRequested = Prefs.isBatteryRequested(ctx),
            wifiName = wifiName(ctx),
            shizuku = shizukuUiState(installed, running, granted),
            // Every fact the card reads comes from here, the flag included:
            // a state set beside the mapping is a card that cannot be reached.
            status = mapStatus(
                StatusInput(
                    enabled = enabled,
                    shizukuRunning = running,
                    shizukuGranted = granted,
                    port = port,
                    connectedMac = connected,
                    allowConnections = allowConnections,
                    notifyNoAccess = DeckState.notifyNoAccess,
                    pairNotifyMissing = DeckState.pending != null && !notificationsGranted,
                    versionSentence = DeckState.versionSentence,
                    shellNotAnswering =
                        running && DeckState.shellFailure?.token == ShellFailure.BIND_TIMEOUT,
                ),
            ),
        )
    }

    // ---- onboarding actions -------------------------------------------

    fun finishOnboarding() {
        val ctx = getApplication<Application>()
        Prefs.setOnboardingDone(ctx, true)
        refresh()
    }

    fun getShizuku() {
        val ctx = getApplication<Application>()
        val market = Intent(Intent.ACTION_VIEW, Uri.parse("market://details?id=$SHIZUKU_PACKAGE"))
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        val web = Intent(
            Intent.ACTION_VIEW,
            Uri.parse("https://play.google.com/store/apps/details?id=$SHIZUKU_PACKAGE"),
        ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        runCatching { ctx.startActivity(market) }
            .recoverCatching { ctx.startActivity(web) }
    }

    fun openShizuku() {
        val ctx = getApplication<Application>()
        val intent = ctx.packageManager.getLaunchIntentForPackage(SHIZUKU_PACKAGE)
            ?.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        if (intent == null) {
            postSnackbar(ctx.getString(R.string.shizuku_missing))
        } else {
            runCatching { ctx.startActivity(intent) }
        }
    }

    fun allowShizuku() {
        // Only a binder can be asked, and only a real "denied" answer is worth a
        // prompt: with no binder the card says Shizuku is not running instead.
        if (ShizukuClient.permission() == false) {
            runCatching { Shizuku.requestPermission(REQUEST_SHIZUKU) }
        }
        refresh()
    }

    fun onNotificationPermissionResult() = refresh()

    /**
     * The onboarding step's button: the same action as turning the home switch
     * on (PHONE-19), so the two cannot drift. It stored "asked once" and threw
     * the settings intent away before; nothing turned the pref on.
     */
    fun keepRunningOn() = setEnabled(true)

    // ---- home actions --------------------------------------------------

    fun setEnabled(value: Boolean) {
        val ctx = getApplication<Application>()
        // One action for the onboarding step and this switch (PHONE-19): store
        // the pref, start the service, ask for the battery exemption only when
        // it is missing. Off never stops the running service; it lets the task's
        // swipe decide (PHONE-5/PHONE-7).
        val result = keepRunning.apply(value)
        DeckState.enabled = value
        if (result == KeepRunningAction.Result.ON_SETTINGS_UNAVAILABLE) {
            Log.i(TAG, "keep running set; battery settings could not be opened")
            postSnackbar(ctx.getString(R.string.keep_running_settings_failed))
        }
        refresh()
    }

    /** The keep-running row's fix when the exemption is still missing. */
    fun openBatterySettings() {
        val ctx = getApplication<Application>()
        if (BatteryExemption.open(ctx) == null) {
            postSnackbar(ctx.getString(R.string.keep_running_settings_failed))
        }
        refresh()
    }

    /**
     * The master connection gate. The server refuses every Mac while it is
     * off and drops the live session at once; the advertisement follows so
     * the phone is not visible either (docs/PROTOCOL.md).
     */
    fun setAllowConnections(value: Boolean) {
        val ctx = getApplication<Application>()
        Prefs.setAllowConnections(ctx, value)
        pushGates()
        DeckForegroundService.gatesChanged(ctx)
        refresh()
    }

    /** Whether an unknown Mac may pair. Paired Macs keep connecting. */
    fun setAllowPairings(value: Boolean) {
        val ctx = getApplication<Application>()
        Prefs.setAllowPairings(ctx, value)
        pushGates()
        DeckForegroundService.gatesChanged(ctx)
        refresh()
    }

    private fun pushGates() {
        val ctx = getApplication<Application>()
        val svc = ShizukuClient.current() ?: return
        runCatching { svc.setGates(Prefs.isAllowConnections(ctx), Prefs.isAllowPairings(ctx)) }
            .onFailure {
                // A daemon that does not know the gates must not keep serving.
                runCatching { svc.stopServer() }
            }
    }

    fun runStatusAction(kind: AttentionKind) {
        val ctx = getApplication<Application>()
        when (kind) {
            AttentionKind.CONNECTIONS_OFF -> setAllowConnections(true)
            // Not running is only openable when the app is there; a phone
            // without it gets the store, or the one control cannot fix it.
            AttentionKind.SHIZUKU_NOT_RUNNING ->
                if (_state.value.shizuku == ShizukuUiState.NOT_INSTALLED) getShizuku() else openShizuku()
            AttentionKind.SHIZUKU_PERMISSION -> allowShizuku()
            // The Mac asked to share notifications but the listener grant is
            // missing: the one screen that can grant it.
            AttentionKind.NOTIFY_ACCESS -> runCatching {
                ctx.startActivity(
                    Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS)
                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
                )
            }

            // The runtime permission is requested by the screen (an Activity
            // owns the launcher); this branch is the screen's fallback.
            AttentionKind.PAIR_NOTIFY -> refresh()

            // R-8/D-4: the card names the other app to update; nothing to do here.
            AttentionKind.VERSION -> refresh()

            AttentionKind.RETRY -> {
                ShizukuClient.retry()
                DeckForegroundService.start(ctx)
                refresh()
            }

            AttentionKind.SHELL_NOT_ANSWERING -> {
                // ISS-100: a tap restarts Contigua's own connection, which for
                // a binder that answers but never binds means our process.
                ShizukuClient.retry()
                DeckForegroundService.start(ctx)
                refresh()
            }

            AttentionKind.NONE -> refresh()
        }
    }

    /** Starts the four-second undo window and returns the snackbar text. */
    fun forget(mac: PairedMacUi): String {
        val ctx = getApplication<Application>()
        val delete = Runnable {
            pendingForgets.remove(mac.clientId)
            Prefs.forget(ctx, mac.clientId)
            DeckState.paired = Prefs.paired(ctx)
            pushPaired()
            refresh()
            DeckState.notifyChanged()
        }
        pendingForgets[mac.clientId] = delete
        handler.postDelayed(delete, FORGET_UNDO_MS)
        refresh()
        return ctx.getString(R.string.home_forgotten, mac.name)
    }

    fun undoForget(mac: PairedMacUi) {
        pendingForgets.remove(mac.clientId)?.let { handler.removeCallbacks(it) }
        refresh()
    }

    /**
     * Paired Macs ▸ Forget All Macs…: rotate the phone's identity and drop every
     * pairing. The shell service sees a different fingerprint on the next push,
     * so it closes the live session and forgets what it cached; every Mac's pin
     * then reads Pair again (docs/specs/pairing.md PAIR-20).
     *
     * The list empties at once. The identity rotation is key generation and the
     * push is a binder call the shell may take time to answer: both run on
     * [background], the push after the rotation, or the main thread would be
     * waiting on them (the ANR this fixes).
     */
    fun forgetAllMacs() {
        val ctx = getApplication<Application>()
        pendingForgets.values.forEach { handler.removeCallbacks(it) }
        pendingForgets.clear()
        forgettingAll = true
        DeckState.paired = emptyList()
        refresh()
        DeckState.notifyChanged()
        background.execute {
            Prefs.forgetAll(ctx)
            pushNow(ctx)
            handler.post {
                forgettingAll = false
                refresh()
            }
        }
    }

    fun answerPairing(allow: Boolean) {
        val pending = DeckState.pending ?: return
        val ctx = getApplication<Application>()
        val action = if (allow) DeckForegroundService.ACTION_ALLOW else DeckForegroundService.ACTION_DENY
        ctx.startService(
            Intent(ctx, DeckForegroundService::class.java)
                .setAction(action)
                .putExtra(DeckForegroundService.EXTRA_REQUEST_ID, pending.requestId),
        )
        DeckState.pending = null
        DeckState.notifyChanged()
    }

    // ---- QR pairing ----------------------------------------------------

    fun onQrScanned(raw: String) {
        val ctx = getApplication<Application>()
        when (val result = QrPairing.parse(raw)) {
            is QrPairing.Result.Pairing -> {
                // R2: the scan pins the Mac by `f` and hands the one-time `s`
                // to the shell server (RAM + a short-lived store copy); the
                // shell answers the Mac's probe with pair.qr, and the Allow
                // prompt still gates the first connection.
                val now = System.currentTimeMillis()
                val existing = Prefs.pendingQr(ctx)
                if (!QrPairing.mayReplacePending(
                        existing?.macFp, existing?.at ?: 0L, result.macFpHex,
                        now, Prefs.PENDING_QR_TTL_MS)) {
                    // L-2: a link from another Mac cannot overwrite a live scan.
                    Log.i(TAG, "pair link ignored: another pairing is pending")
                    return
                }
                Prefs.setPendingQr(
                    ctx,
                    Prefs.PendingQr(result.clientId, result.name, result.macFpHex,
                                    result.secretHex, now),
                )
                pushPaired()
                postSnackbar(ctx.getString(R.string.qr_waiting, result.name))
            }
            QrPairing.Result.BadKey -> postSnackbar(ctx.getString(R.string.qr_bad_key))
            QrPairing.Result.Malformed -> postSnackbar(ctx.getString(R.string.qr_incomplete))
            QrPairing.Result.NotPairing -> postSnackbar(ctx.getString(R.string.qr_not_pairing))
        }
    }

    fun onQrScanFailed() {
        postSnackbar(getApplication<Application>().getString(R.string.qr_scan_failed))
    }

    fun consumeSnackbar() {
        _snackbar.value = null
    }

    // ---- helpers -------------------------------------------------------

    private fun pushPaired() {
        val ctx = getApplication<Application>()
        background.execute { pushNow(ctx) }
    }

    /** The push itself: `serviceStateJson` may generate the identity (keygen). */
    private fun pushNow(ctx: Application) {
        runCatching { Prefs.pushState(ctx, push) }
    }

    private fun postSnackbar(message: String) {
        _snackbar.value = message
    }

    private fun isInstalled(ctx: Application, pkg: String): Boolean =
        runCatching { ctx.packageManager.getApplicationInfo(pkg, 0) }.isSuccess

    @Suppress("DEPRECATION")
    private fun wifiName(ctx: Application): String? {
        val wifi = ctx.applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager ?: return null
        val ssid = runCatching { wifi.connectionInfo?.ssid }.getOrNull()?.trim('"') ?: return null
        if (ssid.isBlank() || ssid == WifiManager.UNKNOWN_SSID) return null
        return ssid
    }

    companion object {
        const val REQUEST_SHIZUKU = 4001
        const val SHIZUKU_PACKAGE = "moe.shizuku.privileged.api"
        private const val FORGET_UNDO_MS = 4_000L
        private const val TAG = "ContiguaVm"
    }
}
