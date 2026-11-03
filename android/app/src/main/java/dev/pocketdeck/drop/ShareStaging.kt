package dev.pocketdeck.drop

import android.os.ParcelFileDescriptor
import dev.pocketdeck.server.DropPolicy
import dev.pocketdeck.server.failureClasses
import java.io.File
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/**
 * The names the shell has staged for one pending SEND (docs/design/dragdrop.md).
 * The app can stat a shell-written file on shared storage but not open it
 * (boot 5), so the shell opens it and hands the app a file descriptor through
 * `IDeckService.openStaged`.
 *
 * A name is valid only while it is in the set: 60 s after staging, or as soon
 * as it is opened, and the file is unlinked then — the open descriptor keeps
 * the bytes alive for the reader.
 */
class ShareStaging(
    private val ttlMs: Long = TTL_MS,
    private val clock: () -> Long = System::currentTimeMillis,
    private val log: (String) -> Unit = {},
) {
    private class Entry(val file: File, val expiresAt: Long)

    private val pending = ConcurrentHashMap<String, Entry>()
    private val sweeper = Executors.newSingleThreadScheduledExecutor { runnable ->
        Thread(runnable, "pocketdeck-staging").apply { isDaemon = true }
    }

    fun expect(name: String, file: File) {
        val target = ShareRequest.parse(name, null) ?: run {
            log("share staging: bad name refused")
            return
        }
        pending[target.name] = Entry(file, clock() + ttlMs)
        runCatching { sweeper.schedule({ sweep() }, ttlMs, TimeUnit.MILLISECONDS) }
    }

    fun open(name: String): ParcelFileDescriptor? {
        val target = ShareRequest.parse(name, null) ?: return null
        val entry = pending.remove(target.name) ?: return null
        if (clock() >= entry.expiresAt ||
            !entry.file.isFile ||
            entry.file.length() > DropPolicy.MAX_FILE_BYTES) {
            delete(entry)
            return null
        }
        val descriptor = runCatching {
            ParcelFileDescriptor.open(entry.file, ParcelFileDescriptor.MODE_READ_ONLY)
        }.onFailure {
            log("share staging: open failed: ${failureClasses(it)}")
        }.getOrNull()
        // The fd is the reader's copy; the shell must not leave the file behind
        // either way. If the open failed the file cannot be served.
        delete(entry)
        return descriptor
    }

    /** Deletes every entry past its deadline. */
    fun sweep() {
        val now = clock()
        for ((name, entry) in pending) {
            if (now >= entry.expiresAt && pending.remove(name, entry)) delete(entry)
        }
    }

    /** Deletes every staged copy but keeps the scheduler for the next server. */
    fun clear() {
        pending.keys.forEach { name ->
            pending.remove(name)?.let { delete(it) }
        }
    }

    /** Deletes every staged copy and stops the timer (the service is going away). */
    fun close() {
        clear()
        sweeper.shutdownNow()
    }

    private fun delete(entry: Entry) {
        runCatching { entry.file.delete() }
    }

    companion object {
        const val TTL_MS = 60_000L
    }
}
