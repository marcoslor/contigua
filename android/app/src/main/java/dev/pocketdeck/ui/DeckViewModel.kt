package dev.pocketdeck.ui

import android.Manifest
import android.app.Application
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.util.Log
import androidx.core.content.ContextCompat
import androidx.lifecycle.AndroidViewModel
import dev.pocketdeck.IDeckService
import dev.pocketdeck.R
import dev.pocketdeck.app.DeckForegroundService
import dev.pocketdeck.app.DeckState
import dev.pocketdeck.app.Prefs
import dev.pocketdeck.app.QrPairing
import dev.pocketdeck.app.ShizukuClient
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import rikka.shizuku.Shizuku

/**
 * The single UI state holder. It observes the foreground service, the Shizuku
 * client and [Prefs], and exposes one [StateFlow]; composables only render and
 * call back into here, never touch Android services directly.
 */
class DeckViewModel(app: Application) : AndroidViewModel(app) {

    private val _state = MutableStateFlow(DeckUiState())
    val state: StateFlow<DeckUiState> = _state.asStateFlow()

    private val _snackbar = MutableStateFlow<String?>(null)
    val snackbar: StateFlow<String?> = _snackbar.asStateFlow()

    private val handler = Handler(Looper.getMainLooper())

    /** Client ids removed from the list but still on disk until Undo expires. */
    private val pendingForgets = LinkedHashMap<String, Runnable>()

    private val deckListener: () -> Unit = { refresh() }

    private val shizukuClientListener: (IDeckService?) -> Unit = { refresh() }

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
        val running = runCatching { Shizuku.pingBinder() }.getOrDefault(false)
        val granted = runCatching {
            Shizuku.checkSelfPermission() == PackageManager.PERMISSION_GRANTED
        }.getOrDefault(false)
        val installed = isInstalled(ctx, SHIZUKU_PACKAGE)
        val notificationsGranted = if (Build.VERSION.SDK_INT >= 33) {
            ContextCompat.checkSelfPermission(ctx, Manifest.permission.POST_NOTIFICATIONS) ==
                PackageManager.PERMISSION_GRANTED
        } else {
            true
        }
        val port = DeckState.port
        val connected = DeckState.connectedMac
        val paired = Prefs.paired(ctx).filterNot { pendingForgets.containsKey(it.clientId) }

        val allowConnections = Prefs.isAllowConnections(ctx)
        _state.value = DeckUiState(
            onboardingDone = Prefs.isOnboardingDone(ctx),
            enabled = enabled,
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
        if (runCatching { Shizuku.pingBinder() }.getOrDefault(false)) {
            runCatching { Shizuku.requestPermission(REQUEST_SHIZUKU) }
        }
        refresh()
    }

    fun onNotificationPermissionResult() = refresh()

    fun ignoreBatteryOptimizations() {
        val ctx = getApplication<Application>()
        Prefs.setBatteryRequested(ctx, true)
        val intent = Intent(
            Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
            Uri.parse("package:${ctx.packageName}"),
        ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        runCatching { ctx.startActivity(intent) }
        refresh()
    }

    // ---- home actions --------------------------------------------------

    fun setEnabled(value: Boolean) {
        val ctx = getApplication<Application>()
        Prefs.setEnabled(ctx, value)
        DeckState.enabled = value
        // Off does not stop the service: it keeps serving while the task is
        // open and stops on its own when the task leaves Recents. On also
        // makes it start at boot and survive that swipe (BootReceiver).
        if (value) DeckForegroundService.start(ctx)
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

            AttentionKind.RETRY -> {
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
                runCatching { ShizukuClient.current()?.setPairedClients(Prefs.serviceStateJson(ctx)) }
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
        runCatching { ShizukuClient.current()?.setPairedClients(Prefs.serviceStateJson(ctx)) }
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
        private const val TAG = "PocketDeckVm"
    }
}
