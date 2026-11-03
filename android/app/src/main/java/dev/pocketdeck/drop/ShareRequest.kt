package dev.pocketdeck.drop

import android.content.Context
import dev.pocketdeck.server.DropPolicy
import java.io.File

/**
 * The SEND step of a drop (docs/design/dragdrop.md). The grant for one of our
 * provider URIs has to come from our own UID, so the shell process stages the
 * finished file in our external `files/shared/` folder and starts the exported
 * [ShareTrampoline] with the bare name. The trampoline is reachable by any app,
 * so nothing an outside caller puts in the intent is trusted: [parse] is the
 * whole check, and it works on the raw strings only.
 */
object ShareRequest {

    /** A checked trampoline request: a bare name inside the staging folder, and a mime type. */
    class Target(val name: String, val mime: String)

    const val DEFAULT_MIME = "application/octet-stream"

    /**
     * The folder the shell process stages a finished drop in, and only it writes.
     * It has to be the app's external media folder: the app may read anything the
     * shell puts there, while the same file under `files/` is refused by the
     * storage sandbox (a file the app does not own under Android/data/<pkg> is
     * inaccessible to the app, even in its own package folder).
     */
    fun stageDir(context: Context): File? {
        val media = context.getExternalMediaDirs().firstOrNull { it != null } ?: return null
        return File(media, "shared")
    }

    /** The app-owned copy of the shared files: the one folder the provider serves. */
    fun cacheDir(context: Context): File = File(context.cacheDir, "shared")

    /**
     * The request, or null when it must be refused. [name] must be a bare file
     * name that [DropPolicy.sanitize] leaves untouched — no separators, no
     * leading dot, no character outside the drop alphabet, at most
     * [DropPolicy.NAME_MAX_CHARS] characters — and [mime] either absent or a
     * plain `type/subtype`.
     */
    /**
     * One gesture's checked request (SHARE-17): 1 to [ShareCache.MAX_FILES]
     * bare names and their matching mime types. Null when any one is refused,
     * so the trampoline shares all of them or none.
     */
    fun parseBatch(names: List<String>?, mimes: List<String>?): List<Target>? {
        val raw = names?.takeIf { it.isNotEmpty() } ?: return null
        if (raw.size > ShareCache.MAX_FILES) return null
        val types = when {
            mimes.isNullOrEmpty() -> List(raw.size) { DEFAULT_MIME }
            mimes.size == raw.size -> mimes
            else -> return null
        }
        return raw.zip(types).map { (name, mime) -> parse(name, mime) ?: return null }
    }

    /** The window's package when it is a package name; anything else means the chooser. */
    fun parseTarget(raw: String?): String? = DropPolicy.packageName(raw)

    fun parse(name: String?, mime: String?): Target? {
        val raw = name?.takeIf { it.isNotEmpty() } ?: return null
        val type = mime?.takeIf { it.isNotEmpty() } ?: DEFAULT_MIME
        if (!MIME.matches(type)) return null
        if (raw != DropPolicy.sanitize(raw, type).toString()) return null
        return Target(raw, type)
    }

    /** `text/plain` with the usual suffix characters, nothing else (no parameters). */
    private val MIME = Regex("[A-Za-z0-9][A-Za-z0-9.+-]*/[A-Za-z0-9][A-Za-z0-9.+-]*")
}
