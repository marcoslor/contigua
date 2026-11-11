package dev.pocketdeck.app

import android.content.ComponentName
import android.content.Context
import android.content.ServiceConnection
import android.content.pm.PackageManager
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.Process
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
            if (Prefs.isShellRestartedForBinder(this.context!!)) {
                Log.i(TAG, "shell restart: restarted for binder") // log-ok: closed tokens
            }
            // Sticky: a binder that arrived before this process asked for it is
            // replayed, so an app started while Shizuku runs binds at once.
            runCatching { Shizuku.addBinderReceivedListenerSticky(binderReceived) }
            runCatching { Shizuku.addBinderDeadListener(binderDead) }
        }
        // The sticky listener covers a binder that is already here; this covers
        // a listener registration that never landed (a Shizuku build that does
        // not replay) without binding on a timer.
        if (machine.state is ShellState.NoBinder) {
            if (hasBinder()) send(ShellEvent.BinderReceived) else send(ShellEvent.Started)
        }
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
        publishFailure()
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

    /**
     * The person's Try again: when the binder answers but every bind times out,
     * another round in this process loses the same way, so restart our own
     * process and let Shizuku's server push a binder to the new pid (PHONE-23).
     * Otherwise ask for a round as before.
     */
    fun retry() {
        if (!listening) return
        when (machine.state) {
            is ShellState.Failed ->
                send(if (hasBinder()) ShellEvent.RestartRequested else ShellEvent.RetryRequested)
            else -> send(ShellEvent.RetryRequested)
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
        publishFailure()
        for (action in actions) perform(action)
    }

    private fun perform(action: ShellAction) {
        when (action) {
            ShellAction.CheckPermission -> send(permissionEvent())
            ShellAction.BindService -> bind()
            ShellAction.ProbeBinder -> probeBinder()
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
            is ShellAction.RestartSelf -> restartSelf(action)
        }
    }

    /**
     * Re-ask for the binder. A sticky re-add replays a binder Shizuku already
     * pushed (the one case a lost registration can fix); a ping is the same
     * answer without the listener. A live server never pushes twice to the same
     * pid (Shizuku's BinderSender remembers it), so this cannot adopt a
     * surviving server on its own — the 60 s step restarts our pid for that.
     */
    private fun probeBinder() {
        runCatching { Shizuku.removeBinderReceivedListener(binderReceived) }
        runCatching { Shizuku.addBinderReceivedListenerSticky(binderReceived) }
        send(if (hasBinder()) ShellEvent.BinderReceived else ShellEvent.BinderAbsent)
    }

    /**
     * Restart only this app's process: Shizuku and its server are never touched
     * (PHONE-23). An automatic restart happens once per lost-binder episode (the
     * pref survives the restart and is cleared on Ready); a tap is consent, so
     * it skips that bound but still never loops. With the background switch off
     * the service is not sticky, so killing the process would leave the app
     * dead: decline.
     */
    private fun restartSelf(action: ShellAction.RestartSelf) {
        val ctx = context ?: return declineRestart(action.reason, "no_context")
        if (!Prefs.isEnabled(ctx) || !DeckState.serviceRunning) {
            return declineRestart(action.reason, "keep_off")
        }
        if (action.bounded && Prefs.isShellRestartedForBinder(ctx)) {
            return declineRestart(action.reason, "already_restarted")
        }
        Prefs.setShellRestartedForBinder(ctx, true)
        Log.i(TAG, "shell restart: ${action.reason.describe()} --restart--> process") // log-ok: closed tokens
        Process.killProcess(Process.myPid())
    }

    private fun declineRestart(reason: ShellFailure, why: String) {
        Log.i(TAG, "shell restart: ${reason.describe()} --restart declined($why)--> waiting") // log-ok: closed tokens
    }

    /** Tell the card when the binding is failed, with the closed reason token. */
    private fun publishFailure() {
        val reason = (machine.state as? ShellState.Failed)?.reason
        if (DeckState.shellFailure != reason) {
            DeckState.shellFailure = reason
            DeckState.notifyChanged()
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
        // Ready ends the lost-binder episode: the next one may restart once.
        context?.let { Prefs.setShellRestartedForBinder(it, false) }
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
