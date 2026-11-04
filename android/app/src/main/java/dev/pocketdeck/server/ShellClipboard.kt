package dev.pocketdeck.server

import android.content.ClipData
import android.content.ClipDescription
import android.content.ContentResolver
import android.content.Context
import android.net.Uri
import android.os.Binder
import android.os.IBinder
import android.os.Parcel
import android.os.Process
import java.lang.reflect.Method
import java.lang.reflect.Proxy

/**
 * The primary clipboard, read and written through the hidden
 * `android.content.IClipboard` binder.
 *
 * The hidden signatures change between Android releases, so each call is
 * probed by name and parameter shape (see [ClipboardApi]) instead of being
 * bound to one layout. The caller's UID decides whether a read is safe: AOSP's
 * `getPrimaryClip` clears the clip when the caller does not own the package it
 * names, and root (UID 0) owns no package at all (ISS-27).
 */
internal class ShellClipboard(
    private val ctx: Context?,
    private val log: (String) -> Unit,
    /** This process's UID: 2000 under Shizuku, 0 when it runs with root privileges. */
    private val callerUid: Int = Process.myUid(),
    private val service: ClipboardService? = BinderClipboardService(log),
    /** The shell-user reader for a root process; null when there is none. */
    private val helper: ClipboardHelperPort? = null,
) : ClipboardPort, ClipboardImagePort {

    /** The one live registration; only its handle may stop it (ISS-13). */
    @Volatile private var live: ClipRegistration? = null

    /**
     * Guards every read-then-write of [live]. Without it, an old session's
     * `stop` could pass its "still live" check, lose the CPU to the new
     * session's `listen`, and then clear the new registration (the ISS-13 race
     * in a smaller window). The binder calls stay outside the lock.
     */
    private val liveLock = Any()

    /** One "reads off" line per sync start, never one per poll tick. */
    @Volatile private var offLogged = false

    override fun getText(): ClipText? = when (val reader = reader()) {
        ClipReader.Direct -> directText()
        ClipReader.Helper -> helper?.getText()
        is ClipReader.Off -> {
            logOffOnce(reader.reason)
            null
        }
    }

    private fun directText(): ClipText? {
        val svc = service ?: return null
        val clip = svc.getPrimaryClip(SHELL_PACKAGE, callerUid) ?: return null
        if (clip.itemCount == 0) return null
        val text = clip.getItemAt(0).text?.toString() ?: return null
        return ClipText(text, isSensitive(clip.description))
    }

    override fun setText(text: String) {
        val svc = service ?: return
        val clip = ClipData.newPlainText(CLIP_LABEL, text)
        svc.setPrimaryClip(clip, SHELL_PACKAGE, callerUid)
    }

    // ---- images (docs/design/dragdrop.md): first image item only ---------------

    private val resolver: ContentResolver?
        get() = ctx?.contentResolver

    /**
     * The image bytes of the primary clip, or null when it holds none, its first
     * item is text (text wins: the text sync owns it) or the item's URI is not
     * readable at shell UID. A null is "nothing to sync", never an error.
     */
    override fun readImage(): ClipImage? = when (val reader = reader()) {
        ClipReader.Direct -> directImage()
        ClipReader.Helper -> helper?.readImage()
        is ClipReader.Off -> {
            logOffOnce(reader.reason)
            null
        }
    }

    /**
     * The primary clip's description has no owner check, so it is the safe MIME
     * probe at every UID: a text clip never reaches `getPrimaryClip`, which
     * halves the poll's reads and keeps a text copy untouched at UID 2000 too.
     */
    private fun directImage(): ClipImage? {
        val svc = service ?: return null
        val description = svc.getPrimaryClipDescription(SHELL_PACKAGE, callerUid) ?: return null
        // filterMimeTypes answers null, not an empty array, when no type
        // matches (every text copy); a throw here killed the helper (ISS-27).
        val probe = description.filterMimeTypes("image/*")?.firstOrNull() ?: return null
        val clip = svc.getPrimaryClip(SHELL_PACKAGE, callerUid) ?: return null
        if (clip.itemCount == 0) return null
        val item = clip.getItemAt(0)
        if (item.text != null) return null
        if (isSensitive(clip.description)) return null
        val contentUri = item.uri ?: return null
        // The app's own clip (SHARE-2/16): never sync our write back to the Mac.
        if (isOurClip(contentUri)) return null
        // API 29's filterMimeTypes avoids the per-index walk (countMimeTypes is a
        // later call than this code's floor).
        val mime = clip.description.filterMimeTypes("image/*")?.firstOrNull() ?: probe
        val source = resolver ?: return null
        val bytes = runCatching { source.openInputStream(contentUri)?.use { s -> s.readBytes() } }
            .onFailure { log("clipboard: unreadable clip image ($mime): ${failureClasses(it)}") }
            .getOrNull() ?: return null
        return ClipImage(bytes, mime.lowercase())
    }

    private fun reader(): ClipReader = clipReader(callerUid, helper?.available == true)

    private fun logOffOnce(reason: String) {
        if (offLogged) return
        offLogged = true
        log("clipboard: reads off ($reason)")
    }

    override fun listen(onChange: () -> Unit): ClipRegistration {
        val reg = ClipRegistration(onChange)
        // The new registration is live before the old one is removed: a
        // dispatch in flight from the old listener must not reach it.
        val previous = synchronized(liveLock) { live.also { live = reg } }
        if (previous != null) remove(previous)
        offLogged = false
        if (callerUid == 0) {
            val shellReader = helper
            if (shellReader == null) {
                logOffOnce((clipReader(callerUid, helperAvailable = false) as ClipReader.Off).reason)
                return reg
            }
            // The helper keeps its own listener as the shell user; it signals
            // changes only, and the session reads when its gate is on.
            shellReader.listen {
                if (live !== reg) return@listen
                reg.onChange()
            }
            shellReader.start()
            return reg
        }
        if (callerUid != SHELL_UID) {
            logOffOnce((clipReader(callerUid, helperAvailable = false) as ClipReader.Off).reason)
            return reg
        }
        val svc = service ?: run {
            log("clipboard: no clipboard service; sync off")
            return reg
        }
        // Same shape as the keyguard listener in AndroidDeviceState: system_server
        // marshals the listener through asBinder() and calls transaction 1 (the
        // one-way dispatchPrimaryClipChanged) on the Binder we hand back. The
        // signal carries no clip: the session reads only when its gate is on.
        val listener = ClipChangeListener {
            // A late dispatch from a replaced registration is not this
            // session's clip (ISS-13).
            if (live !== reg) return@ClipChangeListener
            reg.onChange()
        }
        reg.listener = listener
        if (!svc.addClipListener(listener)) {
            log("clipboard: addPrimaryClipChangedListener failed")
            reg.listener = null
        }
        return reg
    }

    override fun stop(registration: ClipRegistration?) {
        val reg = registration ?: return
        val owned = synchronized(liveLock) {
            if (live === reg) {
                live = null
                true
            } else {
                false
            }
        }
        if (!owned) {
            // A replaced or already stopped handle: the live session keeps its
            // listener (ISS-13). Never prints a clip.
            log("clipboard: stale stop ignored")
            return
        }
        remove(reg)
        // The helper has no listener left to serve; it dies with its stdin, and
        // the next sync starts a fresh one.
        if (callerUid == 0) helper?.stop()
    }

    /** Removes the platform listener a registration installed, if any. */
    private fun remove(reg: ClipRegistration) {
        val listener = reg.listener as? ClipChangeListener ?: return
        reg.listener = null
        val svc = service ?: return
        svc.removeClipListener(listener)
    }

    /** The system's own "this is a secret" mark on a clip's description. */
    private fun isSensitive(description: ClipDescription?): Boolean {
        val extras = description?.extras ?: return false
        return SENSITIVE_KEYS.any { key -> runCatching { extras.getBoolean(key, false) }.getOrDefault(false) }
    }
}

