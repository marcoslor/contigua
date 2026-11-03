package dev.pocketdeck.drop

import android.app.Activity
import android.content.ClipData
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.util.Log
import androidx.core.content.FileProvider
import dev.pocketdeck.app.ShizukuClient
import dev.pocketdeck.server.FILE_PROVIDER_AUTHORITY

/**
 * The grant half of a drop's SEND step (docs/design/dragdrop.md). Shell (UID
 * 2000) cannot grant one of our provider URIs — it does not own the provider, so
 * the system drops `FLAG_GRANT_READ_URI_PERMISSION` and the receiver crashes on
 * the URI it cannot open — so the shell process starts this exported, UI-less
 * activity instead and the SEND intent is built here, in the process that owns
 * the provider.
 *
 * It accepts one to five bare names ([ShareRequest.parseBatch]) of files the
 * shell process staged, copies each through the shell's `openStaged` fd into the
 * app-owned share cache (the app cannot open a shell-written path itself), and
 * shares them once: `ACTION_SEND` for one, `ACTION_SEND_MULTIPLE` for
 * two to five, straight to the window's package when it resolves the intent and
 * today's chooser otherwise (SHARE-17). No UI of its own: it finishes as soon
 * as the share is up, and every refusal is one line in logcat.
 */
class ShareTrampoline : Activity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        Log.i(TAG, "trampoline: started")
        val targets = requests()
        if (targets == null) {
            Log.i(TAG, "share refused: bad name/mime")
            return finish()
        }
        val service = ShizukuClient.current()
        if (service == null) {
            Log.i(TAG, "share refused: no shell service for ${targets.size} file(s)")  // log-ok: a count
            return finish()
        }
        // The shell opens each staged file and hands over the fd: the app can
        // stat a shell-written path but not open it (boot 5, H2).
        val shared = ShareCopies.copy(
            { name -> service.openStaged(name) },
            targets,
            ShareRequest.cacheDir(this),
            ::log,
        )
        if (shared == null) {
            Log.i(TAG, "share refused: cannot copy ${targets.size} file(s)")  // log-ok: a count
            return finish()
        }

        val uris = shared.mapNotNull { file ->
            runCatching { FileProvider.getUriForFile(this, FILE_PROVIDER_AUTHORITY, file) }
                .onFailure { Log.i(TAG, "share: no uri for ${shared.size} file(s): ${it.javaClass.simpleName}") }  // log-ok: a count and an exception class
                .getOrNull()
        }
        if (uris.size != targets.size) return finish()
        offer(uris, targets, ShareRequest.parseTarget(intent.getStringExtra(EXTRA_TARGET)))
        finish()
    }

    /** The checked batch; an older single-name extra is still understood. */
    private fun log(message: String) = Log.i(TAG, message)

    private fun requests(): List<ShareRequest.Target>? {
        val names = intent.getStringArrayExtra(EXTRA_NAMES)
        if (names != null) {
            return ShareRequest.parseBatch(names.toList(), intent.getStringArrayExtra(EXTRA_MIMES)?.toList())
        }
        val single = ShareRequest.parse(intent.getStringExtra(EXTRA_NAME),
                                        intent.getStringExtra(EXTRA_MIME))
        return single?.let { listOf(it) }
    }

    /**
     * The SEND intent, granted to whichever app is picked, or aimed at the
     * window's package when it resolves one (no chooser then).
     */
    private fun offer(uris: List<Uri>, requests: List<ShareRequest.Target>, target: String?) {
        val multiple = uris.size > 1
        val type = requests.map { it.mime }.distinct().singleOrNull() ?: "*/*"
        val label = if (multiple) "Send ${uris.size} files" else requests.single().name
        val send = Intent(if (multiple) Intent.ACTION_SEND_MULTIPLE else Intent.ACTION_SEND)
            .setType(type)
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        if (multiple) {
            send.putParcelableArrayListExtra(Intent.EXTRA_STREAM, ArrayList(uris))
        } else {
            send.putExtra(Intent.EXTRA_STREAM, uris.single())
        }
        // The clip carries the grant too: a receiver that reads ClipData first
        // (most of them do) gets the same read access as one that reads the extra.
        val clip = ClipData.newRawUri(label, uris.first())
        uris.drop(1).forEach { clip.addItem(ClipData.Item(it)) }
        send.clipData = clip

        if (target != null) {
            val aimed = Intent(send).setPackage(target)
            val resolves = aimed.resolveActivity(packageManager) != null
            Log.i(TAG, "share: target $target resolves=$resolves")  // log-ok: checked package
            if (resolves) {
                val started = runCatching { startActivity(aimed) }
                    .onFailure { Log.i(TAG, "share: ${target} did not start: ${it.javaClass.simpleName}") }  // log-ok: checked package, exception class
                    .isSuccess
                if (started) {
                    Log.i(TAG, "share offered for ${uris.size} file(s) to $target ($type)")  // log-ok: checked package and MIME
                    return
                }
            }
        }
        send.setPackage(null)
        Log.i(TAG, "share: chooser for ${uris.size} file(s)")  // log-ok: a count
        val started = runCatching { startActivity(Intent.createChooser(send, label)) }
            .onFailure { Log.i(TAG, "share: no chooser for ${uris.size} file(s): ${it.javaClass.simpleName}") }  // log-ok: a count and an exception class
            .isSuccess
        Log.i(
            TAG,
            if (started) "share offered for ${uris.size} file(s) ($type)"
            else "share failed for ${uris.size} file(s)",
        )
    }

    private companion object {
        const val TAG = "PocketDeckDrop"
        const val EXTRA_NAME = "name"
        const val EXTRA_MIME = "mime"
        const val EXTRA_NAMES = "names"
        const val EXTRA_MIMES = "mimes"
        const val EXTRA_TARGET = "target"
    }
}
