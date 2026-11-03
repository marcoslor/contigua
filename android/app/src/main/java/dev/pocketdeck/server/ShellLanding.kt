package dev.pocketdeck.server

import android.content.Context
import dev.pocketdeck.drop.ShareRequest
import dev.pocketdeck.drop.ShareStaging
import java.io.File

/**
 * What a finished drop does on the phone (docs/design/dragdrop.md): a media scan
 * so the file shows up in Files/Photos, and — where sensible — the SEND chooser
 * with the app's FileProvider URI. Everything is best effort: the file is on the
 * card either way.
 *
 * A gesture's files land one at a time; [ShareBatch] collects them and calls
 * back once, after the last one, so the phone shares the batch once (SHARE-17).
 */
class ShellLanding(
    /** The app's context (Shizuku hands it in): the external folder and the scanner. */
    private val app: Context?,
    /** The names staged for the pending SEND; `openStaged` reads this set. */
    private val staging: ShareStaging,
    private val log: (String) -> Unit = {},
) : DropReceiver.Landing {

    private val batch = ShareBatch { files, target -> offerSend(files, target) }

    override fun land(file: File, mime: String, target: String?, index: Int, count: Int) {
        scan(file)
        batch.landed(file, mime, target, index, count)
    }

    /** Makes the file visible without waiting for the card to be remounted. */
    private fun scan(file: File) {
        // Not MediaScannerConnection with the app's Context: from a uid-2000
        // process that provider call has the wrong package and the system kills
        // the process (see [MediaScan]).
        MediaScan.request(app, listOf(file.absolutePath), log)
    }

    /**
     * Hands the finished batch to the app process, which shows one SEND for all
     * of it (SHARE-17): the URI grant has to come from the UID that owns the
     * provider — this process is shell (UID 2000), and `am start` from it drops
     * the grant. Instead each file is staged in the app's external `files/shared/`
     * folder and the exported [dev.pocketdeck.drop.ShareTrampoline] is started
     * with their bare names, a mime array and the window's package.
     */
    private fun offerSend(files: List<Pair<File, String>>, target: String?) {
        val app = app ?: run {
            log("drop: no context, no SEND for ${files.size} file(s)")
            return
        }
        val dir = ShareRequest.stageDir(app) ?: run {
            log("drop: no external files dir, no SEND for ${files.size} file(s)")
            return
        }
        dir.mkdirs()
        staging.sweep()
        sweep(dir)
        val names = mutableListOf<String>()
        val mimes = mutableListOf<String>()
        for ((file, mime) in files) {
            val name = stage(dir, file, mime) ?: return
            staging.expect(name, File(dir, name))
            names += name
            mimes += mime
        }
        val args = mutableListOf(
            "am", "start", "-n", TRAMPOLINE,
            "--esa", "names", names.joinToString(","),
            "--esa", "mimes", mimes.joinToString(","),
        )
        if (target != null) {
            args += listOf("--es", "target", target)
        }
        val started = runCatching {
            val proc = ProcessBuilder(args).redirectErrorStream(true).start()
            proc.outputStream.close()
            val out = proc.inputStream.bufferedReader().readText()
            out to proc.waitFor()
        }.onFailure { log("drop: am start failed: ${failureClasses(it)}") }
        val (out, code) = started.getOrNull() ?: return
        if (code != 0 || out.contains("Error", ignoreCase = true)) {
            log("drop: SEND not offered (${out.trim().take(200)})")
        } else {
            log("drop: SEND offered for ${names.size} file(s)")
        }
    }

    /** Copies [file] into the staging folder; returns the name the trampoline is given. */
    private fun stage(dir: File, file: File, mime: String): String? = runCatching {
        val name = stageName(dir, file.name, mime)
        file.copyTo(File(dir, name), overwrite = true)
        name
    }.onFailure { log("drop: staging failed: ${failureClasses(it)}") }.getOrNull()

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

        /** Staged leftovers: the same deadline the pending set enforces. */
        const val STAGED_TTL_MS = ShareStaging.TTL_MS
    }
}