/**
 * A primary-clip change as this process hears it: the signal only, never the
 * clip (ISS-27). Reading is a separate decision.
 */
internal fun interface ClipChangeListener {
    fun onPrimaryClipChanged()
}

/**
 * The hidden clipboard service as this process sees it.
 *
 * [uid] is the caller's process UID. The binder call uses the caller's real
 * identity, so production does not pass it; the JVM tests use it to model the
 * AOSP owner check: `getPrimaryClip` clears the clip and returns null when the
 * caller does not own [packageName], while `getPrimaryClipDescription` never
 * checks.
 */
internal interface ClipboardService {
    fun getPrimaryClip(packageName: String, uid: Int): ClipData?
    fun getPrimaryClipDescription(packageName: String, uid: Int): ClipDescription?
    fun setPrimaryClip(clip: ClipData, packageName: String, uid: Int)
    fun addClipListener(listener: ClipChangeListener): Boolean
    fun removeClipListener(listener: ClipChangeListener)
}

/**
 * The clipboard reader that runs as the real shell user (UID 2000) for a
 * process with root privileges. One request at a time; every method returns
 * null when the helper is not ready, never a partial read.
 */
internal interface ClipboardHelperPort {
    /** True while the helper process is up and has registered its listener. */
    val available: Boolean
    fun start()
    fun stop()
    fun listen(onChange: () -> Unit)
    fun getText(): ClipText?
    fun readImage(): ClipImage?
}

