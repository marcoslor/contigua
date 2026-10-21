package dev.pocketdeck.app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.os.Build
import android.os.IBinder
import android.util.Log
import androidx.core.app.NotificationCompat
import dev.pocketdeck.IDeckCallback
import dev.pocketdeck.IDeckService
import dev.pocketdeck.R
import rikka.shizuku.Shizuku

/**
 * Keeps the deck reachable: binds the shell user service, starts the TCP server,
 * advertises it over mDNS and relays pairing prompts to the user. Low-importance
 * ongoing notification; START_STICKY so it survives being killed.
 */
class DeckForegroundService : Service() {

    /**
     * AIDL callbacks arrive on a binder thread; a separate stub object keeps
     * [Service] and the Binder base class from colliding.
     */
    private val callback: IDeckCallback = object : IDeckCallback.Stub() {
        override fun onPairingRequest(requestId: String, macName: String, code: String) =
            handlePairingRequest(requestId, macName, code)

        override fun onPairingEnded(requestId: String) = handlePairingEnded(requestId)

        override fun onPaired(clientId: String, name: String, macFp: String) =
            handlePaired(clientId, name, macFp)

        override fun onSessionChanged(connected: Boolean, clientId: String?, macName: String?, windows: Int) =
            handleSessionChanged(connected, clientId, macName, windows)

        override fun onNotifySession(forwarding: Boolean) {
            DeckState.notifyForward = forwarding
            DeckState.notifyChanged()
        }

        override fun onMediaCommand(json: String?) {
            val command = json ?: return
            PdNotificationBridge.mediaSink?.invoke(command)
        }

        override fun onMediaChoose(key: String?) {
            PdNotificationBridge.chooseSink?.invoke(key ?: return)
        }

        override fun onRing(seconds: Int) {
            RingController.start(this@DeckForegroundService, seconds)
        }

        override fun onRingStop() {
            RingController.stop(this@DeckForegroundService)
        }

        override fun onNotifyOpen(id: String?, displayId: Int) {
            val key = id ?: return
            // An id the listener did not keep is answered with a null intent so
            // the server can log `notify.open unknown id` (no text).
            val intent = NotifyIntents.get(key)?.contentIntent
            ShizukuClient.current()?.openNotification(key, displayId, intent)
        }

        override fun onNotifyAction(id: String?, index: Int, text: String?) {
            PdNotificationBridge.actionSink?.invoke(id ?: return, index, text)
        }

        override fun onNotifyDismiss(id: String?) {
            PdNotificationBridge.dismissSink?.invoke(id ?: return)
        }
    }

    private val nsd by lazy { NsdAdvertiser(this) }
    private var serviceReady = false
    private val clientListener: (IDeckService?) -> Unit = { svc ->
        if (svc != null) onServiceReady(svc) else onServiceLost()
    }

    override fun onCreate() {
        super.onCreate()
        DeckState.serviceRunning = true
        createChannels()
        DeckState.enabled = Prefs.isEnabled(this)
        DeckState.paired = Prefs.paired(this)
        updateShizukuState()
        DeviceStateRelay.start(this)
        ShizukuClient.addListener(clientListener)
        ShizukuClient.ensureBound(this)
        startForeground(NOTIF_ONGOING, ongoingNotification("Starting…"))
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_ALLOW -> respondPairing(intent.getStringExtra(EXTRA_REQUEST_ID), true)
            ACTION_DENY -> respondPairing(intent.getStringExtra(EXTRA_REQUEST_ID), false)
            ACTION_FORGET -> intent.getStringExtra(EXTRA_CLIENT_ID)?.let { forget(it) }
            ACTION_GATES -> {
                pushGates()
                updateAdvertising()
            }
            else -> {
                updateShizukuState()
                ShizukuClient.ensureBound(this)
            }
        }
        // With the background switch off the service lives with the task, so
        // the system must not bring it back on its own after a kill.
        return if (Prefs.isEnabled(this)) START_STICKY else START_NOT_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    /**
     * The person swiped PocketDeck away from Recents. With the switch on the
     * deck keeps serving; with it off this is the stop the switch promises.
     */
    override fun onTaskRemoved(rootIntent: Intent?) {
        if (!Prefs.isEnabled(this)) stopServing()
        super.onTaskRemoved(rootIntent)
    }

    override fun onDestroy() {
        DeckState.serviceRunning = false
        ShizukuClient.removeListener(clientListener)
        nsd.stop()
        super.onDestroy()
    }

    /** Close the listening socket before the service goes away, not just the UI. */
    private fun stopServing() {
        runCatching { ShizukuClient.current()?.stopServer() }
        runCatching { nsd.stop() }
        stopSelf()
    }

    // ------------------------------------------------------------------

