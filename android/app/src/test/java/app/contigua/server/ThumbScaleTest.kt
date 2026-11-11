package app.contigua.server

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * The long-side clamp for `fs.thumb` (FILES-24): the platform's decode can be
 * longer than the requested box (API 36: 800x600 for a 1200x900 photo at 512),
 * so the size handed to `Bitmap.createScaledBitmap` is computed here.
 */
class ThumbScaleTest {

    @Test
    fun aWidePhotoIsCappedOnItsLongSide() {
        assertEquals(512 to 384, ThumbScale.fit(1200, 900, 512))
    }

    @Test
    fun aTallPhotoIsCappedOnItsLongSide() {
        assertEquals(384 to 512, ThumbScale.fit(900, 1200, 512))
    }

    @Test
    fun anImageWithinTheCapIsNotScaled() {
        assertNull(ThumbScale.fit(300, 200, 512))
        assertNull(ThumbScale.fit(512, 512, 512))
    }

    @Test
    fun theRequestedCapBelow512IsUsed() {
        assertEquals(300 to 200, ThumbScale.fit(600, 400, 300))
    }

    @Test
    fun aTinySideStaysAtLeastOnePixel() {
        val (width, height) = ThumbScale.fit(4096, 1, 512)!!
        assertEquals(512, width)
        assertEquals(1, height)
    }

    @Test
    fun aBadInputIsNotScaled() {
        assertNull(ThumbScale.fit(0, 100, 512))
        assertNull(ThumbScale.fit(100, 100, 0))
    }
}
