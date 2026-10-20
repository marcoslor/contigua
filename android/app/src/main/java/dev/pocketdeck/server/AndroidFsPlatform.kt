package dev.pocketdeck.server

import android.content.Context
import java.io.File
import java.nio.file.FileAlreadyExistsException
import java.nio.file.Files
import java.nio.file.StandardCopyOption

/**
 * The phone's half of [FsPlatform] (docs/design/files.md §2). At shell uid the
 * shared-storage mount routes a rename through MediaProvider, so [rename] is a
 * plain `renameTo` on this filesystem — the mount does the database work — and
 * [plainRename] is the `java.nio` move for the cases the mount refuses.
 *
 * [scan] hands the finished path to MediaScannerConnection, the drop path's
 * habit: a file we created with `File` is invisible to other apps until the
 * scanner has seen it.
 */
class AndroidFsPlatform(
    /** The app's context (Shizuku hands it in): only the scanner needs it. */
    private val app: Context?,
    private val log: (String) -> Unit = {},
) : FsPlatform {

    override fun rename(from: File, to: File, replace: Boolean): Boolean {
        return try {
            // `renameTo` replaces silently. A caller that must not replace gets
            // one check right here; the window left is the gap between it and
            // the syscall, not the whole transfer.
            if (!replace && to.exists()) throw FileAlreadyExistsException(to.path)
            from.renameTo(to)
        } catch (e: FileAlreadyExistsException) {
            throw e
        } catch (e: Exception) {
            log("fs: rename failed: ${e.javaClass.simpleName}")
            false
        }
    }

    override fun plainRename(from: File, to: File, replace: Boolean): Boolean {
        return try {
            if (replace) {
                Files.move(from.toPath(), to.toPath(), StandardCopyOption.REPLACE_EXISTING)
            } else {
                // Without REPLACE_EXISTING the kernel refuses a taken name, so
                // this path has no window at all.
                Files.move(from.toPath(), to.toPath())
            }
            true
        } catch (e: FileAlreadyExistsException) {
            throw e
        } catch (e: Exception) {
            log("fs: plain rename failed: ${e.javaClass.simpleName}")
            false
        }
    }

    override fun scan(files: List<File>) {
        val app = app ?: return
        if (files.isEmpty()) return
        runCatching {
            android.media.MediaScannerConnection.scanFile(
                app, files.map { it.absolutePath }.toTypedArray(), null, null,
            )
        }.onFailure { log("fs: media scan failed: ${it.javaClass.simpleName}") }
    }

    override fun setLastModified(file: File, mtimeMs: Long): Boolean =
        runCatching { file.setLastModified(mtimeMs) }.getOrDefault(false)
}
