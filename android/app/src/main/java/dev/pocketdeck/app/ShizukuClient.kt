package dev.pocketdeck.app

import android.content.ComponentName
import android.content.Context
import android.content.ServiceConnection
import android.content.pm.PackageManager
import android.os.IBinder
import android.util.Log
import dev.pocketdeck.BuildConfig
import dev.pocketdeck.IDeckService
import dev.pocketdeck.server.DeckService
import rikka.shizuku.Shizuku
import java.util.concurrent.CopyOnWriteArrayList

/**
 * The app process's single binding to the shell user service. Shizuku's
 * bookkeeping is unhappy with repeated bind/unbind churn, so everything goes
 * through here.
 */
object ShizukuClient {

    private const val TAG = "PocketDeckApp"

    private var service: IDeckService? = null
    private var connecting = false
    private val pending = CopyOnWriteArrayList<(IDeckService?) -> Unit>()
    private val listeners = CopyOnWriteArrayList<(IDeckService?) -> Unit>()

    fun current(): IDeckService? = service

    fun addListener(listener: (IDeckService?) -> Unit) {
        listeners.add(listener)
        service?.let { listener(it) }
    }

    fun removeListener(listener: (IDeckService?) -> Unit) {
        listeners.remove(listener)
    }

    /** Bind the user service if needed, then invoke [callback] with it (null on failure). */
    fun ensureBound(context: Context, callback: ((IDeckService?) -> Unit)? = null) {
        if (callback != null) {
            val s = service
            if (s != null) {
                callback(s)
                return
            }
            pending.add(callback)
        }
        if (service != null || connecting) return
        if (!Shizuku.pingBinder() || Shizuku.isPreV11()) {
            Log.i(TAG, "shizuku not available")
            failPending()
            return
        }
        if (Shizuku.checkSelfPermission() != PackageManager.PERMISSION_GRANTED) {
            Log.i(TAG, "shizuku permission not granted")
            failPending()
            return
        }
        connecting = true
        val args = Shizuku.UserServiceArgs(ComponentName(context.applicationContext, DeckService::class.java))
            .daemon(true)
            .version(BuildConfig.VERSION_CODE)
            .processNameSuffix("pocketdeck")
            .tag("pocketdeck")
        try {
            Shizuku.bindUserService(
                args,
                object : ServiceConnection {
                    override fun onServiceConnected(name: ComponentName?, binder: IBinder?) {
                        val svc = IDeckService.Stub.asInterface(binder)
                        service = svc
                        connecting = false
                        Log.i(TAG, "user service connected")
                        for (cb in pending.toList()) cb(svc)
                        pending.clear()
                        for (l in listeners.toList()) l(svc)
                    }

                    override fun onServiceDisconnected(name: ComponentName?) {
                        Log.i(TAG, "user service disconnected")
                        service = null
                        connecting = false
                        for (l in listeners.toList()) l(null)
                    }
                },
            )
        } catch (e: Throwable) {
            connecting = false
            Log.i(TAG, "bindUserService failed: ${e.message}")
            failPending()
        }
    }

    /** Drop the in-memory binding (the daemon keeps running). */
    fun reset() {
        service = null
        connecting = false
        for (l in listeners.toList()) l(null)
    }

    private fun failPending() {
        for (cb in pending.toList()) cb(null)
        pending.clear()
    }
}
