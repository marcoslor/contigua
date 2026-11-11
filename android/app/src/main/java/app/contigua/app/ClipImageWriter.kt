package app.contigua.app

import android.content.ClipboardManager
import android.content.Context
import android.util.Log
import androidx.core.content.FileProvider
import app.contigua.server.ClipImagePolicy
import app.contigua.server.FILE_PROVIDER_AUTHORITY
import app.contigua.server.imageClip
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.InputStream

/**
 * The app-owned half of a clipboard image (SHARE-2/16): the shell hands over a
 * validated PNG/JPEG over a pipe, and this writes it into `cacheDir/clip`,
 * builds the FileProvider URI at the app's own uid and sets A2's URI-only item.
 * Only the newest file is kept: the clip's URI always points at it.
 */
object ClipImageWriter {

    fun write(context: Context, mime: String, input: InputStream): Boolean {
        if (!ClipImagePolicy.valid(mime)) return false
        val bytes = readAtMost(input, ClipImagePolicy.MAX_BYTES) ?: return false
        val dir = File(context.cacheDir, "clip").apply { mkdirs() }
        val ext = if (mime.equals("image/jpeg", true)) "jpg" else "png"
        val file = runCatching { File.createTempFile("clip-", ".$ext", dir) }.getOrNull() ?: return false
        return try {
            file.writeBytes(bytes)
            val uri = FileProvider.getUriForFile(context, FILE_PROVIDER_AUTHORITY, file)
            context.getSystemService(ClipboardManager::class.java).setPrimaryClip(imageClip(uri, mime))
            Log.i("ClipImageWriter", "set (${bytes.size} bytes)")  // log-ok: a byte count
            dir.listFiles().orEmpty()
                .filter { it.isFile && it != file }
                .forEach { runCatching { it.delete() } }
            true
        } catch (e: Throwable) {
            Log.i("ClipImageWriter", "write failed: ${app.contigua.server.failureClasses(e)}")  // log-ok: class names only
            runCatching { file.delete() }
            false
        }
    }

    /** The bytes, or null when the stream is over [cap]; never keeps an over-cap image. */
    private fun readAtMost(input: InputStream, cap: Int): ByteArray? {
        val out = ByteArrayOutputStream()
        val buffer = ByteArray(64 * 1024)
        var total = 0
        while (true) {
            val n = input.read(buffer)
            if (n < 0) return out.toByteArray()
            total += n
            if (total > cap) return null
            out.write(buffer, 0, n)
        }
    }
}
