package dev.pocketdeck.server

import android.content.Context
import android.net.Uri
import androidx.core.content.FileProvider
import java.io.File

/**
 * What a finished drop does on the phone (docs/design/dragdrop.md): a media scan
 * so the file shows up in Files/Photos, and — where sensible — the SEND chooser
 * with the app's FileProvider URI. Everything is best effort: the file is on the
 * card either way.
 */
class ShellLanding(
    /** The app's context (Shizuku hands it in): provider resources and the scanner. */
    private val app: Context?,
    private val log: (String) -> Unit = {},
) : DropReceiver.Landing {

    override fun land(file: File, mime: String) {
        scan(file, mime)
        offerSend(file, mime)
    }

    /** Makes the file visible without waiting for the card to be remounted. */
    private fun scan(file: File, mime: String) {
        val app = app ?: return
        runCatching {
            android.media.MediaScannerConnection.scanFile(
                app, arrayOf(file.absolutePath), arrayOf(mime), null,
            )
        }.onFailure { log("drop: media scan failed: ${it.message}") }
    }

    /**
     * `am start -a android.intent.action.SEND` on the provider URI. The system
     * honours `FLAG_GRANT_READ_URI_PERMISSION` for any caller once the provider
     * has `grantUriPermissions="true"` (ours does), so a plain `am` invocation
     * from shell UID is the whole grant: the app process itself could never
     * launch this from the background (Android 10+), but shell can.
     */
    private fun offerSend(file: File, mime: String) {
        val app = app ?: run { log("drop: no context, no SEND for ${file.name}"); return }
        val uri: Uri = runCatching { FileProvider.getUriForFile(app, FILE_PROVIDER_AUTHORITY, file) }
            .onFailure { log("drop: fileprovider uri failed: ${it.message}") }
            .getOrNull() ?: return
        // argv, never `sh -c`: the URI and the mime name contain no shell metacharacters
        // beyond what the array form treats as plain arguments.
        val started = runCatching {
            val proc = ProcessBuilder(
                "am", "start", "-a", "android.intent.action.SEND",
                "-t", mime,
                "--grant-read-uri-permission",
                "--eu", "android.intent.extra.STREAM", uri.toString(),
            ).redirectErrorStream(true).start()
            proc.outputStream.close()
            val out = proc.inputStream.bufferedReader().readText()
            out to proc.waitFor()
        }.onFailure { log("drop: am start failed: ${it.message}") }
        val (out, code) = started.getOrNull() ?: return
        if (code != 0 || out.contains("Error", ignoreCase = true)) {
            log("drop: SEND not offered (${out.trim().take(200)})")
        } else {
            log("drop: SEND offered for ${file.name}")
        }
    }
}