/**
 * A2, measured on the emulator (boot 3): the URI-only item pastes nothing in a
 * plain text field (a content URI that cannot serve text coerces to null, never
 * to its `content://` string) and reaches a field whose OnReceiveContentListener
 * accepts image types. So the item carries the URI alone; the empty-text
 * variant is not needed.
 */
internal fun imageClipItem(uri: Uri): ClipData.Item = ClipData.Item(uri)

/** The whole image clip: the image's own MIME type over the URI-only item. */
internal fun imageClip(uri: Uri, mime: String): ClipData =
    ClipData(ClipDescription(CLIP_LABEL, arrayOf(mime)), imageClipItem(uri))

internal const val IFACE = "android.content.IClipboard"
internal const val LISTENER_IFACE = "android.content.IOnPrimaryClipChangedListener"
internal const val SHELL_PACKAGE = "com.android.shell"
private const val CLIP_LABEL = "PocketDeck"

/**
 * The extra Android sets on a clip's description to mean "never leave this
 * device": API 33's `ClipDescription.EXTRA_IS_SENSITIVE` and the same key
 * written out, which older builds and password managers set by name.
 */
private val SENSITIVE_KEYS = setOf(
    ClipDescription.EXTRA_IS_SENSITIVE,
    "android.content.extra.IS_SENSITIVE",
)

/** The app's FileProvider: a shell-written file is served through the app's provider. */
const val FILE_PROVIDER_AUTHORITY = "dev.pocketdeck.fileprovider"

/**
 * The production [ClipboardService]: the hidden binder, probed once per process.
 * The chosen signatures are logged once, when they are first resolved.
 */
internal class BinderClipboardService(private val log: (String) -> Unit) : ClipboardService {

    private val binder: Any? by lazy { Hidden.proxy(IFACE, "clipboard") }
    private val api: ClipboardApi.Calls by lazy { ClipboardApi.calls(log) }
    private val proxies = java.util.concurrent.ConcurrentHashMap<ClipChangeListener, Any>()

    override fun getPrimaryClip(packageName: String, uid: Int): ClipData? {
        val svc = binder ?: return null
        val get = api.get ?: return null
        return runCatching { get.invoke(svc, *argsFor(get, null, null, packageName)) }
            .onFailure { log("clipboard: getPrimaryClip failed: ${failureClasses(it)}") }
            .getOrNull() as? ClipData
    }

