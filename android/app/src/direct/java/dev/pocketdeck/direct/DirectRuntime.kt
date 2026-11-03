package dev.pocketdeck.direct

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.location.LocationManager
import android.net.wifi.aware.WifiAwareManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.util.Log
import androidx.core.content.ContextCompat
import dev.pocketdeck.IDeckService
import dev.pocketdeck.app.DeckState
import dev.pocketdeck.app.PhoneDirect
import dev.pocketdeck.app.PhoneDirectPort
import dev.pocketdeck.app.Prefs
import dev.pocketdeck.app.ShizukuClient
import dev.pocketdeck.proto.PhoneDirectState
import java.net.Socket

/**
 * The app-process owner of Wi-Fi Aware (docs/design/direct-link.md §4.5,
 * transport DIRECT-1/7/8/17): one `WifiAwareSession`, one publish, one NDP and
 * one listener per active Mac. The shell only ever receives the listener's
 * accepted descriptors (or the bridge's) and plain state values.
 *
 * The machine decides; this object performs its actions on the main thread and
 * reports the resulting state as `direct.state`.
 */
object DirectRuntime : PhoneDirectPort {

    private const val TAG = "PocketDeckDirect"

    private val main = Handler(Looper.getMainLooper())

    private var app: Context? = null
    private var port: PlatformAwarePort? = null
    private var link: AwareLink? = null
    private var keyStore: PrefsDirectKeyStore? = null
    private var keys: DirectKeys? = null
    private var keyHandler: DirectKeyHandler? = null
    private var listener: AwareListener? = null
    private var network: AwareNetwork? = null
    private var activeClient: String? = null
    private var running = false
    private var tick: Runnable? = null
    private var ndpRetry: Runnable? = null
    private var awareStateRegistered = false

