package dev.pocketdeck.server

import android.content.ClipData
import android.os.Binder
import android.os.IBinder
import android.os.Parcel
import java.lang.reflect.Method
import java.lang.reflect.Proxy

/**
 * The primary clipboard, read and written as the shell user (UID 2000) through
 * the hidden `android.content.IClipboard` binder. The app process cannot read
 * the clipboard in the background; the shell package can.
 *
 * The hidden signatures change between Android releases, so each call is
 * probed by name and parameter shape (see [ClipboardApi]) instead of being
 * bound to one layout.
 */
internal class ShellClipboard(private val log: (String) -> Unit) : ClipboardPort {

    private val service: Any? by lazy { Hidden.proxy(IFACE, "clipboard") }

    @Volatile private var onChange: ((String) -> Unit)? = null
    private var listener: Any? = null

    override fun getText(): String? {
        val svc = service ?: return null
        val get = ClipboardApi.calls(log).get ?: return null
        val clip = runCatching { get.invoke(svc, *argsFor(get, null, null)) }
            .onFailure { log("clipboard: getPrimaryClip failed: $it") }
            .getOrNull() as? ClipData ?: return null
        if (clip.itemCount == 0) return null
        return clip.getItemAt(0).text?.toString()
    }

    override fun setText(text: String) {
        val svc = service ?: return
        val set = ClipboardApi.calls(log).set ?: return
        val clip = ClipData.newPlainText(CLIP_LABEL, text)
        runCatching { set.invoke(svc, *argsFor(set, ClipData::class.java, clip)) }
            .onFailure { log("clipboard: setPrimaryClip failed: $it") }
    }

    override fun listen(onChange: (String) -> Unit) {
        stop()
        val svc = service ?: run {
            log("clipboard: no clipboard service; sync off")
            return
        }
        val calls = ClipboardApi.calls(log)
        val add = calls.add ?: return
        val iface = calls.listenerIface ?: return
        this.onChange = onChange
        // Same shape as the keyguard listener in AndroidDeviceState: system_server
        // marshals the listener through asBinder() and calls transaction 1 (the
        // one-way dispatchPrimaryClipChanged) on the Binder we hand back.
        val carrier = object : Binder() {
            override fun onTransact(code: Int, data: Parcel, reply: Parcel?, flags: Int): Boolean {
                if (code != IBinder.FIRST_CALL_TRANSACTION) return super.onTransact(code, data, reply, flags)
                data.enforceInterface(iface.name)
                val cb = this@ShellClipboard.onChange ?: return true
                getText()?.let(cb)
                return true
            }
        }
        val proxy = Proxy.newProxyInstance(iface.classLoader, arrayOf(iface)) { _, method, _ ->
            if (method.name == "asBinder") carrier else null
        }
        val added = runCatching { add.invoke(svc, *argsFor(add, iface, proxy)) }
        added.exceptionOrNull()?.let {
            log("clipboard: addPrimaryClipChangedListener failed: $it")
            this.onChange = null
            return
        }
        listener = proxy
    }

    override fun stop() {
        onChange = null
        val proxy = listener ?: return
        listener = null
        val svc = service ?: return
        val calls = ClipboardApi.calls(log)
        val remove = calls.remove ?: return
        val iface = calls.listenerIface ?: return
        runCatching { remove.invoke(svc, *argsFor(remove, iface, proxy)) }
            .onFailure { log("clipboard: removePrimaryClipChangedListener failed: $it") }
    }
}

private const val IFACE = "android.content.IClipboard"
private const val LISTENER_IFACE = "android.content.IOnPrimaryClipChangedListener"
private const val SHELL_PACKAGE = "com.android.shell"
private const val CLIP_LABEL = "PocketDeck"

/**
 * The hidden calls, probed once per process. The chosen signatures are logged
 * here, once, when they are first resolved.
 */
private object ClipboardApi {
    class Calls(
        val listenerIface: Class<*>?,
        val get: Method?,
        val set: Method?,
        val add: Method?,
        val remove: Method?,
    )

    @Volatile private var resolved: Calls? = null

    fun calls(log: (String) -> Unit): Calls {
        resolved?.let { return it }
        synchronized(this) {
            resolved?.let { return it }
            val iface = Hidden.iface(IFACE)
            val listenerIface = Hidden.iface(LISTENER_IFACE)
            val found = Calls(
                listenerIface = listenerIface,
                get = probe(iface, "getPrimaryClip", null),
                set = probe(iface, "setPrimaryClip", ClipData::class.java),
                add = probe(iface, "addPrimaryClipChangedListener", listenerIface),
                remove = probe(iface, "removePrimaryClipChangedListener", listenerIface),
            )
            val names = listOf(
                "getPrimaryClip" to found.get,
                "setPrimaryClip" to found.set,
                "addPrimaryClipChangedListener" to found.add,
                "removePrimaryClipChangedListener" to found.remove,
            )
            for ((name, m) in names) {
                log("clipboard: $name(${m?.parameterTypes?.joinToString { it.simpleName } ?: "missing"})")
            }
            resolved = found
            return found
        }
    }

    /**
     * The overload named [name] whose parameters are String, int or [valueType],
     * with exactly one [valueType] when there is one. Covers the API 33 and
     * API 34–36 layouts and the older `(…, pkg, userId)` form; the longest
     * match wins if several fit.
     */
    private fun probe(iface: Class<*>?, name: String, valueType: Class<*>?): Method? {
        if (iface == null) return null
        val valueCount = if (valueType == null) 0 else 1
        return iface.methods
            .filter { m ->
                m.name == name &&
                    m.parameterTypes.count { it == valueType } == valueCount &&
                    m.parameterTypes.all { it == valueType || it == String::class.java || it == Int::class.javaPrimitiveType }
            }
            .maxByOrNull { it.parameterCount }
    }
}

/**
 * Arguments for a probed call. [value] fills the parameter of [valueType]; the
 * first String is the calling package, later Strings are the null attribution
 * tag; ints are user 0 and device 0.
 */
private fun argsFor(m: Method, valueType: Class<*>?, value: Any?): Array<Any?> {
    var strings = 0
    var valueUsed = false
    return Array(m.parameterCount) { i ->
        val p = m.parameterTypes[i]
        when {
            valueType != null && p == valueType && !valueUsed -> {
                valueUsed = true
                value
            }
            p == String::class.java -> if (strings++ == 0) SHELL_PACKAGE else null
            else -> 0
        }
    }
}
