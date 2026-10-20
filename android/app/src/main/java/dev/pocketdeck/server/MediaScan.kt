package dev.pocketdeck.server

import android.content.ContentResolver
import android.content.Context

/**
 * MediaProvider's scan, asked from the shell process (docs/design/files.md §2,
 * S5 round 2).
 *
 * `MediaScannerConnection.scanFile(appContext, …)` looks harmless — it returns
 * at once — but on API 36 it acquires MediaProvider on a background
 * HandlerThread with the *app package* for the caller, while this process runs
 * as uid 2000. The system answers `SecurityException: Given calling package
 * … does not match caller's uid`, on that thread, outside every caller's
 * `runCatching`, and the process dies (emulator evidence, files.md S5 notes).
 *
 * So: one synchronous provider call per path — `scan_file`, the call the
 * framework's own `MediaStore.scanFile` makes — on our daemon thread, with a
 * context whose package is the one this uid really is (`com.android.shell`;
 * the app's own package inside a uid-2000 process is what the system refuses),
 * and every failure inside [runCatching]. Best effort by design: the file is on
 * the card either way, and a refused scan must never cost the process.
 */
internal object MediaScan {
    private val worker = java.util.concurrent.Executors.newSingleThreadExecutor { runnable ->
        Thread(runnable, "pocketdeck-media-scan").apply { isDaemon = true }
    }

    /** Asks for [paths] to be indexed; returns at once, never throws. */
    fun request(app: Context?, paths: List<String>, log: (String) -> Unit) {
        if (app == null || paths.isEmpty()) return
        val resolver = resolver(app) ?: run {
            log("fs: no shell context for the media scan")
            return
        }
        val array = paths.toTypedArray()
        worker.execute {
            runCatching {
                for (path in array) resolver.call(AUTHORITY, SCAN_FILE, path, null)
            }.onFailure { log("fs: media scan failed: ${it.javaClass.simpleName}") }
        }
    }

    /**
     * A resolver that carries the package this process's uid really has. The
     * app's own Context does not: its package and the caller's uid disagree, and
     * MediaProvider refuses that pair.
     */
    private fun resolver(app: Context): ContentResolver? = runCatching {
        app.createPackageContext(SHELL_PACKAGE, 0).contentResolver
    }.getOrNull()

    private const val AUTHORITY = "media"
    private const val SCAN_FILE = "scan_file"
    private const val SHELL_PACKAGE = "com.android.shell"
}
