package dev.pocketdeck.server

import java.io.File

/**
 * Validation and naming for a file drop (docs/design/dragdrop.md). Nothing here
 * trusts the Mac: the name is reduced to what a Downloads folder shows, and the
 * payload is only kept when the announced SHA-256 matches.
 */
object DropPolicy {
    /** 200 MiB, counted while the data arrives (docs/PROTOCOL.md "Drop Mac → phone"). */
    const val MAX_FILE_BYTES = 200L * 1024 * 1024

    /** Writes land in this folder and nowhere else (the brief's one path). */
    var DIRECTORY = "/sdcard/Download/PocketDeck"

    private val SHA = Regex("[0-9a-f]{64}")
    const val NAME_MAX_CHARS = 100

    /** A gesture's batch: the Mac sends each file's position on `drop.start`. */
    const val MAX_BATCH_FILES = 1000

    /** The package of the app window a drop landed on (SHARE-17). */
    private val PACKAGE = Regex("[A-Za-z][A-Za-z0-9_]*(\\.[A-Za-z][A-Za-z0-9_]*)+")
    const val TARGET_MAX_BYTES = 255

    /** The extension is split off before cleaning, so a foreign name keeps "jpg", not its stem. */
    class Name(val stem: String, val ext: String) {
        override fun toString(): String = if (ext.isEmpty()) stem else "$stem.$ext"
    }

    class Rejected(val code: String, msg: String) : Exception(msg)

    /** The announced drop, after its name is sanitised and the rest is shaped up. */
    data class Desk(
        val name: Name,
        val size: Long,
        val mime: String,
        val sha256: String,
        /** The app window's package; null on the Deck, a phone window and a link. */
        val target: String? = null,
        /** This file's position in the gesture, 1-based. */
        val index: Int = 1,
        /** How many files the gesture carries. */
        val count: Int = 1,
    )

    /** A `drop.start` plus its id: every reply carries the id it belongs to. */
    data class Transfer(val id: Long, val desk: Desk)

    fun parse(obj: Map<String, Any?>): Transfer {
        val id = (obj["id"] as? Number)?.toLong() ?: 0L
        val size = (obj["size"] as? Number)?.toLong() ?: -1L
        val sha = (obj["sha256"] as? String)?.lowercase() ?: ""
        val mime = (obj["mime"] as? String)?.takeIf { it.isNotEmpty() } ?: "application/octet-stream"
        val rawName = obj["name"] as? String
        if (id <= 0 || id > 0xFFFF_FFFFL || rawName == null) {
            throw Rejected("bad_request", "drop.start needs an id, name, size and sha256")
        }
        if (size <= 0 || size > MAX_FILE_BYTES) {
            throw Rejected("too_large", "size must be 1..$MAX_FILE_BYTES bytes")
        }
        if (!SHA.matches(sha)) throw Rejected("bad_request", "sha256 must be 64 lowercase hex")
        val target = when (val raw = obj["target"]) {
            null -> null
            is String -> packageName(raw)
                ?: throw Rejected("bad_request", "target must be a package name")
            else -> throw Rejected("bad_request", "target must be a package name")
        }
        val index = batchField(obj, "index") ?: 1L
        val count = batchField(obj, "count") ?: 1L
        if (count !in 1..MAX_BATCH_FILES.toLong() || index !in 1..count) {
            throw Rejected("bad_request", "index must be 1..count (at most $MAX_BATCH_FILES files)")
        }
        return Transfer(id, Desk(sanitize(rawName, mime), size, mime, sha, target,
                                 index.toInt(), count.toInt()))
    }

    /** The target when it is a package name of at most 255 bytes, else null. */
    fun packageName(raw: String?): String? = raw?.takeIf {
        it.toByteArray(Charsets.UTF_8).size <= TARGET_MAX_BYTES && PACKAGE.matches(it)
    }

    /** An optional batch field: absent is null, anything but a number is refused. */
    private fun batchField(obj: Map<String, Any?>, key: String): Long? = when (val raw = obj[key]) {
        null -> null
        is Number -> raw.toLong()
        else -> throw Rejected("bad_request", "$key must be a number")
    }

    /**
     * The phone's name reduced to `[A-Za-z0-9 ._-]`, no leading dot, at most [NAME_MAX_CHARS]
     * characters, with an extension from the MIME type when it has none — the same shape as
     * the share-in receiver applies on the Mac.
     */
    fun sanitize(raw: String, mime: String): Name {
        val last = raw.split('/', '\\').last()
        var stem = last
        var ext = ""
        val dot = last.lastIndexOf('.')
        if (dot > 0 && last.length - dot <= 7) {
            stem = last.substring(0, dot)
            ext = last.substring(dot + 1)
        }
        ext = ext.filter { it in allowedChars }.trim('.').lowercase()
        if (ext.isEmpty()) ext = EXTENSIONS[mime.lowercase()] ?: ""
        stem = clean(stem)
        if (stem.isEmpty()) stem = "File"
        val room = NAME_MAX_CHARS - (if (ext.isEmpty()) 0 else ext.length + 1)
        stem = stem.take(room).trim(' ', '.')
        if (stem.isEmpty()) stem = "File"
        return Name(stem, ext)
    }

    private fun clean(part: String): String {
        val allowed = part.filter { it in allowedChars }.trim(' ', '.')
        return if (allowed.startsWith(".")) allowed.drop(1) else allowed
    }

    private val allowedChars = ('a'..'z') + ('A'..'Z') + ('0'..'9') + listOf(' ', '.', '_', '-')

    private val EXTENSIONS = mapOf(
        "application/pdf" to "pdf", "text/plain" to "txt", "application/zip" to "zip",
        "image/jpeg" to "jpg", "image/png" to "png", "image/gif" to "gif",
        "image/webp" to "webp", "video/mp4" to "mp4", "audio/mpeg" to "mp3",
        "application/vnd.android.package-archive" to "apk",
    )

    /**
     * The hidden partial file of a drop, keyed by the announced `(size, sha256)` so a later
     * `resume` on the same file finds it; dot-named, so the folder listing stays clean.
     */
    fun tempFile(desk: Desk): File = File(DIRECTORY, ".part-${desk.size}-${desk.sha256.take(12)}")

    /**
     * `name` in `directory`, or "stem 2.ext", "stem 3.ext"… when taken (the share-in
     * receiver's rule).
     */
    fun target(dir: String, name: Name): String {
        val first = File(dir, name.toString())
        if (!first.exists()) return first.path
        var n = 2
        while (File(dir, "${name.stem} $n${if (name.ext.isEmpty()) "" else "."}${name.ext}").exists()) n++
        return File(dir, "${name.stem} $n${if (name.ext.isEmpty()) "" else "."}${name.ext}").path
    }
}
