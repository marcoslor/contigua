package app.contigua.server

import android.os.ParcelFileDescriptor
import app.contigua.server.failureClasses
import java.io.File
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledExecutorService
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.TimeUnit

/**
 * The shell's side of the clipboard image hand-off (SHARE-2/16): the app owns
 * the FileProvider and the clipboard write, so it must also own the bytes. The
 * shell writes them to a scratch file it alone can open, hands the app the open
 * descriptor and waits at most 3 s for `IDeckService.clipImageDone`; no
 * callback, no descriptor or no answer is a refusal.
 */
class ClipImageBridge(
    private val callback: () -> ClipImageCallback?,
    /** A folder the shell can write and the app reads only through the fd; null refuses. */
    private val scratch: () -> File? = { null },
    private val timeoutMs: Long = TIMEOUT_MS,
    private val scheduler: ScheduledExecutorService = defaultScheduler(),
    private val log: (String) -> Unit = {},
) {
    fun interface ClipImageCallback {
        fun onClipImage(id: String, mime: String, data: ParcelFileDescriptor)
    }

    private class Pending(
        val done: (Boolean) -> Unit,
        val timer: ScheduledFuture<*>,
    )

    private val pending = ConcurrentHashMap<String, Pending>()

    /**
     * Sends the bytes to the app through an open fd and calls [done] once with
     * its answer or with false after the timeout. Never blocks the session
     * reader beyond the local write.
     */
    fun offer(id: String, mime: String, bytes: ByteArray, done: (Boolean) -> Unit) {
        val target = callback() ?: return done(false)
        val dir = scratch() ?: return done(false)
        val file = runCatching {
            dir.mkdirs()
            File.createTempFile("clip-", ".img", dir)
        }.getOrNull() ?: return done(false)
        val read = runCatching {
            file.writeBytes(bytes)
            ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY)
        }.onFailure {
            log("clip image: fd failed: ${failureClasses(it)}")
            runCatching { file.delete() }
        }.getOrNull() ?: return done(false)
        // The app gets its own descriptor from the binder; the shell's copy is
        // unlinked at once so a timeout or a dead app leaves nothing behind.
        runCatching { file.delete() }
        val timer = runCatching {
            scheduler.schedule({ finish(id, false) }, timeoutMs, TimeUnit.MILLISECONDS)
        }.getOrNull()
        if (timer == null) {
            closeQuietly(read)
            return done(false)
        }
        pending[id] = Pending(done, timer)
        val sent = runCatching { target.onClipImage(id, mime, read) }
            .onFailure { log("clip image: callback failed: ${failureClasses(it)}") }
            .isSuccess
        closeQuietly(read)
        if (!sent) finish(id, false)
    }

    /** The app's answer (`IDeckService.clipImageDone`); unknown or late ids are ignored. */
    fun answer(id: String, ok: Boolean) = finish(id, ok)

    fun close() {
        pending.keys.forEach { finish(it, false) }
        scheduler.shutdownNow()
    }

    private fun finish(id: String, ok: Boolean) {
        val entry = pending.remove(id) ?: return
        entry.timer.cancel(false)
        runCatching { entry.done(ok) }
            .onFailure { log("clip image: answer failed: ${failureClasses(it)}") }
    }

    private fun closeQuietly(descriptor: ParcelFileDescriptor) {
        runCatching { descriptor.close() }
    }

    companion object {
        const val TIMEOUT_MS = 3_000L

        private fun defaultScheduler(): ScheduledExecutorService =
            Executors.newSingleThreadScheduledExecutor { runnable ->
                Thread(runnable, "contigua-clip-answer").apply { isDaemon = true }
            }
    }
}
