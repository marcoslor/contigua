package dev.pocketdeck.app

import android.content.ComponentName
import android.content.Context
import android.content.ServiceConnection
import android.content.pm.PackageManager
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.util.Log
import dev.pocketdeck.BuildConfig
import dev.pocketdeck.IDeckService
import dev.pocketdeck.server.DeckService
import rikka.shizuku.Shizuku
import java.util.concurrent.CopyOnWriteArrayList

/**
 * The app process's single binding to the shell user service, driven by the
 * [ShellBinding] machine (docs/specs/phone-app.md PHONE-20).
 *
 * Shizuku's server can die and come back at any time: on a non-rooted phone it
 * runs from wireless debugging, so losing that connection takes the server and
 * the user service with it (the person's 10-28 report). The machine is told
 * about every binder arrival and death, so the service is bound again by
 * itself; nothing here waits for a tap.
 *
 * Shizuku's bookkeeping is unhappy with repeated bind/unbind churn, so every
 * bind goes through the machine's bounded round.
 */
object ShizukuClient {

    private const val TAG = "PocketDeckApp"

    private val main = Handler(Looper.getMainLooper())
    private var machine = ShellBinding()
    private var context: Context? = null
    private var listening = false

    @Volatile private var service: IDeckService? = null
    private val pending = CopyOnWriteArrayList<(IDeckService?) -> Unit>()
    private val listeners = CopyOnWriteArrayList<(IDeckService?) -> Unit>()

    private val bindTimeout = Runnable { send(ShellEvent.BindTimedOut) }
    private val retryTick = Runnable { send(ShellEvent.RetryTick) }

    private val binderReceived = Shizuku.OnBinderReceivedListener { send(ShellEvent.BinderReceived) }
    private val binderDead = Shizuku.OnBinderDeadListener {
        lost()
        send(ShellEvent.BinderDead)
    }

    /** The bound service, or null. */
    fun current(): IDeckService? = service

    /** Whether Shizuku's binder is with this process right now. */
    fun hasBinder(): Boolean = runCatching { Shizuku.pingBinder() }.getOrDefault(false)

    /**
     * Whether PocketDeck may use Shizuku: true granted, false denied, null when
     * Shizuku cannot answer (no binder, or not attached yet). Shizuku keeps a
     * grant across a server restart, so "cannot answer" must never be read as
     * "denied": that is what asked the person to allow PocketDeck again after
     * their server came back.
     */
    fun permission(): Boolean? = try {
        when {
            !hasBinder() -> null
            // A server too old to gate per app cannot be granted at all.
            Shizuku.isPreV11() -> false
            else -> Shizuku.checkSelfPermission() == PackageManager.PERMISSION_GRANTED
        }
    } catch (e: Throwable) {
        Log.i(TAG, "shizuku permission unreadable: ${e.javaClass.simpleName}") // log-ok: class only
        null
    }

    fun addListener(listener: (IDeckService?) -> Unit) {
        listeners.add(listener)
        service?.let { listener(it) }
    }

    fun removeListener(listener: (IDeckService?) -> Unit) {
        listeners.remove(listener)
    }

    /**
     * Start (or continue) the binding for this process. Called by the foreground
     * service when it starts and by anything that needs the shell service now.
     */
    fun attach(context: Context) {
        this.context = context.applicationContext
        if (!listening) {
            listening = true
            // Sticky: a binder that arrived before this process asked for it is
            // replayed, so an app started while Shizuku runs binds at once.
            runCatching { Shizuku.addBinderReceivedListenerSticky(binderReceived) }
            runCatching { Shizuku.addBinderDeadListener(binderDead) }
        }
        // The sticky listener covers a binder that is already here; this covers
        // a listener registration that never landed (a Shizuku build that does
        // not replay) without binding on a timer.
        if (machine.state is ShellState.NoBinder && hasBinder()) send(ShellEvent.BinderReceived)
    }

    /** Stop listening: the deck is not serving, so nothing may be bound. */
    fun detach() {
        if (!listening) return
        listening = false
        runCatching { Shizuku.removeBinderReceivedListener(binderReceived) }
        runCatching { Shizuku.removeBinderDeadListener(binderDead) }
        main.removeCallbacks(bindTimeout)
        main.removeCallbacks(retryTick)
        machine = ShellBinding()
        lost()
        context = null
    }

