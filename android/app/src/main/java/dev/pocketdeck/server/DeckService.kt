package dev.pocketdeck.server

import android.app.KeyguardManager
import android.app.PendingIntent
import android.content.Context
import android.net.ssl.SSLSockets
import android.os.Build
import android.os.ParcelFileDescriptor
import android.os.SystemClock
import android.util.Log
import dev.pocketdeck.IDeckCallback
import dev.pocketdeck.IDeckService
import dev.pocketdeck.proto.Crypto
import dev.pocketdeck.e2ee.TlsExporter
import dev.pocketdeck.proto.Json
import java.io.File
import java.util.concurrent.TimeUnit
import javax.net.ssl.SSLSocket

/**
 * The Shizuku user-service entry point. Runs as shell (UID 2000), owns the TCP
 * server and the virtual displays, and talks to the app process over AIDL for
 * the pairing prompt and session state.
 */
class DeckService(private val appContext: Context?) :
    IDeckService.Stub(),
    PairingStore,
    DeviceSource,
    DeckCallback {

    /** Shizuku may construct the service either with a Context or with nothing. */
    constructor() : this(null)

    @Volatile private var callback: IDeckCallback? = null
    @Volatile private var clients: List<PairedClient> = emptyList()
    @Volatile private var deviceId: String = ""
    @Volatile private var deviceName: String = "Android"

    /** v2 in-memory TLS identity pushed from the app (never written, never logged). */
    @Volatile var selfCertPem: String = ""
    @Volatile var selfKeyP8: String = ""

    /** The scanned QR the app handed over (R2); null when none or expired.
     * Never logged: the secret is HMAC fodder only. */
    @Volatile var pendingQr: Map<String, Any?>? = null

    @Volatile private var server: Server? = null
    @Volatile private var power: AndroidPower? = null

    /** Mirror of the app's per-phone notify toggle (pushed via setNotifyShared). */
    @Volatile private var notifySharedStore = false

    /**
     * The app's connection gates (pushed via setGates). Null until the app
     * delivers them, which refuses every Mac: the server never assumes the
     * permissive defaults on its own.
     */
    @Volatile private var gates: GateSettings? = null

    /** Last battery reading relayed by the app process (this process cannot receive it). */
    @Volatile private var batteryPercent = 0
    @Volatile private var batteryCharging = false

    /** The live state watcher of the current session, if any. */
    @Volatile private var stateWatcher: AndroidDeviceState? = null

    override fun destroy() {
        log("destroy")
        runCatching { power?.shutdown() }
        runCatching { stopServer() }
        System.exit(0)
    }

    @Synchronized
    override fun startServer(): Int {
        server?.let { return it.port }
        val base = appContext ?: run {
            log("startServer: no context in service process")
            return -1
        }
        val shell = ShellContext(base)
        val display = AndroidDisplayLayer(shell, ::log)
        val injector = AndroidInjector(::log)
        val launcher = AndroidLauncher(shell, ::log)
        val power = AndroidPower(base, ::log)
        this.power = power
        val titles = AndroidWindowObserver(shell, ::log)
        val uids = AppUids(base, ::log)
        val audio = AudioCapture(shell, ::log, uids::uidOf)
        val taskMove = AndroidTaskMove(shell, ::log)
        val clip = ShellClipboard(shell, ::log)

        // One quiet window per server process, shared by every session: a
        // reconnect must not reset it (review M-1).
        val pairCooldown = PairCooldown()
        val factory = SessionFactory { socket ->
            Session(
                socket = socket,
                display = display,
                catalog = launcher,
                launcher = launcher,
                injector = injector,
                power = power,
                device = this,
                store = this,
                callback = this,
                titleObserver = titles,
                taskPresence = titles,
                clipboard = clip,
                clipImages = clip,
                packages = ShellPackages(shell, ::log),
                taskMove = taskMove,
                dropLanding = ShellLanding(appContext, ::log),
                // The shared storage root. Environment.getExternalStorageDirectory()
                // asks StorageManager, which refuses a caller that is not the
                // app's own uid; the shell service is uid 2000. This is the real
                // path of /sdcard (docs/design/files.md §4).
                filesRoot = File("/storage/emulated/0"),
                fsStats = AndroidFsStats,
                now = { SystemClock.uptimeMillis() },
                log = ::log,
                // Read when this session starts, never cached: the property can
                // be set or cleared between connections (review I-1).
                autoApprovePairing = DebugFlags.autoApprovePairing(),
                pairCooldown = pairCooldown,
                selfCertProvider = { selfCertPem },
                pendingQrProvider = { pendingQr },
                pendingQrConsumer = { pendingQr = null },
                gateProvider = { gates },
                audioCapture = audio,
                notifyShared = { notifySharedStore },
                // The session tells the app when the forwarding gate is open, so
                // the listener's bridge knows when to push (DeckState relay).
                notifyForward = { forward -> sendToApp { it.onNotifySession(forward) } },
                mediaCommand = { action -> sendToApp { it.onMediaCommand(action) } },
                notifyOpen = { id, displayId -> sendToApp { it.onNotifyOpen(id, displayId) } },
                // phone.ring: the app process shows the alarm over the lock
                // screen (the shell service has no UI and no audio device).
                ringer = object : Ringer {
                    override fun start(seconds: Int) = sendToApp { it.onRing(seconds) }
                    override fun stop() = sendToApp { it.onRingStop() }
                },
                tlsView = Session.TlsView.from(socket).also { view ->
                    // K4/e2e evidence, hashes only, debug builds only: the
                    // platform stack really backs the v2 pairing
                    // (isSupportedSocket gates the exporter) and both ends
                    // compare this hash, not the bytes. Release builds log
                    // neither line.
                    if (dev.pocketdeck.BuildConfig.DEBUG) {
                        if (socket is SSLSocket) log("v2 ssl socket supported: ${SSLSockets.isSupportedSocket(socket)}")
                        val exporter = view.exporter()
                        log(if (exporter == null) "v2 exporter unavailable"
                            else "v2 exporter sha256: " + TlsExporter.toHex(TlsExporter.sha256(exporter)))
                    }
                },
            )
        }
        val srv = Server(factory, ::log, { selfCertPem }, { selfKeyP8 }, { gates },
            { clients.map { it.macFpHex } })
        server = srv
        return srv.start()
    }

    @Synchronized
    override fun stopServer() {
        server?.stop()
        server = null
    }

    override fun setCallback(cb: IDeckCallback?) {
        callback = cb
    }

    override fun setPairedClients(json: String) {
        val obj = runCatching { Json.parseObject(json) }.getOrNull() ?: return
        Json.str(obj["deviceId"])?.let { if (it.isNotEmpty()) deviceId = it }
        Json.str(obj["deviceName"])?.let { if (it.isNotEmpty()) deviceName = it }
        val self = Json.asObject(obj["self"])
        if (self != null) {
            Json.str(self["certPem"])?.let { if (it.isNotEmpty()) selfCertPem = it }
            Json.str(self["keyP8"])?.let { if (it.isNotEmpty()) selfKeyP8 = it }
        }
        pendingQr = Json.asObject(obj["pendingQr"])
        val list = Json.asList(obj["clients"]).orEmpty().mapNotNull { entry ->
            val m = Json.asObject(entry) ?: return@mapNotNull null
            val id = Json.str(m["clientId"]) ?: return@mapNotNull null
            val pin = Json.str(m["macFp"]) ?: return@mapNotNull null
            // v1 clients carry a shared key; without a 32-byte pin they are v1
            // leftovers, refsed here (the §7 forced re-pair).
            if (pin.length != 64) {
                log("skipping client without a v2 pin")
                return@mapNotNull null
            }
            PairedClient(id, Json.str(m["name"]) ?: "Mac", pin.lowercase())
        }
        clients = list
        log("paired clients: ${list.size}, device=$deviceId, self=${selfCertPem.isNotEmpty()}")
    }

    override fun respondPairing(requestId: String, allow: Boolean) {
        server?.respondPairing(requestId, allow)
    }

    override fun status(): String {
        val srv = server
        return "uid=${android.system.Os.getuid()} pid=${android.system.Os.getpid()} " +
            "port=${srv?.port ?: -1} clients=${clients.size} ctx=${appContext != null}"
    }

    override fun shareText(text: String?): Int =
        server?.shareText(text ?: "") ?: ShareStatus.NO_SESSION

    override fun shareFile(name: String?, mime: String?, data: ParcelFileDescriptor?): Int {
        val pfd = data ?: return ShareStatus.FAILED
        val srv = server ?: return ShareStatus.NO_SESSION
        return ParcelFileDescriptor.AutoCloseInputStream(pfd).use {
            srv.shareFile(name ?: "image", mime ?: "application/octet-stream", it)
        }
    }

    /**
     * The app's two connection gates. Pushed before `startServer` at every
     * bind, so a fresh server never listens with unknown values; a later push
     * also drops sessions the new values refuse.
     */
    override fun setGates(allowConnections: Boolean, allowPairings: Boolean) {
        gates = GateSettings(allowConnections, allowPairings)
        log("gates: connections=$allowConnections pairings=$allowPairings")
        server?.applyGates()
    }

    /** The app's per-phone opt-in for notification sharing (privacy default OFF). */
    override fun setNotifyShared(shared: Boolean) {
        notifySharedStore = shared
        server?.recomputeNotify()
    }

    /**
     * The app listener's event push (notifications + the media session). Text is
     * never logged; the session validates and forwards.
     */
    override fun pushDeviceEvent(json: String?) {
        if (json.isNullOrEmpty() || notifySharedStore.not()) return
        val obj = runCatching { Json.parseObject(json) }.getOrNull() ?: return
        val t = Json.str(obj["t"]) ?: return
        server?.onDeviceEvent(t, obj)
    }

    /**
     * The app's answer to `onNotifyOpen` (docs/design/notify.md): send the
     * notification's own action on the display the Mac asked for. The shell UID
     * does the send because it owns the virtual display; a null intent means
     * the id is not in the app's map (an unknown id is a no-op).
     */
    override fun openNotification(id: String?, displayId: Int, intent: PendingIntent?) {
        if (intent == null) {
            log("notify.open unknown id")
            return
        }
        val base = appContext ?: run {
            log("notify.open fallback reason=no_context")
            return
        }
        val reason = NotifyOpen.send(base, intent, displayId)
        if (reason != null) {
            log("notify.open fallback reason=$reason")
        } else {
            log("notify.open sent on display $displayId")
        }
    }

    /** `cmd notification allow_listener` at shell UID (docs/design/notify.md). */
    override fun grantListenerAccess(): Boolean {
        val component = "${dev.pocketdeck.BuildConfig.APPLICATION_ID}/dev.pocketdeck.app.PdNotificationListener"
        run("cmd", "notification", "allow_listener", component)
        // The grant command is silent and the settings write can lag a moment
        // behind it (seen on API 36); poll briefly -- the listener list is the
        // truth, but the first read right after the command may be stale.
        var granted = false
        for (attempt in 1..15) {
            granted = run("settings", "get", "secure", "enabled_notification_listeners")
                .contains(component)
            if (granted) break
            Thread.sleep(200)
        }
        log("notify: listener grant=$granted component=$component")
        return granted
    }

    /** Runs argv (no shell) and returns its output; "" on any failure. */
    private fun run(vararg argv: String): String = runCatching {
        val process = ProcessBuilder(*argv).redirectErrorStream(true).start()
        val out = process.inputStream.bufferedReader().readText()
        process.waitFor(10, TimeUnit.SECONDS)
        out.trim()
    }.getOrDefault("")

    // ---- PairingStore -------------------------------------------------

    override fun snapshot(): List<PairedClient> = clients

    override fun add(client: PairedClient) {
        if (clients.none { it.clientId == client.clientId }) clients = clients + client
    }

    // ---- DeviceSource -------------------------------------------------

    override fun info(): DeviceInfo {
        if (deviceId.isEmpty()) deviceId = Crypto.toHex(Crypto.randomBytes(8))
        val dm = runCatching { appContext?.resources?.displayMetrics }.getOrNull()
        return DeviceInfo(
            id = deviceId,
            name = deviceName,
            model = Build.MODEL ?: "Android",
            sdk = Build.VERSION.SDK_INT,
            screenW = dm?.widthPixels ?: 0,
            screenH = dm?.heightPixels ?: 0,
            dpi = dm?.densityDpi ?: 0,
            locked = isLocked(),
        )
    }

    override fun state(): DeviceState = DeviceState(isLocked(), batteryPercent, batteryCharging)

    /** Event-driven updates; null when the service has no context to register with. */
    override fun subscribeState(onChange: (DeviceState) -> Unit): AutoCloseable? {
        val base = appContext ?: return null
        val watcher = AndroidDeviceState(base, { batteryPercent to batteryCharging }, ::log)
        stateWatcher = watcher
        return runCatching { watcher.start(onChange) }
            .onFailure { stateWatcher = null }
            .getOrNull()
    }

    /** Battery relay from the app process: cache it and forward to a live session. */
    override fun setBatteryState(percent: Int, charging: Boolean) {
        batteryPercent = percent
        batteryCharging = charging
        stateWatcher?.onBatteryEvent(percent, charging)
    }

    /** Keyguard relay from the app process, used when the shell has no listener. */
    override fun setLockedState(locked: Boolean) {
        stateWatcher?.onLockEvent(locked)
    }

    // ---- DeckCallback (to the app process) ----------------------------

    override fun onPairingRequest(requestId: String, macName: String, code: String) =
        sendToApp { it.onPairingRequest(requestId, macName, code) }

    override fun onPairingEnded(requestId: String) =
        sendToApp { it.onPairingEnded(requestId) }

    override fun onPaired(clientId: String, name: String, macFpHex: String) =
        sendToApp { it.onPaired(clientId, name, macFpHex) }

    override fun onSessionChanged(connected: Boolean, macName: String?, windows: Int) =
        sendToApp { it.onSessionChanged(connected, macName, windows) }

    // ------------------------------------------------------------------

    private inline fun sendToApp(block: (IDeckCallback) -> Unit) {
        val cb = callback ?: return
        runCatching { block(cb) }
    }

    private fun isLocked(): Boolean = runCatching {
        (appContext?.getSystemService(Context.KEYGUARD_SERVICE) as? KeyguardManager)?.isDeviceLocked ?: false
    }.getOrDefault(false)

    private fun log(message: String) {
        Log.i(TAG, message)
    }

    private companion object {
        const val TAG = "PocketDeckSvc"
    }
}
