package dev.pocketdeck.app

import android.app.Notification
import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.drawable.Icon
import android.util.Base64

/**
 * The Android end of [NotifyImageRules]: turn a notification's own picture into
 * a [BitmapSource]. Only the app process calls this (docs/design/notify.md).
 */
object NotifyPictures {

    /** One picture per notification: big picture, else its icon, else the large icon. */
    fun bitmapFor(context: Context, notification: Notification): Bitmap? {
        val extras = notification.extras ?: return largeIcon(context, notification)
        for (key in PICTURE_KEYS) {
            val value = extras.get(key) ?: continue
            bitmapOf(context, value)?.let { return it }
        }
        return largeIcon(context, notification)
    }

    fun sourceFor(context: Context, notification: Notification): BitmapSource? =
        bitmapFor(context, notification)?.let { AndroidBitmapSource(it) }

    fun base64(bytes: ByteArray): String = Base64.encodeToString(bytes, Base64.NO_WRAP)

    private fun largeIcon(context: Context, notification: Notification): Bitmap? =
        notification.getLargeIcon()?.let { bitmapOf(context, it) }

    private fun bitmapOf(context: Context, value: Any?): Bitmap? = when (value) {
        is Bitmap -> value.takeIf { it.width > 0 && it.height > 0 }
        is Icon -> iconBitmap(context, value)
        else -> null
    }

    /** Some icons only expose a drawable; rasterise it, bounded, and keep alpha. */
    private fun iconBitmap(context: Context, icon: Icon): Bitmap? {
        val drawable = runCatching { icon.loadDrawable(context) }.getOrNull() ?: return null
        val width = drawable.intrinsicWidth.takeIf { it > 0 } ?: NotifyImageRules.MAX_SIDE
        val height = drawable.intrinsicHeight.takeIf { it > 0 } ?: NotifyImageRules.MAX_SIDE
        val (w, h) = NotifyImageRules.targetSize(width, height, NotifyImageRules.MAX_SIDE)
        val bitmap = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
        drawable.setBounds(0, 0, w, h)
        drawable.draw(Canvas(bitmap))
        return bitmap
    }

    private val PICTURE_KEYS = arrayOf(
        Notification.EXTRA_PICTURE,
        Notification.EXTRA_PICTURE_ICON,
    )
}

class AndroidBitmapSource(private val bitmap: Bitmap) : BitmapSource {
    override val width: Int get() = bitmap.width
    override val height: Int get() = bitmap.height
    override val hasAlpha: Boolean get() = bitmap.hasAlpha()

    override fun scaledTo(width: Int, height: Int): BitmapSource =
        AndroidBitmapSource(Bitmap.createScaledBitmap(bitmap, width, height, true))

    override fun encode(mime: String, quality: Int): ByteArray? {
        val format = if (mime == "image/png") Bitmap.CompressFormat.PNG else Bitmap.CompressFormat.JPEG
        val out = java.io.ByteArrayOutputStream()
        return if (bitmap.compress(format, quality, out)) out.toByteArray() else null
    }
}
