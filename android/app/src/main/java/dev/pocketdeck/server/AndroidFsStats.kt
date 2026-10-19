package dev.pocketdeck.server

import android.system.Os
import android.system.OsConstants
import java.io.File

/**
 * `Os.lstat` metadata for `fs.*`: one syscall per entry, the same filesystem
 * view the drop path writes at shell uid (docs/design/files.md §2). The inode
 * is what the Mac keys its items by (`ino:<st_ino>`).
 */
object AndroidFsStats : FsStats {
    override fun stat(file: File): FsMeta? = runCatching {
        val st = Os.lstat(file.path)
        val dir = (st.st_mode and OsConstants.S_IFMT) == OsConstants.S_IFDIR
        // st_mtime is whole seconds; File.lastModified() keeps the milliseconds
        // the etag needs to notice a quick rewrite.
        FsMeta(dir, if (dir) 0 else st.st_size, file.lastModified(), st.st_ino)
    }.getOrNull()
}
