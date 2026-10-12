package dev.pocketdeck.server

import android.app.KeyguardManager
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.BatteryManager
import android.os.Build
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

    override fun destroy() {
        log("destroy")
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
                now = { SystemClock.uptimeMillis() },
                log = ::log,
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

    override fun state(): DeviceState {
        val (battery, charging) = battery()
        return DeviceState(isLocked(), battery, charging)
    }

    // ---- DeckCallback (to the app process) ----------------------------

    override fun onPairingRequest(requestId: String, macName: String, code: String) =
        sendToApp { it.onPairingRequest(requestId, macName, code) }

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
        (appContext?.getSystemService(Context.KEYGUARD_SERVICE) as? KeyguardManager)?.isKeyguardLocked ?: false
    }.getOrDefault(false)

    private fun battery(): Pair<Int, Boolean> {
        val ctx = appContext ?: return 0 to false
        val intent = runCatching { ctx.registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED)) }.getOrNull()
            ?: return 0 to false
        val level = intent.getIntExtra(BatteryManager.EXTRA_LEVEL, -1)
        val scale = intent.getIntExtra(BatteryManager.EXTRA_SCALE, -1)
        val percent = if (level >= 0 && scale > 0) level * 100 / scale else 0
        val status = intent.getIntExtra(BatteryManager.EXTRA_STATUS, -1)
        val charging = status == BatteryManager.BATTERY_STATUS_CHARGING || status == BatteryManager.BATTERY_STATUS_FULL
        return percent to charging
    }

    private fun log(message: String) {
        Log.i(TAG, message)
    }

    private companion object {
        const val TAG = "PocketDeckSvc"
    }
}
