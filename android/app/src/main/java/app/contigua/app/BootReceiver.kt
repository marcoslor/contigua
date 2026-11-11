package app.contigua.app

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Handler
import android.os.Looper
import android.util.Log
import rikka.shizuku.Shizuku

private const val TAG = "ContiguaApp"

/**
 * Restart the deck after a reboot or an app update, when the user enabled it
 * (ISS-42). The decision is [DeckStartup]; this class only performs its
 * actions.
 */
class BootReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent) {
        val trigger = when (intent.action) {
            Intent.ACTION_BOOT_COMPLETED -> StartTrigger.Boot
            Intent.ACTION_MY_PACKAGE_REPLACED -> StartTrigger.Update
            else -> return
        }
        StartupRun(context.applicationContext, goAsync()).received(trigger)
    }
}

/**
 * Holds the broadcast open (goAsync) for Shizuku's binder, through the sticky
 * listener, and starts the deck from the one action the machine returns.
 *
 * A binder that arrives after the bound keeps the listener registered, so the
 * deck still starts without a tap while the process lives; the listener is
 * removed as soon as it starts.
 */
private class StartupRun(
    private val app: Context,
    private val pending: BroadcastReceiver.PendingResult,
) {
    private val main = Handler(Looper.getMainLooper())
    private val machine = DeckStartup()
    private var finished = false

    private val binderListener = Shizuku.OnBinderReceivedListener {
        if (Looper.myLooper() == Looper.getMainLooper()) event(StartupEvent.BinderArrived)
        else main.post { event(StartupEvent.BinderArrived) }
    }

    private val timeout = Runnable { event(StartupEvent.Waited(DeckStartup.BOUND_MS)) }

    fun received(trigger: StartTrigger) {
        event(StartupEvent.Received(trigger, Prefs.isEnabled(app), ShizukuClient.hasBinder()))
    }

    private fun event(event: StartupEvent) {
        val from = machine.state
        val actions = machine.transition(event)
        // Closed tokens only: no names, counts or device data.
        Log.i(TAG, "app start: ${from.describe()} --${event.describe()}--> ${machine.state.describe()}") // log-ok: closed tokens
        for (action in actions) when (action) {
            StartupAction.WaitForBinder -> {
                // Arm the timeout before the sticky registration: a binder
                // that is already here may be replayed inside the call.
                main.postDelayed(timeout, DeckStartup.BOUND_MS)
                val listening = runCatching {
                    Shizuku.addBinderReceivedListenerSticky(binderListener)
                }.isSuccess
                if (!listening) {
                    main.removeCallbacks(timeout)
                    event(StartupEvent.Waited(DeckStartup.BOUND_MS))
                }
            }
            StartupAction.FinishBroadcast -> finish()
            StartupAction.StartDeck -> {
                runCatching { Shizuku.removeBinderReceivedListener(binderListener) }
                main.removeCallbacks(timeout)
                // A start refused for background limits must not crash the
                // process that is trying to recover the deck.
                runCatching { DeckForegroundService.start(app) }
                    .onFailure { Log.i(TAG, "app start: start refused ${it.javaClass.simpleName}") } // log-ok: class only
                finish()
            }
        }
    }

    private fun finish() {
        if (finished) return
        finished = true
        runCatching { pending.finish() }
    }
}
