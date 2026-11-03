package dev.pocketdeck.server

import android.content.ClipData
import android.content.ClipDescription
import android.content.ContentResolver
import android.content.Context
import android.net.Uri
import android.os.Binder
import android.os.Environment
import android.os.IBinder
import android.os.Parcel
import android.os.Process
import java.io.File
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
internal class ShellClipboard(
    private val ctx: Context?,
    private val log: (String) -> Unit,
) : ClipboardPort, ClipboardImagePort {

    private val service: Any? by lazy { Hidden.proxy(IFACE, "clipboard") }

    @Volatile private var onChange: ((ClipText) -> Unit)? = null
    private var listener: Any? = null

    override fun getText(): ClipText? {
        val svc = service ?: return null
        val get = ClipboardApi.calls(log).get ?: return null
        val clip = runCatching { get.invoke(svc, *argsFor(get, null, null)) }
            .onFailure { log("clipboard: getPrimaryClip failed: $it") }
            .getOrNull() as? ClipData ?: return null
        if (clip.itemCount == 0) return null
        val text = clip.getItemAt(0).text?.toString() ?: return null
        return ClipText(text, isSensitive(clip.description))
    }

    override fun setText(text: String) {
        val svc = service ?: return
        val set = ClipboardApi.calls(log).set ?: return
        val clip = ClipData.newPlainText(CLIP_LABEL, text)
        runCatching { set.invoke(svc, *argsFor(set, ClipData::class.java, clip)) }
            .onFailure { log("clipboard: setPrimaryClip failed: $it") }
    }

    // ---- images (docs/design/dragdrop.md): first image item only ---------------

    private val resolver: android.content.ContentResolver?
        get() = ctx?.contentResolver

    /**
     * The image bytes of the primary clip, or null when it holds none, its first
     * item is text (text wins: the text sync owns it) or the item's URI is not
     * readable at shell UID. A null is "nothing to sync", never an error.
     */
    override fun readImage(): ClipImage? {
        val svc = service ?: return null
        val get = ClipboardApi.calls(log).get ?: return null
        val clip = runCatching { get.invoke(svc, *argsFor(get, null, null)) }
            .onFailure { log("clipboard: getPrimaryClip failed: $it") }
            .getOrNull() as? ClipData ?: return null
        if (clip.itemCount == 0) return null
        val item = clip.getItemAt(0)
        if (item.text != null) return null
        if (isSensitive(clip.description)) return null
        val contentUri = item.uri ?: return null
        // API 29's filterMimeTypes avoids the per-index walk (countMimeTypes is a
        // later call than this code's floor).
        val mime = clip.description.filterMimeTypes("image/*").firstOrNull() ?: return null
        val source = resolver ?: return null
        val bytes = runCatching { source.openInputStream(contentUri)?.use { s -> s.readBytes() } }
            .onFailure { log("clipboard: unreadable clip image ($mime, $contentUri): $it") }
            .getOrNull() ?: return null
        return ClipImage(bytes, mime.lowercase())
    }

    /**
     * Puts an image file of [DIRECTORY] on the clipboard through a FileProvider
     * URI of the app, which survives the paste into any app that ClipboardService
     * grants the URI to (the provider is public and keyed by the grant flag).
     */
    override fun writeImage(file: File, mime: String, label: String): Boolean {
        // State only: the UID tells whether Shizuku's shell process is the one
        // writing, and the size/kind tell whether the file is really there.
        log("clipboard: image write uid=${Process.myUid()} " +
            "exists=${file.isFile} size=${file.length()} mime=$mime")
        // The URI is built here, not by FileProvider.getUriForFile: that static
        // helper asks PackageManager for the app's resources, and this process
        // is uid 2000 with the app's Context, so the system refuses the pair
        // ("package does not match caller's uid"; emulator boot 3).
        val uri = imageUri(file) ?: run {
            log("clipboard: image outside the drop folder")
            return false
        }
        log("clipboard: image uri scheme=${uri.scheme} own=${uri.authority == AUTHORITY}")
        val clip = imageClip(uri, mime)
        log("clipboard: image clip items=${clip.itemCount} " +
            "mime=${clip.description.getMimeType(0)}")
        val svc = service ?: run {
            log("clipboard: no clipboard service for an image")
            return false
        }
        val set = ClipboardApi.calls(log).set ?: run {
            log("clipboard: no setPrimaryClip for an image")
            return false
        }
        val attempt = runCatching { set.invoke(svc, *argsFor(set, ClipData::class.java, clip)) }
        attempt.exceptionOrNull()?.let {
            log("clipboard: setPrimaryClip(image) failed: ${it.javaClass.simpleName}")
        }
        if (attempt.isSuccess) log("clipboard: image clip ($mime)")
        return attempt.isSuccess
    }

    override fun listen(onChange: (ClipText) -> Unit) {
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

    /** The system's own "this is a secret" mark on a clip's description. */
    private fun isSensitive(description: ClipDescription?): Boolean {
        val extras = description?.extras ?: return false
        return SENSITIVE_KEYS.any { key -> runCatching { extras.getBoolean(key, false) }.getOrDefault(false) }
    }
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

/**
 * The FileProvider URI for an image in the drop folder, exactly as
 * `<external-path name="downloads" path="Download/PocketDeck"/>` maps it.
 *
 * Built by hand because this runs in the shell service process (uid 2000) with
 * the app's Context: `FileProvider.getUriForFile` asks PackageManager for the
 * app's resources, and the package/uid pair is refused (emulator boot 3).
 * [ShellClipboardImageTest] pins the mapping.
 */
internal fun imageUri(file: File): Uri? {
    val root = runCatching {
        File(Environment.getExternalStorageDirectory(), "Download/PocketDeck").canonicalFile
    }.getOrNull() ?: return null
    val canonical = runCatching { file.canonicalFile }.getOrNull() ?: return null
    if (canonical.parentFile != root) return null
    return Uri.Builder()
        .scheme(ContentResolver.SCHEME_CONTENT)
        .authority(FILE_PROVIDER_AUTHORITY)
        .appendPath("downloads")
        .appendPath(canonical.name)
        .build()
}

private const val IFACE = "android.content.IClipboard"
private const val LISTENER_IFACE = "android.content.IOnPrimaryClipChangedListener"
private const val SHELL_PACKAGE = "com.android.shell"
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
private const val AUTHORITY = FILE_PROVIDER_AUTHORITY

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
