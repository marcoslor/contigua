package dev.pocketdeck.drop

import java.io.File

/**
 * The app-owned folder behind the provider URI (docs/design/dragdrop.md). The
 * trampoline copies every staged drop into it — a path the app process can
 * always read, whatever the storage sandbox does with the staged one — and the
 * oldest entries are dropped so a long-lived phone cannot fill its cache.
 */
object ShareCache {

    /** Newest five files, and never more than 500 MB, of shared copies. */
    const val MAX_FILES = 5
    const val MAX_BYTES = 500L * 1024 * 1024

    /** Copies [source] into [dir] under its own name; null when the copy fails. */
    fun put(dir: File, source: File): File? = runCatching {
        dir.mkdirs()
        val copy = File(dir, source.name)
        source.inputStream().use { input ->
            copy.outputStream().use { output -> input.copyTo(output) }
        }
        evict(dir, keep = copy)
        copy
    }.getOrNull()

    /**
     * Deletes the oldest entries until the folder holds ≤ [MAX_FILES] files and
     * ≤ [MAX_BYTES] bytes together with [keep], which is never deleted: the
     * chooser the caller just showed may still be reading it.
     */
    fun evict(dir: File, keep: File? = null) {
        val entries = dir.listFiles().orEmpty()
            .filter { it.isFile && it.path != keep?.path }
            .sortedBy { it.lastModified() }
        var files = entries.size + if (keep == null) 0 else 1
        var bytes = entries.sumOf { it.length() } + (keep?.length() ?: 0)
        for (entry in entries) {
            if (files <= MAX_FILES && bytes <= MAX_BYTES) return
            val size = entry.length()
            if (entry.delete()) {
                files -= 1
                bytes -= size
            }
        }
    }
}
