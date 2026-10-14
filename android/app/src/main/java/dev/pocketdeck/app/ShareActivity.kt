package dev.pocketdeck.app

import android.app.Activity
import android.content.ContentResolver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.provider.OpenableColumns
import android.util.Log
import android.widget.Toast
import dev.pocketdeck.IDeckService
import dev.pocketdeck.server.ShareStatus
import java.io.InputStream
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference

/**
 * Share → "Send to Mac" (docs/design/sharein.md). No UI: it reads the intent,
 * opens the shared images while it still holds their URI grant, finishes, and
 * sends from a background thread through the shell service's session.
 */
class ShareActivity : Activity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val intent = intent
        val item = ShareIntent.parse(
            intent.action,
            intent.type,
            intent.getCharSequenceExtra(Intent.EXTRA_TEXT),
            streams(intent),
        )
        val images = (item as? ShareItem.Images<Uri>)?.let { open(it) }.orEmpty()
        val app = applicationContext
        finish()
        val service = AtomicReference<IDeckService?>()
        val bound = CountDownLatch(1)
        ShizukuClient.ensureBound(app) {
            service.set(it)
            bound.countDown()
        }
        Thread({
            bound.await(BIND_TIMEOUT_S, TimeUnit.SECONDS)
            val status = runCatching { ShareDispatch.send(item, images, service.get()?.let(::ServiceTarget)) }
                .onFailure { Log.i(TAG, "share failed: ${it.message}") }
                .getOrDefault(ShareStatus.NO_SESSION)
            Log.i(TAG, "share ${item::class.simpleName}: status $status")
            toast(app, ShareIntent.message(status, item))
        }, "pocketdeck-share").start()
    }

    @Suppress("DEPRECATION")
    private fun streams(intent: Intent): List<Uri> = when (intent.action) {
        Intent.ACTION_SEND -> listOfNotNull(intent.getParcelableExtra(Intent.EXTRA_STREAM) as? Uri)
        Intent.ACTION_SEND_MULTIPLE -> intent.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM).orEmpty()
        else -> emptyList()
    }

    private fun open(item: ShareItem.Images<Uri>): List<OpenedImage> = item.streams.mapIndexedNotNull { i, uri ->
        // Any app can start this activity: a file: URI or one of our own providers would
        // make us read (and send) our private files on its behalf.
        if (!isForeignContent(uri)) {
            Log.i(TAG, "refusing stream $uri")
            return@mapIndexedNotNull null
        }
        runCatching {
            var name: String? = null
            var size: Long? = null
            contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE), null, null, null)
                ?.use { c ->
                    if (c.moveToFirst()) {
                        name = c.getColumnIndex(OpenableColumns.DISPLAY_NAME).takeIf { it >= 0 }?.let(c::getString)
                        size = c.getColumnIndex(OpenableColumns.SIZE).takeIf { it >= 0 && !c.isNull(it) }?.let(c::getLong)
                    }
                }
            val mime = contentResolver.getType(uri)?.takeIf { it.startsWith("image/") } ?: item.mime
            val input = contentResolver.openInputStream(uri) ?: return@runCatching null
            OpenedImage(name ?: uri.lastPathSegment ?: "image-${i + 1}", mime, size, input)
        }.onFailure { Log.i(TAG, "cannot open $uri: ${it.message}") }.getOrNull()
    }

    private fun isForeignContent(uri: Uri): Boolean {
        if (uri.scheme != ContentResolver.SCHEME_CONTENT) return false
        val authority = uri.authority ?: return false
        return authority !in ownAuthorities
    }

    @Suppress("DEPRECATION")
    private val ownAuthorities: Set<String> by lazy {
        val providers = runCatching {
            packageManager.getPackageInfo(packageName, PackageManager.GET_PROVIDERS).providers
        }.getOrNull().orEmpty()
        providers.flatMap { it.authority?.split(';').orEmpty() }.toSet()
    }

    /** Images go through a pipe: the shell process reads it, needing no URI grant. */
    private class ServiceTarget(private val service: IDeckService) : ShareTarget {
        override fun text(text: String): Int = service.shareText(text)

        override fun file(name: String, mime: String, input: InputStream): Int {
            val (read, write) = ParcelFileDescriptor.createPipe()
            val pump = Thread({
                runCatching {
                    ParcelFileDescriptor.AutoCloseOutputStream(write).use { out -> input.copyTo(out) }
                }
            }, "pocketdeck-share-pump")
            pump.start()
            return try {
                service.shareFile(name, mime, read)
            } finally {
                runCatching { read.close() }
                pump.join(PUMP_JOIN_MS)
            }
        }
    }

    private companion object {
        const val TAG = "PocketDeckApp"
        const val BIND_TIMEOUT_S = 5L
        const val PUMP_JOIN_MS = 2_000L

        fun toast(context: Context, text: String) {
            Handler(Looper.getMainLooper()).post { Toast.makeText(context, text, Toast.LENGTH_SHORT).show() }
        }
    }
}