    /** DIRECT-14: the platform's own "Aware became unavailable/available" rule. */
    private val awareState = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            val provider = port ?: return
            main.post { feed(AwareLinkEvent.AwareStateChanged(provider.available())) }
        }
    }

    private val onDeckState: () -> Unit = { main.post { refresh() } }

    private val handoff: DirectPathHandoff by lazy {
        DirectPathHandoff(
            handOver = handOver@{ socket ->
                val service = ShizukuClient.current() ?: return@handOver false
                val descriptor = runCatching { ParcelFileDescriptor.fromSocket(socket) }.getOrNull()
                    ?: return@handOver false
                try {
                    service.adoptDirectSocket(descriptor)
                } finally {
                    runCatching { descriptor.close() }
                }
            },
            bridge = { socket -> DirectBridge.start(socket, ShizukuClient.current(), ::log) },
            log = ::log,
        )
    }

    /** Idempotent: a second call re-reads the switch, permission and keys. */
    fun start(context: Context) {
        val ctx = context.applicationContext
        app = ctx
        if (!running) {
            running = true
            port = PlatformAwarePort(ctx)
            keyStore = PrefsDirectKeyStore(ctx)
            keys = DirectKeys(keyStore!!)
            keyHandler = DirectKeyHandler(
                keys!!,
                ack = { ok ->
                    ShizukuClient.current()?.let { runCatching { it.directKeyStored(ok) } }
                },
                log = ::log,
            )
            PhoneDirect.port = this
            DeckState.addListener(onDeckState)
            registerAwareState(ctx)
        }
        refresh()
    }

    fun stop() {
        if (!running) return
        feed(AwareLinkEvent.SwitchOff)
        running = false
        tick?.let { main.removeCallbacks(it) }
        tick = null
        ndpRetry?.let { main.removeCallbacks(it) }
        ndpRetry = null
        app?.let { unregisterAwareState(it) }
        DeckState.removeListener(onDeckState)
        listener?.close()
        listener = null
        network = null
        port?.releaseNetwork()
        port?.detach()
        link = null
        activeClient = null
        PhoneDirect.port = null
        PhoneDirect.state = null
    }

    fun switchOn(context: Context) {
        Prefs.setDirectSwitch(context.applicationContext, true)
        start(context)
    }

    fun switchOff(context: Context) {
        Prefs.setDirectSwitch(context.applicationContext, false)
        if (running) {
            feed(AwareLinkEvent.SwitchOff)
            report()
        }
    }

    /** The machine's state as closed tokens, for the debug control's log line. */
    fun stateToken(): String = link?.stateToken() ?: "off"

    override fun onMacEnable(clientId: String, on: Boolean) {
        main.post {
            val ctx = app ?: return@post
            Prefs.setDirectEnabled(ctx, clientId, on)
            if (clientId == activeClient || activeClient == null) refresh()
        }
    }

    override fun onMacKey(clientId: String, keyHex: String) {
        main.post {
            val ctx = app ?: return@post
            keyHandler?.onWireKey(clientId, keyHex)
            if (keys?.key(clientId) != null && Prefs.directEnabled(ctx, clientId)) refresh()
        }
    }

    // ------------------------------------------------------------------

    private fun refresh() {
        val ctx = app ?: return
        val provider = port ?: return
        if (link == null) link = AwareLink(gates(ctx), ::log)
        if (!provider.available()) {
            feed(AwareLinkEvent.PlatformBlocked(AwareReason.NO_FEATURE))
            return
        }
        if (!locationEnabled(ctx)) {
            feed(AwareLinkEvent.PlatformBlocked(AwareReason.LOCATION_OFF))
            return
        }
        val chosen = chooseActive(ctx)
        if (chosen != activeClient) {
            activeClient = chosen
            feed(AwareLinkEvent.SwitchOff)
        }
        val client = activeClient
        if (client?.let { keys?.key(it) } != null) feed(AwareLinkEvent.KeyStored)
        else feed(AwareLinkEvent.KeyForgotten)
        val macOn = client?.let { Prefs.directEnabled(ctx, it) } == true
        feed(AwareLinkEvent.MacDirectEnable(macOn))
        if (permissionGranted(ctx)) feed(AwareLinkEvent.PermissionChanged(true))
        else feed(AwareLinkEvent.PermissionDenied)
        if (Prefs.directSwitch(ctx)) feed(AwareLinkEvent.SwitchOn) else feed(AwareLinkEvent.SwitchOff)
        if (DeckState.connectedClientId != null) feed(AwareLinkEvent.SessionLive(macOn))
        else feed(AwareLinkEvent.SessionEnded)
        report()
    }

    private fun gates(ctx: Context) = AwareGates(
        switchOn = Prefs.directSwitch(ctx),
        permitted = permissionGranted(ctx),
        keyStored = activeClient?.let { keys?.key(it) } != null,
        macDirectOn = activeClient?.let { Prefs.directEnabled(ctx, it) } == true,
    )

    private fun chooseActive(ctx: Context): String? {
        val connected = DeckState.connectedClientId
        if (ready(ctx, connected)) return connected
        return Prefs.paired(ctx).firstOrNull { ready(ctx, it.clientId) }?.clientId
    }

    private fun ready(ctx: Context, clientId: String?): Boolean {
        val id = clientId ?: return false
        return Prefs.directEnabled(ctx, id) && keys?.key(id) != null
    }

    private fun feed(event: AwareLinkEvent) {
        val machine = link ?: return
        val step = machine.transition(event)
        for (action in step.actions) perform(action)
        report()
        scheduleTick()
    }

    private fun perform(action: AwareLinkAction) {
        val provider = port ?: return
        when (action) {
            AwareLinkAction.Attach -> provider.attach(
                onAttached = {
                    main.post {
                        feed(AwareLinkEvent.Attached)
                        maybeStartNdp()
                    }
                },
                onFailed = { reason -> main.post { feed(AwareLinkEvent.PublishFailed(reason)) } },
            )
            AwareLinkAction.Detach -> provider.detach()
            AwareLinkAction.Publish -> publish()
            AwareLinkAction.Unpublish -> provider.unpublish()
            is AwareLinkAction.UpdateSsi -> {
                val key = activeKey() ?: return
                if (!provider.updateSsi(Ssi.bytes(key, action.window))) {
                    // An in-place update the platform refused: republish with
                    // the new bytes; a failure is reported through the port.
                    provider.unpublish()
                    publish()
                }
            }
            AwareLinkAction.StartNdp -> startNdp()
            AwareLinkAction.ReleaseNetwork -> {
                listener?.close()
                listener = null
                network = null
                provider.releaseNetwork()
            }
            is AwareLinkAction.StartListener -> startListener(action.network)
            AwareLinkAction.StopListener -> {
                listener?.close()
                listener = null
            }
        }
    }

    private fun publish() {
        val provider = port ?: return
        val key = activeKey() ?: run {
            feed(AwareLinkEvent.KeyForgotten)
            return
        }
        val window = Ssi.window(nowSeconds())
        provider.publish(
            ssi = Ssi.bytes(key, window),
            passphrase = DirectKey.passphrase(key),
            onStarted = {
                main.post {
                    feed(AwareLinkEvent.PublishStarted)
                    maybeStartNdp()
                }
            },
            onFailed = { reason -> main.post { feed(AwareLinkEvent.PublishFailed(reason)) } },
        )
    }

    private fun startNdp() {
        val provider = port ?: return
        val key = activeKey() ?: run {
            feed(AwareLinkEvent.KeyForgotten)
            return
        }
        provider.requestNetwork(
            passphrase = DirectKey.passphrase(key),
            port = DirectConfig.PORT,
            onAvailable = { available ->
                main.post {
                    network = available
                    log("aware: ndp bw=${available.bandwidthKbps()}")
                    feed(AwareLinkEvent.NdpAvailable(available))
                }
            },
            onLost = {
                main.post {
                    feed(AwareLinkEvent.NdpLost)
                    scheduleNdpRetry()
                }
            },
        )
    }

    private fun startListener(available: AwareNetwork) {
        val aware = AwareListener(
            network = available,
            listenPort = DirectConfig.PORT,
            onAccepted = { socket -> handoff.deliver(socket) },
            log = ::log,
        )
        listener = aware
        if (!aware.start()) {
            listener = null
            main.post { feed(AwareLinkEvent.NdpLost) }
        }
    }

    private fun activeKey(): ByteArray? = activeClient?.let { keys?.key(it) }

    /** A session that went live before the publish did still needs its standby. */
    private fun maybeStartNdp() {
        val ctx = app ?: return
        val client = activeClient ?: return
        if (DeckState.connectedClientId != null) {
            feed(AwareLinkEvent.SessionLive(Prefs.directEnabled(ctx, client)))
        }
    }

    /** One retry two seconds after a lost NDP, while a session is still live. */
    private fun scheduleNdpRetry() {
        if (DeckState.connectedClientId == null) return
        ndpRetry?.let { main.removeCallbacks(it) }
        val runnable = Runnable {
            ndpRetry = null
            if (link?.state is AwareLinkState.Publishing && DeckState.connectedClientId != null) {
                maybeStartNdp()
            }
        }
        ndpRetry = runnable
        main.postDelayed(runnable, NDP_RETRY_MS)
    }

    private fun registerAwareState(ctx: Context) {
        if (awareStateRegistered) return
        awareStateRegistered = true
        runCatching {
            ContextCompat.registerReceiver(
                ctx,
                awareState,
                IntentFilter(WifiAwareManager.ACTION_WIFI_AWARE_STATE_CHANGED),
                ContextCompat.RECEIVER_NOT_EXPORTED,
            )
        }.onFailure { awareStateRegistered = false }
    }

    private fun unregisterAwareState(ctx: Context) {
        if (!awareStateRegistered) return
        awareStateRegistered = false
        runCatching { ctx.unregisterReceiver(awareState) }
    }

    /** Report the phone's state as `direct.state`; the shell forwards it. */
    private fun report() {
        val ctx = app ?: return
        val switchOn = Prefs.directSwitch(ctx)
        val permitted = permissionGranted(ctx)
        val reason = when (val state = link?.state) {
            is AwareLinkState.Blocked -> state.reason
            else -> if (switchOn && !permitted) AwareReason.NO_PERMISSION else null
        }
        val state = PhoneDirectState.of(switchOn && permitted, reason)
        PhoneDirect.state = state
        ShizukuClient.current()?.let { service ->
            runCatching { service.setDirectState(state.on, state.reason) }
        }
    }

    private fun scheduleTick() {
        if (!running) return
        tick?.let { main.removeCallbacks(it) }
        val now = nowSeconds()
        val next = (Ssi.window(now) + 1) * DirectConfig.SSI_WINDOW_SECONDS - now
        val runnable = Runnable {
            tick = null
            feed(AwareLinkEvent.SsiTick(Ssi.window(nowSeconds())))
        }
        tick = runnable
        main.postDelayed(runnable, (next + 1) * 1000)
    }

    private fun permissionGranted(ctx: Context): Boolean =
        DirectPermissions.granted(Build.VERSION.SDK_INT) { permission ->
            ctx.checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED
        }

    private fun locationEnabled(ctx: Context): Boolean = runCatching {
        ctx.getSystemService(LocationManager::class.java)?.isLocationEnabled == true
    }.getOrDefault(true)

    private fun nowSeconds(): Long = System.currentTimeMillis() / 1000

    private fun log(message: String) {
        Log.i(TAG, message)
    }

    private const val NDP_RETRY_MS = 2_000L
}

