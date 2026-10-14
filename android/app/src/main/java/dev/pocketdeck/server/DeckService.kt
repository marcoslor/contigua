package dev.pocketdeck.server

import android.app.KeyguardManager
import android.content.Context
import android.os.Build
import android.os.ParcelFileDescriptor
import android.os.SystemClock
import android.util.Log
import dev.pocketdeck.IDeckCallback
import dev.pocketdeck.IDeckService
import dev.pocketdeck.proto.Crypto
import dev.pocketdeck.proto.Json

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

    @Volatile private var server: Server? = null
    @Volatile private var power: AndroidPower? = null

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
                clipboard = ShellClipboard(::log),
                packages = ShellPackages(shell, ::log),
                now = { SystemClock.uptimeMillis() },
                log = ::log,
                autoApprovePairing = dev.pocketdeck.BuildConfig.DEBUG,
            )
        }
        val srv = Server(factory, ::log)
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
        val list = Json.asList(obj["clients"]).orEmpty().mapNotNull { entry ->
            val m = Json.asObject(entry) ?: return@mapNotNull null
            val id = Json.str(m["clientId"]) ?: return@mapNotNull null
            val key = Json.str(m["key"]) ?: return@mapNotNull null
            PairedClient(id, Json.str(m["name"]) ?: "Mac", key)
        }
        clients = list
        log("paired clients: ${list.size}, device=$deviceId")
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

    override fun onPaired(clientId: String, name: String, keyHex: String) =
        sendToApp { it.onPaired(clientId, name, keyHex) }

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
