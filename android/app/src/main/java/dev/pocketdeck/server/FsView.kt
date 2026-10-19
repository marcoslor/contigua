package dev.pocketdeck.server

import dev.pocketdeck.proto.Json

/**
 * Read-only view of the shared storage for `fs.list` / `fs.stat`
 * (docs/PROTOCOL.md "Phone files"). Stateless across requests: a page is a
 * sorted slice of a fresh listing, and the cursor is the next index.
 *
 * A page holds at most [maxPageItems] items and at most [maxPageBytes] of JSON,
 * so a folder the person never tidied up cannot blow the frame cap.
 */
class FsView(
    val paths: FsPaths,
    private val maxPageItems: Int = MAX_PAGE_ITEMS,
    private val maxPageBytes: Int = MAX_PAGE_BYTES,
) {
    /** One page of a listing; `next` is null on the last page. */
    data class Page(val items: List<FsItem>, val next: String?)

    /**
     * Children of [path], starting at [page] (absent or unknown = the first).
     * The root listing hides `Android` and dot-prefixed entries; a direct
     * request for one is refused by [FsPaths.resolve].
     */
    fun list(path: String?, page: String?): Page {
        val dir = paths.resolve(path)
        val meta = paths.meta(dir) ?: throw FsPaths.notFound()
        if (!meta.dir) throw FsPaths.notADir()
        val children = dir.listFiles() ?: throw FsPaths.denied("unreadable directory")
        val topLevel = dir.path == paths.rootPath
        val names = children
            .filter { child ->
                !topLevel || !(child.name.startsWith(".") || child.name == FsPaths.ANDROID)
            }
            .sortedBy { it.name }
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
        return Page(items, if (index < names.size) index.toString() else null)
    }

    /** Metadata of one entry; a directory answers like the root (`name` ""). */
    fun stat(path: String?): FsItem {
        val file = paths.resolve(path)
        val meta = paths.meta(file) ?: throw FsPaths.notFound()
        return paths.item(file, meta)
    }

    companion object {
        const val MAX_PAGE_ITEMS = 1000
        const val MAX_PAGE_BYTES = 1 shl 20
    }
}