/**
 * The fallback when the shell cannot wrap the app's descriptor (§4.5): one
 * AF_UNIX socketpair, handed over the same AIDL call, and two byte pumps. No
 * framing and no parsing; TLS still ends in the shell.
 */
object DirectBridge {

    fun start(socket: Socket, service: IDeckService?, log: (String) -> Unit): Boolean {
        val target = service ?: return false
        val pair = runCatching { ParcelFileDescriptor.createSocketPair() }.getOrNull() ?: return false
        val appEnd = pair[0]
        val shellEnd = pair[1]
        val adopted = runCatching { target.adoptDirectSocket(shellEnd) }.getOrDefault(false)
        if (!adopted) {
            runCatching { shellEnd.close() }
            runCatching { appEnd.close() }
            return false
        }
        runCatching { shellEnd.close() }
        val readEnd = runCatching { ParcelFileDescriptor.dup(appEnd.fileDescriptor) }.getOrNull()
        val writeEnd = runCatching { ParcelFileDescriptor.dup(appEnd.fileDescriptor) }.getOrNull()
        runCatching { appEnd.close() }
        val inStream = ParcelFileDescriptor.AutoCloseInputStream(readEnd ?: return false)
        val outStream = ParcelFileDescriptor.AutoCloseOutputStream(writeEnd ?: run {
            runCatching { inStream.close() }
            return false
        })
        Thread({
            runCatching { socket.getInputStream().copyTo(outStream, 8 * 1024); outStream.flush() }
            runCatching { outStream.close() }
            runCatching { socket.shutdownOutput() }
        }, "pocketdeck-direct-bridge-up").apply { isDaemon = true }.start()
        Thread({
            runCatching { inStream.copyTo(socket.getOutputStream(), 8 * 1024) }
            runCatching { inStream.close() }
            runCatching { socket.close() }
        }, "pocketdeck-direct-bridge-down").apply { isDaemon = true }.start()
        return true
    }
}