    private fun onServiceReady(svc: IDeckService) {
        try {
            svc.setCallback(callback)
            svc.setPairedClients(Prefs.serviceStateJson(this))
            // Before startServer: a server that has not received the gates
            // refuses everything, so this order has no permissive window.
            // A daemon too old to know setGates cannot be gated: stop it
            // instead of letting it serve (fail closed).
            try {
                svc.setGates(Prefs.isAllowConnections(this), Prefs.isAllowPairings(this))
            } catch (e: Throwable) {
                Log.i(TAG, "setGates unavailable; stopping the un-gated server: ${e.message}")
                runCatching { svc.stopServer() }
                serviceReady = false
                DeckState.port = -1
                nsd.stop()
                updateOngoing()
                return
            }
            val port = svc.startServer()
            DeckState.port = port
            serviceReady = true
            updateShizukuState()
            updateAdvertising()
            updateOngoing()
            // The shell process cannot read the battery itself: hand it the last
            // reading (and the keyguard state) as soon as it is reachable.
            DeviceStateRelay.push(svc)
            DeviceStateRelay.pushLocked(svc)
            // The notify toggle also lives only in the app: hand it over so the
            // session can answer `notify.state` without a round trip.
            syncNotifyShared()
        } catch (e: Throwable) {
            Log.i(TAG, "startServer failed: ${e.message}")
        }
    }

    private fun syncNotifyShared() {
        ShizukuClient.current()?.let { svc ->
            runCatching { svc.setNotifyShared(Prefs.isNotifyShared(this)) }
        }
    }

    private fun onServiceLost() {
        serviceReady = false
        DeckState.port = -1
        DeckState.connectedMac = null
        DeckState.connectedClientId = null
        nsd.stop()
        updateOngoing()
        DeckState.notifyChanged()
    }

    private fun advertise(port: Int) {
        if (port <= 0) return
        nsd.advertise(port, Prefs.deviceId(this), Prefs.deviceName(this), Build.MODEL ?: "Android")
    }

    /**
     * While "Allow connections" is off the phone is not advertised at all
     * (docs/PROTOCOL.md "Transport"): less exposure, and no Mac caches an
     * address that only answers with a refusal.
     */
    private fun updateAdvertising() {
        if (!Prefs.isAllowConnections(this)) {
            nsd.stop()
            return
        }
        if (DeckState.port > 0) advertise(DeckState.port)
    }

    private fun pushGates() {
        val svc = ShizukuClient.current() ?: return
        runCatching { svc.setGates(Prefs.isAllowConnections(this), Prefs.isAllowPairings(this)) }
    }

    fun respondPairing(requestId: String?, allow: Boolean) {
        if (requestId != null) {
            runCatching { ShizukuClient.current()?.respondPairing(requestId, allow) }
        }
        DeckState.pending = null
        getSystemService(NotificationManager::class.java).cancel(NOTIF_PAIRING)
        DeckState.notifyChanged()
    }

    fun forget(clientId: String) {
        Prefs.forget(this, clientId)
        DeckState.paired = Prefs.paired(this)
        runCatching { ShizukuClient.current()?.setPairedClients(Prefs.serviceStateJson(this)) }
        DeckState.notifyChanged()
    }

    private fun updateShizukuState() {
        DeckState.shizukuRunning = Shizuku.pingBinder()
        DeckState.shizukuGranted = runCatching {
            Shizuku.checkSelfPermission() == android.content.pm.PackageManager.PERMISSION_GRANTED
        }.getOrDefault(false)
    }

    // ---- IDeckCallback ------------------------------------------------

    private fun handlePairingRequest(requestId: String, macName: String, code: String) {
        DeckState.pending = DeckState.PendingPairing(requestId, macName, code)
        DeckState.notifyChanged()
        showPairingNotification(requestId, macName, code)
    }

    private fun handlePairingEnded(requestId: String) {
        if (DeckState.pending?.requestId != requestId) return
        DeckState.pending = null
        getSystemService(NotificationManager::class.java).cancel(NOTIF_PAIRING)
        DeckState.notifyChanged()
    }

    private fun handlePaired(clientId: String, name: String, macFp: String) {
        Prefs.addPaired(this, Prefs.PairedMac(clientId, name, macFp, System.currentTimeMillis()))
        // A QR scan that landed in a pairing is consumed: drop the one-time secret.
        Prefs.clearPendingQr(this)
        DeckState.paired = Prefs.paired(this)
        DeckState.pending = null
        getSystemService(NotificationManager::class.java).cancel(NOTIF_PAIRING)
        runCatching { ShizukuClient.current()?.setPairedClients(Prefs.serviceStateJson(this)) }
        DeckState.notifyChanged()
    }

