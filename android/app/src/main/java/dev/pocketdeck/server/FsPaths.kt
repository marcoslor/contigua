package dev.pocketdeck.server

import dev.pocketdeck.proto.Crypto
import java.io.File
import java.nio.file.Files
import java.nio.file.attribute.BasicFileAttributes
import java.security.MessageDigest

/**
 * One refused `fs.*` request: a wire error code and a message that names no
 * path (docs/design/files.md §4: logs and errors carry counts, never names).
 */
class FsFailure(val code: String, message: String) : Exception(message)

/**
 * Path rules for the phone's shared storage (docs/PROTOCOL.md "Phone files").
 *
 * The root is resolved once, at construction. Every request speaks a path
 * relative to it (`""` = the root); the resolved file is canonicalized and must
 * still sit under the canonical root, so neither `..` nor a symlink can leave
 * it. `Android/…` and dot-prefixed top-level entries are refused: at shell uid
 * the phone can read every app's private storage there, and a Finder location
 * must show what a person calls phone storage, not what only uid 2000 sees.
 */
class FsPaths(val root: File, private val stats: FsStats = FsStats.Default) {

    /** The root's canonical path, with no trailing separator. */
    val rootPath: String = canonical(root)

    /** The root as the canonical file every relative path hangs off. */
    fun rootFile(): File = File(rootPath)

    /**
     * Absolute path [raw] resolved under the root, or [FsFailure]:
     * `fs_denied` for every shape rule and for a target outside the root.
     * Existence is not checked here; callers answer `fs_not_found`.
     */
    fun resolve(raw: String?): File {
        val path = raw ?: ""
        if (path.startsWith("/")) throw denied("absolute path")
        if (path.indexOf('\u0000') >= 0) throw denied("NUL in path")
        if (path.indexOf('\\') >= 0) throw denied("backslash in path")
        if (path.toByteArray(Charsets.UTF_8).size > MAX_PATH_BYTES) throw denied("path too long")
        if (path.isEmpty()) return rootFile()
        val parts = path.split('/')
        if (parts.size > MAX_COMPONENTS) throw denied("too many components")
        for (part in parts) {
            if (part.isEmpty() || part == "." || part == "..") throw denied("bad component")
            // A write's staging file is ours, never an item a Mac may read,
            // overwrite or delete by name.
            if (isTempName(part)) throw denied("staging name")
        }
        if (parts[0].startsWith(".")) throw denied("hidden entry")
        if (parts[0] == ANDROID) throw denied("Android")
        val file = File(rootFile(), path)
        val canonicalPath = canonical(file)
        if (canonicalPath != rootPath && !canonicalPath.startsWith(rootPath + File.separator)) {
            throw denied("outside the root")
        }
        // A symlink inside the root may still point at Android/… or a hidden
        // top-level entry: apply the shape rule to where it really lands.
        if (canonicalPath != rootPath) {
            val top = canonicalPath.substring(rootPath.length + 1).substringBefore(File.separatorChar)
            if (top.startsWith(".") || top == ANDROID) throw denied("link to a hidden entry")
        }
        return File(canonicalPath)
    }

    /** Metadata for [file], or null when it is gone. */
    fun meta(file: File): FsMeta? = stats.stat(file)

    /** The item a listing or stat report carries (docs/PROTOCOL.md "Phone files"). */
    fun item(file: File, meta: FsMeta = stats.stat(file) ?: throw notFound()): FsItem =
        FsItem(
            name = if (file.path == rootPath) "" else file.name,
            dir = meta.dir,
            size = meta.size,
            mtime = meta.mtimeMs,
            ino = meta.ino,
            etag = etag(meta),
        )

    /**
     * The weak version of docs/design/files.md §3: 16 bytes of `(ino, size,
     * mtime)` as 32 hex characters. Any metadata change moves it; content is
     * never hashed on a list.
     */
    fun etag(meta: FsMeta): String = etag(meta.ino, meta.size, meta.mtimeMs)

    companion object {
        const val MAX_PATH_BYTES = 4096
        const val MAX_COMPONENTS = 32
        const val ANDROID = "Android"
        /** A write's hidden temp: `<TEMP_PREFIX><random><TEMP_SUFFIX>`. */
        const val TEMP_PREFIX = ".pocketdeck-"
        const val TEMP_SUFFIX = ".part"

        fun isTempName(name: String): Boolean =
            name.length > TEMP_PREFIX.length + TEMP_SUFFIX.length &&
                name.startsWith(TEMP_PREFIX) && name.endsWith(TEMP_SUFFIX)

        fun denied(why: String) = FsFailure("fs_denied", "denied: $why")
        fun notFound() = FsFailure("fs_not_found", "no such file")
        fun notADir() = FsFailure("fs_not_a_dir", "not a directory")
        fun stale() = FsFailure("fs_stale", "the file changed")
        fun busy() = FsFailure("fs_busy", "too many reads")

        /** Canonical path, or the absolute one when the platform refuses to resolve it. */
        private fun canonical(file: File): String = try {
            file.canonicalPath
        } catch (e: Exception) {
            file.absolutePath
        }

        fun etag(ino: Long, size: Long, mtimeMs: Long): String {
            val digest = MessageDigest.getInstance("SHA-256")
                .digest("$ino:$size:$mtimeMs".toByteArray(Charsets.UTF_8))
            return Crypto.toHex(digest).substring(0, 32)
        }
    }
}

/** What a stat says about one entry; `size` is 0 for directories. */
data class FsMeta(val dir: Boolean, val size: Long, val mtimeMs: Long, val ino: Long)

/** Metadata source; the JVM tests supply their own, the phone uses `Os.lstat`. */
fun interface FsStats {
    fun stat(file: File): FsMeta?

    companion object {
        /** Plain JVM attributes (a temp folder stands in for /sdcard in tests). */
        val Default = FsStats { file ->
            val attrs = try {
                Files.readAttributes(file.toPath(), BasicFileAttributes::class.java)
            } catch (e: Exception) {
                return@FsStats null
            }
            val ino = try {
                (Files.getAttribute(file.toPath(), "unix:ino") as? Number)?.toLong() ?: 0L
            } catch (e: Exception) {
                0L
            }
            val dir = attrs.isDirectory
            FsMeta(dir, if (dir) 0 else attrs.size(), attrs.lastModifiedTime().toMillis(), ino)
        }
    }
}

/** One entry of `fs.items`/`fs.item`: no path, the parent is implicit. */
data class FsItem(
    val name: String,
    val dir: Boolean,
    val size: Long,
    val mtime: Long,
    val ino: Long,
    val etag: String,
) {
    fun toJson(): Map<String, Any?> = mapOf(
        "name" to name,
        "dir" to dir,
        "size" to size,
        "mtime" to mtime,
        "ino" to ino,
        "etag" to etag,
    )
}
