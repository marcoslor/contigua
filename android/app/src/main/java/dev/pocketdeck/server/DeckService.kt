package dev.pocketdeck.server

import android.app.KeyguardManager
import android.app.PendingIntent
import android.content.Context
import android.net.ssl.SSLSockets
import android.os.Build
import android.os.IBinder
import android.os.ParcelFileDescriptor
import android.os.SystemClock
import android.util.Log
import dev.pocketdeck.IDeckCallback
import dev.pocketdeck.IDeckService
import dev.pocketdeck.drop.ShareStaging
import dev.pocketdeck.proto.Crypto
import dev.pocketdeck.e2ee.IdentityPin
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
    DeckCallback,
    ClipImageHost {

    /** Shizuku may construct the service either with a Context or with nothing. */
    constructor() : this(null)

    @Volatile private var callback: IDeckCallback? = null

    /** The staged names a pending SEND may still open (SHARE-17). */
    private val staging = ShareStaging(log = ::log)

    /** Mac -> phone clipboard images: the app owns the provider and the clip. */
    private val clipBridge = ClipImageBridge(
        callback = {
            callback?.let { cb ->
                ClipImageBridge.ClipImageCallback { id, mime, data -> cb.onClipImage(id, mime, data) }
            }
        },
        scratch = {
            appContext?.let {
                File(DropPolicy.STORAGE_ROOT, "Android/media/${it.applicationInfo.packageName}/clip")
            }
        },
        log = ::log,
    )
    @Volatile private var deviceId: String = ""
    @Volatile private var deviceName: String = "Android"

    /**
     * What the app process currently vouches for: its TLS identity and the Macs
     * it trusts (never written, never logged). Unlinked — nothing served — until
     * the first push, and again the moment the app's binder dies. The app owns
     * both values; the shell service outlives an app whose data was cleared,
     * which is the bug this state machine closes (docs/design/e2ee.md §10).
     */
    @Volatile private var link: AppLink.State = AppLink.State.Unlinked

    @Volatile private var appBinder: IBinder? = null

    /**
     * Clear data kills the app process, and uninstall removes it: in both the
     * app's binder dies. That notification is immediate and needs no broadcast
     * permission, so it works on API 30–36 (see docs/design/e2ee.md §10).
     */
    private val appDeath = object : IBinder.DeathRecipient {
        override fun binderDied() {
            log("app binder died")
            appBinder = null
            callback = null
            apply(AppLink.Event.AppGone)
        }
    }

    /** The scanned QR the app handed over (R2); null when none or expired.
     * Never logged: the secret is HMAC fodder only. */
    @Volatile var pendingQr: Map<String, Any?>? = null

    @Volatile private var server: Server? = null
    @Volatile private var power: AndroidPower? = null

    /**
     * The phone's notification-listener grant, as the app last reported it
     * (via `listenerAccess`, pushed whenever it changes).
     */
    @Volatile private var listenerAccessStore = false

    /**
     * The app's connection gates (pushed via setGates). Null until the app
     * delivers them, which refuses every Mac: the server never assumes the
     * permissive defaults on its own.
     */
    @Volatile private var gates: GateSettings? = null

    /** Last battery reading relayed by the app process (this process cannot receive it). */
    @Volatile private var batteryPercent = 0
    @Volatile private var batteryCharging = false

    /** The phone's DND, shared by every session (docs/design/focus.md). */
    private var zen: ZenControl? = null

    /** The phone's ringer mode, read for the first `state` of every session. */
    private var ringer: RingerControl? = null

    /** STREAM_MUSIC's level, shared by every session (docs/PROTOCOL.md "Volume"). */
    private var volume: VolumeControl? = null

    /** The live state watcher of the current session, if any. */
    @Volatile private var stateWatcher: AndroidDeviceState? = null

    override fun destroy() {
        log("destroy")
        appBinder?.let { runCatching { it.unlinkToDeath(appDeath, 0) } }
        appBinder = null
        runCatching { power?.shutdown() }
        runCatching { stopServer() }
        staging.close()
        clipBridge.close()
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
        val clip = ShellClipboard(shell, ::log, helper = ClipHelper(shell, ::log))
        val injector = AndroidInjector(::log, clipboard = clip)
        val launcher = AndroidLauncher(shell, ::log)
        val power = AndroidPower(base, ::log)
        this.power = power
        // One zen memory for the whole service: a session ending must not make
        // PocketDeck forget that it owns the phone's DND.
        val zenControl = ZenControl(AndroidZenSettings(base, ::log), ShellZenSetter(::log), ::log)
        zen = zenControl
        // One ringer reader for the whole service. The DND check inside it is a
        // second gate: a ringer change while DND is on could end that DND.
        val ringerControl = RingerControl(
            AndroidRingerSettings(base, ::log),
            ShellRingerSetter(::log),
            { zenControl.current() },
            ::log,
        )
        ringer = ringerControl
        // One volume reader for the whole service: the Mac's slider and the
        // state stream must name the same stream (STREAM_MUSIC) at all times.
        val volumeControl = VolumeControl(AndroidVolumeSettings(base, ::log), ::log)
        volume = volumeControl
        val titles = AndroidWindowObserver(shell, ::log)
        val uids = AppUids(base, ::log)
        val audio = AudioCapture(shell, ::log, uids::uidOf)
        val taskMove = AndroidTaskMove(shell, ::log)

        // One quiet window per server process, shared by every session: a
        // reconnect must not reset it (review M-1).
        val pairCooldown = PairCooldown()
        val factory = SessionFactory { socket, plain, hello ->
            Session(
                socket = socket,
                plainSocket = plain,
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
                clipImageHost = this,
                packages = ShellPackages(shell, ::log),
                taskMove = taskMove,
                taskEvents = AndroidTaskStackEvents(::log),
                dropLanding = ShellLanding(appContext, staging, ::log),
                // The shared storage root. Environment.getExternalStorageDirectory()
                // asks StorageManager, which refuses a caller that is not the
                // app's own uid; the shell service is uid 2000. This is the real
                // path of /sdcard (docs/design/files.md §4).
                filesRoot = File(DropPolicy.STORAGE_ROOT),
                fsStats = AndroidFsStats,
                fsPlatform = AndroidFsPlatform(appContext, ::log),
                fsWatch = AndroidFsWatchSource(appContext, ::log),
                fsThumb = AndroidThumbSource(),
                now = { SystemClock.uptimeMillis() },
                log = ::log,
                // Read when this session starts, never cached: the property can
                // be set or cleared between connections (review I-1).
                autoApprovePairing = DebugFlags.autoApprovePairing(),
                pairCooldown = pairCooldown,
                selfCertProvider = ::servedCertPem,
                pendingQrProvider = { pendingQr },
                pendingQrConsumer = { pendingQr = null },
                gateProvider = { gates },
                audioCapture = audio,
                notifyAccess = { listenerAccessStore },
                notifyGrant = { runListenerGrant() },
                // The gate's answer for the app: the bridge's push gate and the
                // home's attention item both read it (DeckState relay).
                notifyState = { forward, reason ->
                    sendToApp { it.onNotifyState(forward, reason) }
                },
                mediaCommand = { command -> sendToApp { it.onMediaCommand(command) } },
                mediaChoose = { key -> sendToApp { it.onMediaChoose(key) } },
                notifyOpen = { id, displayId -> sendToApp { it.onNotifyOpen(id, displayId) } },
                notifyAction = { id, index, text -> sendToApp { it.onNotifyAction(id, index, text) } },
                notifyDismiss = { id -> sendToApp { it.onNotifyDismiss(id) } },
                // phone.ring: the app process shows the alarm over the lock
                // screen (the shell service has no UI and no audio device).
                ringer = object : Ringer {
                    override fun start(seconds: Int) = sendToApp { it.onRing(seconds) }
                    override fun stop() = sendToApp { it.onRingStop() }
                },
                zen = zenControl,
                ringerMode = ringerControl,
                volume = volumeControl,
                secureProbe = AndroidSecureProbe(base, ::log),
                preReadHello = hello,
                tlsView = Session.TlsView.from(socket).also { view ->
                    // K4/e2e evidence, debug builds only: the platform stack
                    // really backs the v2 pairing (isSupportedSocket gates the
                    // exporter). R5: the exporter's hash never goes to a log,
                    // not even a prefix; only its state does. Release builds
                    // log neither line.
                    if (dev.pocketdeck.BuildConfig.DEBUG) {
                        if (socket is SSLSocket) log("v2 ssl socket supported: ${SSLSockets.isSupportedSocket(socket)}")
                        log(if (view.exporter() == null) "v2 exporter unavailable" else "v2 exporter ready")
                    }
                },
            )
        }
        val srv = Server(factory, ::log, ::servedCertPem, ::servedKeyP8, { gates },
            { servedClients().map { it.macFpHex } },
            onVersionRefused = { v -> onVersionRefused(v) })
        server = srv
        return srv.start()
    }

    @Synchronized
    override fun stopServer() {
        server?.stop()
        server = null
        staging.clear()
    }

    /**
     * The trampoline's read side (SHARE-17): an fd for a bare name the shell
     * staged for a pending SEND, or null. The app cannot open the staged path
     * itself (boot 5); the fd crosses the binder so only the shell touches it.
     */
    override fun openStaged(name: String?): ParcelFileDescriptor? =
        name?.let { staging.open(it) }

    override fun offer(id: Int, mime: String, bytes: ByteArray, done: (Boolean) -> Unit) =
        clipBridge.offer(id.toString(), mime, bytes, done)

    override fun clipImageDone(id: String?, ok: Boolean) {
        id?.let { clipBridge.answer(it, ok) }
    }

    override fun setCallback(cb: IDeckCallback?) {
        val previous = appBinder
        callback = cb
        appBinder = null
        if (previous != null) runCatching { previous.unlinkToDeath(appDeath, 0) }
        if (cb == null) return
        val binder = cb.asBinder()
        val watching = runCatching { binder.linkToDeath(appDeath, 0) }.isSuccess
        if (!watching) {
            // No death notification means the app could outlive the state it
            // vouched for: fail closed instead of serving blind.
            log("app binder death watch refused; not serving")
            callback = null
            apply(AppLink.Event.AppGone)
            return
        }
        appBinder = binder
    }

    /**
     * The app's identity and paired Macs on every bind and every change. The
     * declared fingerprint is trusted only when it matches the certificate it
     * arrived with; a push with no usable identity is the app being gone.
     */
    override fun setPairedClients(json: String) {
        val obj = runCatching { Json.parseObject(json) }.getOrNull() ?: return
        Json.str(obj["deviceId"])?.let { if (it.isNotEmpty()) deviceId = it }
        Json.str(obj["deviceName"])?.let { if (it.isNotEmpty()) deviceName = it }
        val self = Json.asObject(obj["self"])
        val certPem = self?.let { Json.str(it["certPem"]) }.orEmpty()
        val keyP8 = self?.let { Json.str(it["keyP8"]) }.orEmpty()
        val declared = Json.str(obj["identityFp"]).orEmpty()
        val fingerprint = IdentityPin.verified(declared, certPem)
        pendingQr = Json.asObject(obj["pendingQr"])
        val list = Json.asList(obj["clients"]).orEmpty().mapNotNull { entry ->
            val m = Json.asObject(entry) ?: return@mapNotNull null
            val id = Json.str(m["clientId"]) ?: return@mapNotNull null
            val pin = Json.str(m["macFp"]) ?: return@mapNotNull null
            // v1 clients carry a shared key; without a 32-byte pin they are v1
            // leftovers, refused here (the §7 forced re-pair).
            if (pin.length != 64) {
                log("skipping client without a v2 pin")
                return@mapNotNull null
            }
            PairedClient(id, Json.str(m["name"]) ?: "Mac", pin.lowercase())
        }
        apply(AppLink.Event.AppPushed(fingerprint, certPem, keyP8, list))
        log("paired clients: ${list.size}, device=$deviceId, self=${fingerprint.isNotEmpty()}")
    }

    /** The current state, for the log/`status`; never key material. */
    private fun servedCertPem(): String = (link as? AppLink.State.Linked)?.certPem.orEmpty()

    private fun servedKeyP8(): String = (link as? AppLink.State.Linked)?.keyP8.orEmpty()

    private fun servedClients(): List<PairedClient> =
        (link as? AppLink.State.Linked)?.pairs.orEmpty()

    /**
     * Runs one transition of the app-link machine and its returned actions.
     * Never touches the network or the session directly: the machine decides,
     * this applies.
     */
    private fun apply(event: AppLink.Event) {
        val before = link
        val transition = AppLink.transition(before, event)
        link = transition.state
        log(
            "app link: ${AppLink.describe(before)} --${AppLink.describe(event)}--> " +
                AppLink.describe(transition.state),
        )
        transition.actions.forEach { action ->
            when (action) {
                is AppLink.Action.NOTIFY_FORGOTTEN -> server?.notifyForgotten(action.macClientIds)
                AppLink.Action.DROP_SESSIONS -> server?.dropSessions()
                AppLink.Action.FORGET_CACHE -> server?.forgetCachedIdentity()
            }
        }
    }

    override fun respondPairing(requestId: String, allow: Boolean) {
        server?.respondPairing(requestId, allow)
    }

    override fun status(): String {
        val srv = server
        return "uid=${android.system.Os.getuid()} pid=${android.system.Os.getpid()} " +
            "port=${srv?.port ?: -1} clients=${servedClients().size} " +
            "link=${AppLink.describe(link)} ctx=${appContext != null}"
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

    /**
     * The app's notification-listener grant. It is the phone-side half of the
     * gate (the Mac's `notify.enable` is the person-facing switch); a grant
     * that arrives after a failed attempt turns forwarding on by itself.
     */
    override fun listenerAccess(granted: Boolean) {
        listenerAccessStore = granted
        server?.listenerAccess(granted)
    }

    /**
     * The app listener's event push (notifications + the media session). Text is
     * never logged; the session validates and forwards.
     */
    override fun pushDeviceEvent(json: String?) {
        if (json.isNullOrEmpty()) return
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

    /**
     * `cmd notification allow_listener` at shell UID (docs/design/notify.md):
     * the phone's one attempt to honour the Mac's opt-in by itself.
     */
    private fun runListenerGrant(): Boolean {
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

    override fun snapshot(): List<PairedClient> = servedClients()

    override fun add(client: PairedClient) = apply(AppLink.Event.PhonePaired(client))

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
        val level = volume?.read()
        return DeviceState(
            locked = isLocked(),
            battery = batteryPercent,
            charging = batteryCharging,
            dnd = zen?.current(),
            ringer = ringer?.current(),
            screen = ScreenState.read(appContext),
            volume = level?.first,
            volumeMax = level?.second,
        )
    }

    /** Event-driven updates; null when the service has no context to register with. */
    override fun subscribeState(onChange: (DeviceState) -> Unit): AutoCloseable? {
        val base = appContext ?: return null
        val watcher = AndroidDeviceState(base, { batteryPercent to batteryCharging }, ::log)
        stateWatcher = watcher
        // Every state build reads zen_mode: the state the person sees always
        // names the DND as it is at that moment.
        return runCatching {
            watcher.start { state ->
                val level = volume?.read()
                onChange(state.copy(
                    dnd = zen?.current(),
                    ringer = ringer?.current(),
                    volume = level?.first,
                    volumeMax = level?.second,
                ))
            }
        }
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

    override fun onSessionChanged(connected: Boolean, clientId: String?, macName: String?, windows: Int) =
        sendToApp { it.onSessionChanged(connected, clientId, macName, windows) }

    /** R-8/D-4: a refused hello's version reaches the app's status card. */
    override fun onVersionRefused(macV: Int?) =
        sendToApp { it.onVersionRefused(macV ?: -1) }

    /** WIN-66: the app owns the private ring of no-frame episodes. */
    override fun onNoFrameEpisode(episode: Int, json: String) =
        sendToApp { it.onNoFrameEpisode(episode, json) }

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
