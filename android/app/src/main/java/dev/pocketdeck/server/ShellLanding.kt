package dev.pocketdeck.server

import android.content.Context
import dev.pocketdeck.drop.ShareRequest
import java.io.File

/**
 * What a finished drop does on the phone (docs/design/dragdrop.md): a media scan
 * so the file shows up in Files/Photos, and — where sensible — the SEND chooser
 * with the app's FileProvider URI. Everything is best effort: the file is on the
 * card either way.
 */
class ShellLanding(
    /** The app's context (Shizuku hands it in): the external folder and the scanner. */
    private val app: Context?,
    private val log: (String) -> Unit = {},
) : DropReceiver.Landing {

    override fun land(file: File, mime: String) {
        scan(file)
        offerSend(file, mime)
    }

    /** Makes the file visible without waiting for the card to be remounted. */
    private fun scan(file: File) {
        // Not MediaScannerConnection with the app's Context: from a uid-2000
        // process that provider call has the wrong package and the system kills
        // the process (see [MediaScan]).
        MediaScan.request(app, listOf(file.absolutePath), log)
    }

    /**
     * Hands the finished file to the app process, which shows the SEND chooser:
     * the URI grant has to come from the UID that owns the provider — this
     * process is shell (UID 2000), and `am start -a android.intent.action.SEND`
     * from it drops the grant, so the receiver cannot open the URI (and crashes
     * on it). Instead the file is staged in the app's external `files/shared/`
     * folder and the exported [dev.pocketdeck.drop.ShareTrampoline] is started
     * with its bare name; the trampoline copies it into the app's share cache
     * and builds the SEND intent there.
     */
    private fun offerSend(file: File, mime: String) {
        val app = app ?: run { log("drop: no context, no SEND for ${file.name}"); return }
        val name = stage(app, file, mime) ?: return
        val started = runCatching {
            val proc = ProcessBuilder(
                "am", "start", "-n", TRAMPOLINE,
                "--es", "name", name,
                "--es", "mime", mime,
            ).redirectErrorStream(true).start()
            proc.outputStream.close()
            val out = proc.inputStream.bufferedReader().readText()
            out to proc.waitFor()
        }.onFailure { log("drop: am start failed: ${it.message}") }
        val (out, code) = started.getOrNull() ?: return
        if (code != 0 || out.contains("Error", ignoreCase = true)) {
            log("drop: SEND not offered (${out.trim().take(200)})")
        } else {
            log("drop: SEND offered for $name")
        }
    }

    /** Copies [file] into the staging folder; returns the name the trampoline is given. */
    private fun stage(app: Context, file: File, mime: String): String? {
        val dir = ShareRequest.stageDir(app) ?: run {
            log("drop: no external files dir, no SEND for ${file.name}")
            return null
        }
        return runCatching {
            dir.mkdirs()
            sweep(dir)
            val name = stageName(dir, file.name, mime)
            file.copyTo(File(dir, name), overwrite = true)
            name
        }.onFailure { log("drop: staging ${file.name} failed: ${it.message}") }.getOrNull()
    }

    /**
     * The trampoline copies a staged file once and deletes it; anything older is
     * a leftover from a failed hand-off and only takes space.
     */
    private fun sweep(dir: File) {
        val cutoff = System.currentTimeMillis() - STAGED_TTL_MS
        dir.listFiles().orEmpty()
            .filter { it.isFile && it.lastModified() < cutoff }
            .forEach { runCatching { it.delete() } }
    }

    /**
     * [name], or the drop folder's collision form when a leftover holds it — with
     * the plain name as the fallback, so the trampoline's name check always sees
     * a name its own sanitiser leaves alone.
     */
    private fun stageName(dir: File, name: String, mime: String): String {
        if (!File(dir, name).exists()) return name
        val numbered = DropPolicy.target(dir.path, DropPolicy.sanitize(name, mime)).substringAfterLast('/')
        return if (ShareRequest.parse(numbered, mime) != null) numbered else name
    }

    private companion object {
        /** The app's exported trampoline, started as the app's own UID. */
        const val TRAMPOLINE = "dev.pocketdeck/.drop.ShareTrampoline"

        /** Staged leftovers: long enough for a hand-off, short enough not to accumulate. */
        const val STAGED_TTL_MS = 5 * 60_000L
    }
}
