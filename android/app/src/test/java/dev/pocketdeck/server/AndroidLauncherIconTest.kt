package dev.pocketdeck.server

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.drawable.AdaptiveIconDrawable
import android.graphics.drawable.BitmapDrawable
import android.graphics.drawable.ColorDrawable
import android.graphics.drawable.Drawable
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Shadows
import org.robolectric.annotation.Config

/**
 * The launcher renders an adaptive icon's layers for the Mac's glass tiles
 * (Robolectric, so the real AdaptiveIconDrawable drawing runs).
 */
@RunWith(AndroidJUnit4::class)
@Config(sdk = [34])
class AndroidLauncherIconTest {

    private val ctx: Context = ApplicationProvider.getApplicationContext()
    private val launcher = AndroidLauncher(ctx, log = {})

    private fun pngSize(base64: String): Int {
        val bytes = android.util.Base64.decode(base64, android.util.Base64.DEFAULT)
        val bitmap = BitmapFactory.decodeByteArray(bytes, 0, bytes.size)
        val side = bitmap.width
        bitmap.recycle()
        return side
    }

    private fun pngPixel(base64: String, x: Int, y: Int): Int {
        val bytes = android.util.Base64.decode(base64, android.util.Base64.DEFAULT)
        val bitmap = BitmapFactory.decodeByteArray(bytes, 0, bytes.size)
        val pixel = bitmap.getPixel(x, y)
        bitmap.recycle()
        return pixel
    }

    @Test
    fun adaptiveIconGivesLayerPngsAt216WithTheLayerColours() {
        adaptively("com.test.adaptive", ColorDrawable(Color.RED), ColorDrawable(Color.BLUE))

        val layers = launcher.iconLayers("com.test.adaptive")

        assertNotNull(layers)
        assertEquals(216, pngSize(layers!!.fg))
        assertEquals(216, pngSize(layers.bg))
        assertEquals(Color.RED, pngPixel(layers.fg, 108, 108))
        assertEquals(Color.BLUE, pngPixel(layers.bg, 108, 108))
        assertNull(layers.mono)
    }

    @Test
    fun foregroundLayerKeepsTheTransparentCornersOfItsShape() {
        adaptively("com.test.disc", makeDisc(Color.RED), ColorDrawable(Color.BLUE))
        val layers = launcher.iconLayers("com.test.disc")!!

        assertEquals(Color.TRANSPARENT, pngPixel(layers.fg, 8, 8))
        assertEquals(Color.RED, pngPixel(layers.fg, 108, 108))
    }

    @Test
    fun pxRendersLayersAtTheAskedSizeAndKeepsTheOldOne() {
        adaptively("com.test.big", makeDisc(Color.RED), ColorDrawable(Color.BLUE))

        val big = launcher.iconLayers("com.test.big", 1296)!!
        assertEquals(1296, pngSize(big.fg))
        assertEquals(1296, pngSize(big.bg))
        assertEquals(Color.BLUE, pngPixel(big.bg, 648, 648))
        // The size the Mac draws for the Deck is a separate cache entry.
        assertEquals(216, pngSize(launcher.iconLayers("com.test.big", null)!!.fg))
        assertEquals(432, pngSize(launcher.iconLayers("com.test.big", 432)!!.fg))
    }

    @Test
    fun pxIsClamped() {
        adaptively("com.test.clamp", makeDisc(Color.RED), ColorDrawable(Color.BLUE))

        assertEquals(216, pngSize(launcher.iconLayers("com.test.clamp", 8)!!.fg))
        assertEquals(1296, pngSize(launcher.iconLayers("com.test.clamp", 9999)!!.fg))
    }

    @Test
    fun flatIconsFollowPxToo() {
        icon("com.test.flatpx", ColorDrawable(Color.GREEN))

        assertEquals(96, pngSize(launcher.iconPng("com.test.flatpx", null)!!))
        assertEquals(144, pngSize(launcher.iconPng("com.test.flatpx", 216)!!))
        assertEquals(864, pngSize(launcher.iconPng("com.test.flatpx", 1296)!!))
    }

    @Test
    fun bitmapDrawableSendsNoLayers() {
        val bitmap = Bitmap.createBitmap(48, 48, Bitmap.Config.ARGB_8888)
        Canvas(bitmap).drawColor(Color.GRAY)
        icon("com.test.flat", BitmapDrawable(ctx.resources, bitmap))
        // A BitmapDrawable must never be asked twice either: the cached answer
        // is the same null.
        assertNull(launcher.iconLayers("com.test.flat"))
        assertNull(launcher.iconLayers("com.test.flat"))
    }

    @Test
    fun unknownPackageSendsNoLayers() {
        assertNull(launcher.iconLayers("com.test.nope"))
        assertNull(launcher.iconLayers("com.test.nope"))
    }

    private fun icon(pkg: String, drawable: Drawable) {
        Shadows.shadowOf(ctx.packageManager).setApplicationIcon(pkg, drawable)
    }

    private fun adaptively(pkg: String, fg: Drawable, bg: Drawable) {
        // AOSP's public constructor is (background, foreground).
        icon(pkg, AdaptiveIconDrawable(bg, fg))
    }

    private fun makeDisc(color: Int): Drawable {
        // Robolectric's native Canvas has no drawCircle; the disc is written
        // pixel by pixel, which is enough (an opaque centre, clear corners).
        val bitmap = Bitmap.createBitmap(216, 216, Bitmap.Config.ARGB_8888)
        val pixels = IntArray(216 * 216) { i ->
            val x = i % 216
            val y = i / 216
            val dx = x - 108
            val dy = y - 108
            if (dx * dx + dy * dy <= 60 * 60) color else Color.TRANSPARENT
        }
        bitmap.setPixels(pixels, 0, 216, 0, 0, 216, 216)
        return BitmapDrawable(ctx.resources, bitmap)
    }
}
