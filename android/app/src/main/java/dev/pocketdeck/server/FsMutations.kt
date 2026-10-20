package dev.pocketdeck.server

import dev.pocketdeck.proto.Json
import java.io.File
import java.nio.file.Files

/**
 * The fs.* operations that change the tree without moving bytes: `fs.move`,
 * `fs.delete`, `fs.mkdir`, `fs.setAttrs` (docs/PROTOCOL.md "Phone files").
 *
 * Every path goes through [FsPaths] first, so the Android/ and dot-prefixed
 * rules and the canonical-root rule are the same ones the read side uses. A
 * rename and a move use [FsPlatform]: the media-aware rename first, the plain
 * one as the fallback, with a scan of what moved so MediaStore (and the Gallery)
 * keeps up. Nothing here logs a name: codes, depths and counts only.
 */
class FsMutations(
    private val paths: FsPaths,
    private val platform: FsPlatform,
    private val log: (String) -> Unit = {},
) {
    /** `fs.move`: rename or move one entry, keeping its bytes. */
    fun move(fromPath: String?, toPath: String?, etag: String?): FsItem {
        val from = paths.resolve(fromPath)
        val meta = paths.meta(from) ?: throw FsPaths.notFound()
        if (from.path == paths.rootPath) throw FsPaths.denied("the root does not move")
        if (etag != null && etag != paths.etag(meta)) throw FsPaths.stale()
        val to = paths.resolve(toPath)
        if (to.path == from.path) return paths.item(from, meta)
        if (paths.meta(to) != null) throw FsFailure("fs_exists", "that name is taken")
        // Moving a folder onto its own child can never work and would leave the
        // tree in two pieces; the shape rules would not catch it.
        if (meta.dir && to.path.startsWith(from.path + File.separator)) {
            throw FsPaths.denied("a folder cannot move into itself")
        }
        val renamed = platform.rename(from, to) || platform.plainRename(from, to)
        if (!renamed) throw FsPaths.denied("the move failed")
        runCatching { platform.scan(listOf(to, from)) }
        log("fs: move ok dir=${meta.dir}")
        return paths.item(to)
    }

    /** `fs.delete`: one file, or a folder when empty or [recursive]. */
    fun delete(path: String?, recursive: Boolean) {
        val file = paths.resolve(path)
        if (file.path == paths.rootPath) throw FsPaths.denied("the root does not delete")
        val meta = paths.meta(file) ?: throw FsPaths.notFound()
        if (meta.dir) {
            val children = file.listFiles().orEmpty()
            if (children.isNotEmpty() && !recursive) {
                throw FsPaths.denied("the folder is not empty")
            }
            if (!deleteTree(file)) throw FsPaths.denied("the delete failed")
        } else if (!file.delete()) {
            throw FsPaths.denied("the delete failed")
        }
        log("fs: delete ok dir=${meta.dir} recursive=$recursive")
    }

    /** `fs.mkdir`: one folder, never a chain. */
    fun mkdir(path: String?): FsItem {
        val file = paths.resolve(path)
        if (file.path == paths.rootPath) throw FsFailure("fs_exists", "that name is taken")
        if (paths.meta(file) != null) throw FsFailure("fs_exists", "that name is taken")
        val parent = file.parentFile ?: throw FsPaths.notFound()
        val parentMeta = paths.meta(parent) ?: throw FsPaths.notFound()
        if (!parentMeta.dir) throw FsPaths.notADir()
        if (!file.mkdir()) throw FsPaths.denied("could not create the folder")
        log("fs: mkdir ok")
        return paths.item(file)
    }

    /** `fs.setAttrs`: the date, best effort (a platform that refuses is not a failure). */
    fun setAttrs(path: String?, mtime: Long?): FsItem {
        val file = paths.resolve(path)
        paths.meta(file) ?: throw FsPaths.notFound()
        if (mtime != null && mtime >= 0) {
            if (!platform.setLastModified(file, mtime)) log("fs: setAttrs refused")
        } else {
            log("fs: setAttrs without a time")
        }
        return paths.item(file)
    }

    /**
     * Deletes [file] and its contents. A symlink is removed as itself, never
     * followed: the person's tree is not a way out of the root.
     */
    private fun deleteTree(file: File): Boolean {
        if (!isLink(file) && file.isDirectory) {
            for (child in file.listFiles().orEmpty()) {
                if (!deleteTree(child)) return false
            }
        }
        return file.delete()
    }

    private fun isLink(file: File): Boolean = runCatching {
        Files.isSymbolicLink(file.toPath())
    }.getOrDefault(false)

    companion object {
        /** A `fs.move`/`fs.delete`/`fs.mkdir`/`fs.setAttrs` request id, or null. */
        fun id(obj: Map<String, Any?>): Long? =
            (obj["id"] as? Number)?.toLong()?.takeIf { it in 1..0xFFFF_FFFFL }

        fun mtime(obj: Map<String, Any?>): Long? = Json.long(obj["mtime"])
    }
}
