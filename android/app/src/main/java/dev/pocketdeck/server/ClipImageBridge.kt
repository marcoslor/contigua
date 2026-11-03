package dev.pocketdeck.server

import android.os.ParcelFileDescriptor
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledExecutorService

/**
 * The shell's side of the clipboard image hand-off (SHARE-2/16): the app owns
 * the FileProvider and the clipboard write, so it must also own the bytes. The
 * shell passes the image over a pipe and waits at most 3 s for the app's
 * `IDeckService.clipImageDone`; no callback or no answer is a refusal.
 */
class ClipImageBridge(
    private val callback: () -> ClipImageCallback?,
    private val timeoutMs: Long = TIMEOUT_MS,
    private val scheduler: ScheduledExecutorService = defaultScheduler(),
    private val log: (String) -> Unit = {},
) {
    fun interface ClipImageCallback {
        fun onClipImage(id: String, mime: String, data: ParcelFileDescriptor)
    }

    fun offer(id: String, mime: String, bytes: ByteArray, done: (Boolean) -> Unit) = done(false)

    fun answer(id: String, ok: Boolean) = Unit

    fun close() = Unit

    companion object {
        const val TIMEOUT_MS = 3_000L

        private fun defaultScheduler(): ScheduledExecutorService =
            Executors.newSingleThreadScheduledExecutor { runnable ->
                Thread(runnable, "pocketdeck-clip-answer").apply { isDaemon = true }
            }
    }
}
