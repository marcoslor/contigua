package app.contigua.app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.os.Build
import android.os.IBinder
import android.os.ParcelFileDescriptor
import android.util.Log
import androidx.core.app.NotificationCompat
import app.contigua.IDeckCallback
import app.contigua.IDeckService
import app.contigua.R
import app.contigua.e2ee.IdentityPin
import app.contigua.e2ee.PhoneIdentity
import app.contigua.server.failureClasses
import java.util.concurrent.Executors

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

        override fun onVersionRefused(macV: Int) {
            // R-8/D-4: the status card shows the sentence until a session succeeds.
            DeckState.versionSentence = app.contigua.proto.PathVersion.phoneSentence(
                if (macV < 0) null else macV,
            )
            DeckState.notifyChanged()
        }

        override fun onNotifyState(forwarding: Boolean, reason: String?) {
            DeckState.notifyForward = forwarding
            DeckState.notifyNoAccess = reason == "no_access"
            DeckState.notifyChanged()
            // Every answered enable while forwarding is an active-set request
            // (NOTIFY-1/PATH-6): one resend, even when the gate did not move.
            if (forwarding) PdNotificationBridge.resyncSink?.invoke()
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

        /**
         * A Mac clipboard image (SHARE-2/16). The app owns the provider, so it
         * copies the pipe into `cacheDir/clip`, sets A2's URI-only item and
         * answers the shell; the copy runs off the binder thread.
         */
        override fun onClipImage(id: String?, mime: String?, data: ParcelFileDescriptor?) {
            val key = id
            if (key == null) {
                runCatching { data?.close() }
                return
            }
            val type = mime
            val descriptor = data
            if (type == null || descriptor == null) {
                runCatching { descriptor?.close() }
                answerClip(key, false)
                return
            }
            try {
                clipWriter.execute {
                    val ok = runCatching {
                        ParcelFileDescriptor.AutoCloseInputStream(descriptor).use {
                            ClipImageWriter.write(this@DeckForegroundService, type, it)
                        }
                    }.onFailure {
                        Log.i(TAG, "clip image: ${failureClasses(it)}")  // log-ok: class names only
                    }.getOrDefault(false)
                    answerClip(key, ok)
                }
            } catch (e: Throwable) {
                Log.i(TAG, "clip image: queue failed: ${failureClasses(e)}")  // log-ok: class names only
                runCatching { descriptor.close() }
                answerClip(key, false)
            }
        }

        /**
         * WIN-66: one no-frame episode for the private ring. The shell builds
         * the line (ids, counts, durations and closed tokens only); the file
         * write is small and runs on the binder thread like the pairing writes.
         */
        override fun onNoFrameEpisode(episode: Int, json: String?) {
            NoFrameStore.record(this@DeckForegroundService, episode, json ?: return)
        }
    }

    /** The app's answer to the shell's `onClipImage` (SHARE-2/16). */
    private fun answerClip(id: String, ok: Boolean) {
        runCatching { ShizukuClient.current()?.clipImageDone(id, ok) }
    }

    private val nsd by lazy { NsdAdvertiser(this) }
    private val clipWriter = Executors.newSingleThreadExecutor { runnable ->
        Thread(runnable, "contigua-clip-write").apply { isDaemon = true }
    }
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
        // Bind now and keep listening: Shizuku's server can die and come back
        // while this service runs (PHONE-20), and the machine rebinds by itself.
        ShizukuClient.attach(this)
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
     * The person swiped Contigua away from Recents. With the switch on the
     * deck keeps serving; with it off this is the stop the switch promises.
     */
    override fun onTaskRemoved(rootIntent: Intent?) {
        if (!Prefs.isEnabled(this)) stopServing()
        super.onTaskRemoved(rootIntent)
    }

    override fun onDestroy() {
        DeckState.serviceRunning = false
        ShizukuClient.removeListener(clientListener)
        // Stop listening before the process keeps a binder nobody serves: with
        // the deck off, nothing may be bound (PHONE-7).
        ShizukuClient.detach()
        clipWriter.shutdownNow()
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

    /** The shell service bound: push the app's vouches, then start listening. */
    internal fun onServiceReady(svc: IDeckService) {
        try {
            svc.setCallback(callback)
            // ISS-15: the server starts with the phone's identity, so it has
            // to exist here, in this client callback path, before the push and
            // the start. The app owns it; this is the one generator and store.
            ensureIdentity()
            Prefs.pushState(this) { svc.setPairedClients(it) }
            // Before startServer: a server that has not received the gates
            // refuses everything, so this order has no permissive window.
            // A daemon too old to know setGates cannot be gated: stop it
            // instead of letting it serve (fail closed).
            try {
                svc.setGates(Prefs.isAllowConnections(this), Prefs.isAllowPairings(this))
            } catch (e: Throwable) {
                Log.i(TAG, "setGates unavailable; stopping the un-gated server: ${failureClasses(e)}")  // log-ok: class names only
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
            // The listener grant lives in the system, not the app: hand the
            // current value over so the session can answer `notify.state`.
            syncListenerAccess()
        } catch (e: Throwable) {
            Log.i(TAG, "startServer failed: ${failureClasses(e)}")  // log-ok: class names only
        }
    }

    /**
     * ISS-15: the service start's identity step. A fresh app has no
     * `identity_v2.json`; this makes one before the server can read it from the
     * pushed state, through `PhoneIdentity.ensure` (the same generator and store
     * every other path uses). An existing identity is loaded, never replaced.
     * The log carries a fingerprint prefix, never key material.
     */
    private fun ensureIdentity(): PhoneIdentity.Identity? =
        runCatching { PhoneIdentity.ensure(this) }
            .onSuccess { Log.i(TAG, "identity: ready fp=${IdentityPin.of(it.certPem).orEmpty().take(8)}") } // log-ok: hash prefix only
            .onFailure { Log.i(TAG, "identity: generation failed: ${failureClasses(it)}") } // log-ok: class names only
            .getOrNull()

    private fun syncListenerAccess() {
        val granted = NotifyAccess.isGranted(this)
        ShizukuClient.current()?.let { svc ->
            runCatching { svc.listenerAccess(granted) }
        }
    }

    private fun onServiceLost() {
        serviceReady = false
        DeckState.port = -1
        DeckState.connectedMac = null
        DeckState.connectedClientId = null
        DeckState.versionSentence = null
        updateShizukuState()
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
        runCatching { Prefs.pushState(this) { checkNotNull(ShizukuClient.current()).setPairedClients(it) } }
        DeckState.notifyChanged()
    }

    private fun updateShizukuState() {
        DeckState.shizukuRunning = ShizukuClient.hasBinder()
        // Shizuku keeps the grant across a restart of its server, so a check it
        // cannot answer (no binder, not attached yet) is not a denial: keep the
        // last answer instead of asking the person to allow Contigua again.
        DeckState.shizukuGranted = ShizukuClient.permission() ?: DeckState.shizukuGranted
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
        runCatching { Prefs.pushState(this) { checkNotNull(ShizukuClient.current()).setPairedClients(it) } }
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
        // A live session is the way out of the version card (R-8/D-4).
        if (connected) DeckState.versionSentence = null
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
            DeckState.connectedMac != null -> resources.getQuantityString(
                R.plurals.notif_connected,
                DeckState.windows,
                DeckState.connectedMac,
                DeckState.windows,
            )
            serviceReady && DeckState.port > 0 -> getString(R.string.notif_listening)
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
        private const val TAG = "ContiguaApp"
        private const val CHANNEL_ONGOING = "deck"
        private const val CHANNEL_PAIRING = "pairing"
        private const val NOTIF_ONGOING = 1
        private const val NOTIF_PAIRING = 2

        /** The prompt stops being answerable after two minutes (docs/DESIGN.md §2). */
        private const val PAIRING_TIMEOUT_MS = 120_000L

        const val ACTION_ALLOW = "app.contigua.action.ALLOW"
        const val ACTION_DENY = "app.contigua.action.DENY"
        const val ACTION_FORGET = "app.contigua.action.FORGET"
        const val ACTION_GATES = "app.contigua.action.GATES"
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
