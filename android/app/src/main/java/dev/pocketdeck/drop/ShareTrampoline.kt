package dev.pocketdeck.drop

import android.app.Activity
import android.content.ClipData
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.util.Log
import androidx.core.content.FileProvider
import dev.pocketdeck.server.DropPolicy
import dev.pocketdeck.server.FILE_PROVIDER_AUTHORITY
import java.io.File

/**
 * The grant half of a drop's SEND step (docs/design/dragdrop.md). Shell (UID
 * 2000) cannot grant one of our provider URIs — it does not own the provider, so
 * the system drops `FLAG_GRANT_READ_URI_PERMISSION` and the receiver crashes on
 * the URI it cannot open — so the shell process starts this exported, UI-less
 * activity instead and the SEND intent is built here, in the process that owns
 * the provider.
 *
 * It accepts one bare name ([ShareRequest.parse]) of a file the shell process
 * staged in `files/shared/`, copies it into the app-owned share cache and shows
 * the chooser for that copy. No UI of its own: it finishes as soon as the
 * chooser is up, and every refusal is one line in logcat.
 */
class ShareTrampoline : Activity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val rawName = intent.getStringExtra(EXTRA_NAME)
        val rawMime = intent.getStringExtra(EXTRA_MIME)
        val target = ShareRequest.parse(rawName, rawMime)
        if (target == null) {
            Log.i(TAG, "share refused: bad name/mime (${rawName?.take(80)}, ${rawMime?.take(40)})")
            return finish()
        }
        val source = ShareRequest.stageDir(this)?.let { File(it, target.name) }
        if (source == null || !source.isFile || source.length() > DropPolicy.MAX_FILE_BYTES) {
            Log.i(TAG, "share refused: no staged file for ${target.name}")
            return finish()
        }
        val shared = ShareCache.put(ShareRequest.cacheDir(this), source)
        if (shared == null) {
            Log.i(TAG, "share refused: cannot copy ${target.name}")
            return finish()
        }
        // The staging copy exists for this one hand-off; the cache copy is shared.
        runCatching { source.delete() }

        val uri = runCatching { FileProvider.getUriForFile(this, FILE_PROVIDER_AUTHORITY, shared) }
            .onFailure { Log.i(TAG, "share: no uri for ${shared.name}: ${it.message}") }
            .getOrNull() ?: return finish()
        offer(uri, shared, target.mime)
        finish()
    }

    /** The SEND intent, granted to whichever app the user picks. */
    private fun offer(uri: Uri, file: File, mime: String) {
        val name = file.name
        val send = Intent(Intent.ACTION_SEND)
            .setType(mime)
            .putExtra(Intent.EXTRA_STREAM, uri)
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        // The clip carries the grant too: a receiver that reads ClipData first
        // (most of them do) gets the same read access as one that reads the extra.
        send.clipData = ClipData.newRawUri(name, uri)
        val started = runCatching { startActivity(Intent.createChooser(send, name)) }
            .onFailure { Log.i(TAG, "share: no chooser for $name: ${it.message}") }
            .isSuccess
        Log.i(
            TAG,
            if (started) "share offered for $name ($mime, ${file.length()} bytes)" else "share failed for $name",
        )
    }

    private companion object {
        const val TAG = "PocketDeckDrop"
        const val EXTRA_NAME = "name"
        const val EXTRA_MIME = "mime"
    }
}