    private fun handleSessionChanged(connected: Boolean, clientId: String?, macName: String?, windows: Int) {
        // Both ends of a session are "last connected": a row that comes back
        // must not keep an older time until the next pairing.
        if (clientId != null) {
            Prefs.touchLastConnected(this, clientId, System.currentTimeMillis())
            DeckState.paired = Prefs.paired(this)
        }
        DeckState.connectedMac = if (connected) macName else null
        DeckState.connectedClientId = if (connected) clientId else null
        DeckState.windows = windows
        updateOngoing()
        DeckState.notifyChanged()
    }

    // ---- notifications ------------------------------------------------

    private fun createChannels() {
        val nm = getSystemService(NotificationManager::class.java)
        nm.createNotificationChannel(
            NotificationChannel(CHANNEL_ONGOING, getString(R.string.channel_ongoing), NotificationManager.IMPORTANCE_LOW),
        )
        nm.createNotificationChannel(
            NotificationChannel(CHANNEL_PAIRING, getString(R.string.channel_pairing), NotificationManager.IMPORTANCE_HIGH),
        )
    }

    private fun ongoingNotification(text: String): Notification =
        NotificationCompat.Builder(this, CHANNEL_ONGOING)
            .setSmallIcon(R.drawable.ic_deck)
            .setContentTitle(getString(R.string.app_name))
            .setContentText(text)
            .setContentIntent(mainIntent())
            .setOngoing(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .build()

    private fun updateOngoing() {
        val text = when {
            DeckState.connectedMac != null -> getString(R.string.notif_connected, DeckState.connectedMac, DeckState.windows)
            serviceReady && DeckState.port > 0 -> getString(R.string.notif_listening, DeckState.port)
            else -> getString(R.string.notif_starting)
        }
        getSystemService(NotificationManager::class.java).notify(NOTIF_ONGOING, ongoingNotification(text))
    }

    private fun showPairingNotification(requestId: String, macName: String, code: String) {
        val allow = serviceAction(ACTION_ALLOW, requestId, requestId.hashCode())
        val deny = serviceAction(ACTION_DENY, requestId, requestId.hashCode() + 1)
        val notification = NotificationCompat.Builder(this, CHANNEL_PAIRING)
            .setSmallIcon(R.drawable.ic_deck)
            .setContentTitle(getString(R.string.pairing_title, macName))
            .setContentText(getString(R.string.pairing_text, formatPairingCode(code)))
            .setStyle(
                NotificationCompat.BigTextStyle()
                    .bigText(getString(R.string.pairing_text, formatPairingCode(code))),
            )
            .setContentIntent(mainIntent())
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setCategory(NotificationCompat.CATEGORY_STATUS)
            .setOnlyAlertOnce(true)
            .setTimeoutAfter(PAIRING_TIMEOUT_MS)
            .setAutoCancel(true)
            .addAction(0, getString(R.string.allow), allow)
            .addAction(0, getString(R.string.deny), deny)
            .build()
        getSystemService(NotificationManager::class.java).notify(NOTIF_PAIRING, notification)
    }

    private fun serviceAction(action: String, requestId: String, requestCode: Int): PendingIntent {
        val intent = Intent(this, DeckForegroundService::class.java)
            .setAction(action)
            .putExtra(EXTRA_REQUEST_ID, requestId)
        return PendingIntent.getService(this, requestCode, intent, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
    }

    private fun mainIntent(): PendingIntent {
        val intent = Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        return PendingIntent.getActivity(this, 0, intent, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
    }

    companion object {
        private const val TAG = "PocketDeckApp"
        private const val CHANNEL_ONGOING = "deck"
        private const val CHANNEL_PAIRING = "pairing"
        private const val NOTIF_ONGOING = 1
        private const val NOTIF_PAIRING = 2

        /** The prompt stops being answerable after two minutes (docs/DESIGN.md §2). */
        private const val PAIRING_TIMEOUT_MS = 120_000L

        const val ACTION_ALLOW = "dev.pocketdeck.action.ALLOW"
        const val ACTION_DENY = "dev.pocketdeck.action.DENY"
        const val ACTION_FORGET = "dev.pocketdeck.action.FORGET"
        const val ACTION_GATES = "dev.pocketdeck.action.GATES"
        const val EXTRA_REQUEST_ID = "request_id"
        const val EXTRA_CLIENT_ID = "client_id"

        fun start(context: android.content.Context) {
            val intent = Intent(context, DeckForegroundService::class.java)
            context.startForegroundService(intent)
        }

        /** A gate changed: push it to the server and fix the advertisement. */
        fun gatesChanged(context: android.content.Context) {
            // Never start a stopped service just to re-advertise; the next
            // start pushes the stored values before it listens. The background
            // switch is not the question here: an open task keeps it running.
            if (!DeckState.serviceRunning) return
            val intent = Intent(context, DeckForegroundService::class.java).setAction(ACTION_GATES)
            runCatching { context.startService(intent) }
        }
    }
}