    override fun getPrimaryClipDescription(packageName: String, uid: Int): ClipDescription? {
        val svc = binder ?: return null
        val description = api.description ?: return null
        return runCatching { description.invoke(svc, *argsFor(description, null, null, packageName)) }
            .onFailure { log("clipboard: getPrimaryClipDescription failed: ${failureClasses(it)}") }
            .getOrNull() as? ClipDescription
    }

    override fun setPrimaryClip(clip: ClipData, packageName: String, uid: Int) {
        val svc = binder ?: return
        val set = api.set ?: return
        runCatching { set.invoke(svc, *argsFor(set, ClipData::class.java, clip, packageName)) }
            .onFailure { log("clipboard: setPrimaryClip failed: ${failureClasses(it)}") }
    }

    override fun addClipListener(listener: ClipChangeListener): Boolean {
        val svc = binder ?: return false
        val add = api.add ?: return false
        val iface = api.listenerIface ?: return false
        // system_server marshals the listener through asBinder() and calls
        // transaction 1 (the one-way dispatchPrimaryClipChanged).
        val carrier = object : Binder() {
            override fun onTransact(code: Int, data: Parcel, reply: Parcel?, flags: Int): Boolean {
                if (code != IBinder.FIRST_CALL_TRANSACTION) return super.onTransact(code, data, reply, flags)
                data.enforceInterface(iface.name)
                listener.onPrimaryClipChanged()
                return true
            }
        }
        val proxy = Proxy.newProxyInstance(iface.classLoader, arrayOf(iface)) { _, method, _ ->
            if (method.name == "asBinder") carrier else null
        }
        proxies[listener] = proxy
        val added = runCatching { add.invoke(svc, *argsFor(add, iface, proxy, SHELL_PACKAGE)) }
        added.exceptionOrNull()?.let {
            log("clipboard: addPrimaryClipChangedListener failed: ${failureClasses(it)}")
            proxies.remove(listener)
            return false
        }
        return true
    }

    override fun removeClipListener(listener: ClipChangeListener) {
        val proxy = proxies.remove(listener) ?: return
        val svc = binder ?: return
        val remove = api.remove ?: return
        val iface = api.listenerIface ?: return
        runCatching { remove.invoke(svc, *argsFor(remove, iface, proxy, SHELL_PACKAGE)) }
            .onFailure { log("clipboard: removePrimaryClipChangedListener failed: ${failureClasses(it)}") }
    }
}

/**
 * The hidden calls, probed once per process. The chosen signatures are logged
 * here, once, when they are first resolved.
 */
private object ClipboardApi {
    class Calls(
        val listenerIface: Class<*>?,
        val get: Method?,
        val description: Method?,
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
                description = probe(iface, "getPrimaryClipDescription", null),
                set = probe(iface, "setPrimaryClip", ClipData::class.java),
                add = probe(iface, "addPrimaryClipChangedListener", listenerIface),
                remove = probe(iface, "removePrimaryClipChangedListener", listenerIface),
            )
            val names = listOf(
                "getPrimaryClip" to found.get,
                "getPrimaryClipDescription" to found.description,
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
 * first String is the calling [packageName], later Strings are the null
 * attribution tag; ints are user 0 and device 0.
 */
private fun argsFor(m: Method, valueType: Class<*>?, value: Any?, packageName: String): Array<Any?> {
    var strings = 0
    var valueUsed = false
    return Array(m.parameterCount) { i ->
        val p = m.parameterTypes[i]
        when {
            valueType != null && p == valueType && !valueUsed -> {
                valueUsed = true
                value
            }
            p == String::class.java -> if (strings++ == 0) packageName else null
            else -> 0
        }
    }
}

/**
 * The echo rule for app-owned clipboard images (SHARE-2/16): a clip pointing at
 * our own provider is the app's own write, never something to sync back to the
 * Mac.
 */
internal fun isOurClip(uri: Uri?): Boolean = uri?.authority == FILE_PROVIDER_AUTHORITY
