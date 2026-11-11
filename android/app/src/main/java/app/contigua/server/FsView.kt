package app.contigua.server

import app.contigua.proto.Crypto
import app.contigua.proto.Json
import java.io.File
import java.security.MessageDigest

/**
 * Read-only view of the shared storage for `fs.list` / `fs.stat` / `fs.digest`
 * (docs/PROTOCOL.md "Phone files"). Stateless across requests: a page is a
 * sorted slice of a fresh listing, and the cursor is the next index.
 *
 * A page holds at most [maxPageItems] items and at most [maxPageBytes] of JSON,
 * so a folder the person never tidied up cannot blow the frame cap.
 *
 * The listing filter is the one definition of what a folder contains: our own
 * staging files, Android's transient `.trashed-*`/`.pending-*` entries (at any
 * depth) and, at the root, the dot entries and `Android/`.
 */
class FsView(
    val paths: FsPaths,
    private val maxPageItems: Int = MAX_PAGE_ITEMS,
    private val maxPageBytes: Int = MAX_PAGE_BYTES,
) {
    /**
     * One page of a listing; `next` is null on the last page, which also
     * carries the folder's digest so a complete listing can refresh the Mac's
     * record (FILES-35).
     */
    data class Page(val items: List<FsItem>, val next: String?, val digest: String? = null)

    /**
     * Children of [path], starting at [page] (absent or unknown = the first).
     * The visible entries are the same set [digest] hashes: a transient entry
     * is not an item, so it fills no page and moves no cursor.
     */
    fun list(path: String?, page: String?): Page {
        val dir = paths.resolve(path)
        val meta = paths.meta(dir) ?: throw FsPaths.notFound()
        if (!meta.dir) throw FsPaths.notADir()
        val names = visible(dir).sortedBy { it.name }
        val start = page?.toIntOrNull()?.takeIf { it in 0 until names.size } ?: 0
        val items = ArrayList<FsItem>(minOf(names.size - start, maxPageItems))
        var bytes = 0
        var index = start
        while (index < names.size && items.size < maxPageItems) {
            val child = names[index]
            index++
            val childMeta = paths.meta(child) ?: continue // deleted since the listing
            val item = paths.item(child, childMeta)
            val size = Json.encode(item.toJson()).length + 1
            if (items.isNotEmpty() && bytes + size > maxPageBytes) {
                // The page is full by size: this child starts the next one.
                index--
                break
            }
            items += item
            bytes += size
        }
        val next = if (index < names.size) index.toString() else null
        return Page(items, next, if (next == null) digest(dir) else null)
    }

    /** Metadata of one entry; a directory answers like the root (`name` ""). */
    fun stat(path: String?): FsItem {
        val file = paths.resolve(path)
        val meta = paths.meta(file) ?: throw FsPaths.notFound()
        return paths.item(file, meta)
    }

    /**
     * The folder's digest (FILES-35): the first 16 bytes, as hex, of SHA-256
     * over its visible entries in name-byte order, each written
     * `name \0 ino \0 size \0 mtime \n`. One readdir and one stat per entry, no
     * recursion; a path that is not a folder answers `fs_not_found`.
     */
    fun digest(path: String?): String {
        val dir = paths.resolve(path)
        val meta = paths.meta(dir) ?: throw FsPaths.notFound()
        if (!meta.dir) throw FsPaths.notFound()
        return digest(dir)
    }

    private fun digest(dir: File): String {
        val names = visible(dir).sortedWith { a, b -> compareNames(a.name, b.name) }
        val hash = MessageDigest.getInstance("SHA-256")
        for (child in names) {
            val meta = paths.meta(child) ?: continue // deleted since the readdir
            hash.update(child.name.toByteArray(Charsets.UTF_8))
            hash.update(NUL)
            hash.update(meta.ino.toString().toByteArray(Charsets.US_ASCII))
            hash.update(NUL)
            hash.update(meta.size.toString().toByteArray(Charsets.US_ASCII))
            hash.update(NUL)
            hash.update(meta.mtimeMs.toString().toByteArray(Charsets.US_ASCII))
            hash.update(NEWLINE)
        }
        return Crypto.toHex(hash.digest()).substring(0, 32)
    }

    /** The entries a person sees: one readdir, the same filter for every page. */
    private fun visible(dir: File): List<File> {
        val children = dir.listFiles() ?: throw FsPaths.denied("unreadable directory")
        val topLevel = dir.path == paths.rootPath
        return children.filter { child ->
            !FsPaths.isTempName(child.name) &&
                !FsPaths.isTransientName(child.name) &&
                (!topLevel || !(child.name.startsWith(".") || child.name == FsPaths.ANDROID))
        }
    }

    /** Name-byte order (UTF-8), not the platform's UTF-16 string order. */
    private fun compareNames(a: String, b: String): Int {
        val left = a.toByteArray(Charsets.UTF_8)
        val right = b.toByteArray(Charsets.UTF_8)
        for (index in 0 until minOf(left.size, right.size)) {
            val diff = (left[index].toInt() and 0xFF) - (right[index].toInt() and 0xFF)
            if (diff != 0) return diff
        }
        return left.size - right.size
    }

    companion object {
        const val MAX_PAGE_ITEMS = 1000
        const val MAX_PAGE_BYTES = 1 shl 20
        /** At most this many paths in one `fs.digest` (the watch cap). */
        const val MAX_DIGEST_PATHS = 64
        private val NUL = 0.toByte()
        private val NEWLINE = 10.toByte()
    }
}