    /** Bind the user service if needed, then invoke [callback] with it (null on failure). */
    fun ensureBound(context: Context, callback: ((IDeckService?) -> Unit)? = null) {
        attach(context)
        val bound = service
        if (bound != null) {
            callback?.invoke(bound)
            return
        }
        if (callback != null) pending.add(callback)
        when (machine.state) {
            // A caller asking now is the person's Try again or a component
            // that needs the service: a fresh bounded round.
            is ShellState.Failed, is ShellState.WaitingRetry, is ShellState.NeedsPermission ->
                send(ShellEvent.RetryRequested)
            is ShellState.NoBinder ->
                if (hasBinder()) send(ShellEvent.BinderReceived)
            is ShellState.Binding, ShellState.Ready -> Unit
        }
        // The machine is the answer. A state that cannot bind now (no binder,
        // permission missing, the round is over) cannot answer these callers
        // later either, so they hear "no" instead of waiting for nothing.
        when (machine.state) {
            is ShellState.NoBinder, is ShellState.NeedsPermission, is ShellState.Failed -> failPending()
            is ShellState.Binding, is ShellState.WaitingRetry, ShellState.Ready -> Unit
        }
    }

    // ---- the machine's driver ------------------------------------------

    private fun send(event: ShellEvent) {
        if (Looper.myLooper() != Looper.getMainLooper()) {
            main.post { send(event) }
            return
        }
        val from = machine.state
        val actions = machine.transition(event)
        // Closed state/reason tokens only: no text, no names, no device data.
        Log.i(TAG, "shell binding: ${from.describe()} --${event.describe()}--> ${machine.state.describe()}") // log-ok: closed tokens
        for (action in actions) perform(action)
    }

    private fun perform(action: ShellAction) {
        when (action) {
            ShellAction.CheckPermission -> send(permissionEvent())
            ShellAction.BindService -> bind()
            ShellAction.ProbeBinder -> Unit
            is ShellAction.ArmTimeout -> {
                main.removeCallbacks(bindTimeout)
                main.postDelayed(bindTimeout, action.ms)
            }
            ShellAction.CancelTimers -> {
                main.removeCallbacks(bindTimeout)
                main.removeCallbacks(retryTick)
            }
            is ShellAction.WaitThenRetry -> {
                main.removeCallbacks(retryTick)
                main.postDelayed(retryTick, action.ms)
            }
            ShellAction.ReportReady -> onReady()
            is ShellAction.ReportFailure -> {
                Log.i(TAG, "shell service gave up: ${action.failure.describe()}") // log-ok: closed reason token
                failPending()
            }
            is ShellAction.RestartSelf -> Unit
        }
    }

    private fun permissionEvent(): ShellEvent = when (permission()) {
        true -> ShellEvent.PermissionGranted
        false -> ShellEvent.PermissionDenied
        // No binder to ask: the binder listener decides when to try again.
        null -> ShellEvent.BinderDead
    }

    private fun bind() {
        val ctx = context ?: run {
            send(ShellEvent.BindFailed(ShellFailure(ShellFailure.BIND_FAILED, "NoContext")))
            return
        }
        if (!hasBinder()) {
            send(ShellEvent.BindFailed(ShellFailure(ShellFailure.BINDER_DEAD)))
            return
        }
        val args = Shizuku.UserServiceArgs(ComponentName(ctx, DeckService::class.java))
            .daemon(true)
            .version(BuildConfig.VERSION_CODE)
            .processNameSuffix("pocketdeck")
            .tag("pocketdeck")
        val connection = object : ServiceConnection {
            override fun onServiceConnected(name: ComponentName?, binder: IBinder?) {
                main.post {
                    service = IDeckService.Stub.asInterface(binder)
                    send(ShellEvent.BindSucceeded)
                }
            }

            override fun onServiceDisconnected(name: ComponentName?) {
                main.post {
                    lost()
                    send(ShellEvent.ServiceDied)
                }
            }
        }
        try {
            Shizuku.bindUserService(args, connection)
        } catch (e: Throwable) {
            send(ShellEvent.BindFailed(ShellFailure(ShellFailure.BIND_FAILED, e.javaClass.simpleName)))
        }
    }

    private fun onReady() {
        val bound = service ?: return
        for (callback in pending.toList()) callback(bound)
        pending.clear()
        for (listener in listeners.toList()) listener(bound)
        startDeckIfNobodyServes()
    }

    /**
     * ISS-42: a process can bind the shell service with no foreground service
     * in it (the notification listener's bind is enough). Ready then has no
     * listener to push the pairings, and every Mac is refused until the app is
     * tapped. This starts the deck; the deck's own attach is still the only
     * path that calls [DeckForegroundService.onServiceReady].
     */
    private fun startDeckIfNobodyServes() {
        val ctx = context ?: return
        if (!startsDeckWhenReady(Prefs.isEnabled(ctx), DeckState.serviceRunning)) return
        Log.i(TAG, "deck start: Ready --start-deck--> Starting") // log-ok: closed tokens
        runCatching { DeckForegroundService.start(ctx) }
            .onFailure { Log.i(TAG, "deck start: start refused ${it.javaClass.simpleName}") } // log-ok: class only
    }

    /** The binding is gone: answer the waiting callers and the UI. */
    private fun lost() {
        service = null
        failPending()
        for (listener in listeners.toList()) listener(null)
    }

    private fun failPending() {
        for (callback in pending.toList()) callback(null)
        pending.clear()
    }
}
