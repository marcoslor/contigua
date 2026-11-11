package app.contigua.server

import android.view.InputDevice
import android.view.MotionEvent
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.annotation.Config

/**
 * The injected wheel event is a real MotionEvent here (Robolectric), so the
 * assertions are about what apps will actually read from it.
 */
@RunWith(AndroidJUnit4::class)
@Config(sdk = [34])
class AndroidInjectorScrollTest {

    private val captured = mutableListOf<MotionEvent>()
    private val displays = mutableListOf<Int>()
    private val injector = AndroidInjector(log = {}, sink = { e, displayId ->
        displays += displayId
        captured += MotionEvent.obtain(e as MotionEvent)
    })

    private fun scroll(displayId: Int = 7, nx: Float = 0.25f, ny: Float = 0.75f, h: Float = 0f, v: Float = 0f) {
        injector.scroll(displayId, nx, ny, h, v, IntSize(1000, 2000))
    }

    @Test
    fun wheelEventCarriesBothAxesAsAMouse() {
        scroll(h = -1.5f, v = 3f)

        val e = captured.single()
        assertEquals(MotionEvent.ACTION_SCROLL, e.actionMasked)
        assertEquals(InputDevice.SOURCE_MOUSE, e.source)
        assertTrue(e.isFromSource(InputDevice.SOURCE_CLASS_POINTER))
        assertEquals(MotionEvent.TOOL_TYPE_MOUSE, e.getToolType(0))
        assertEquals(-1.5f, e.getAxisValue(MotionEvent.AXIS_HSCROLL), 0f)
        assertEquals(3f, e.getAxisValue(MotionEvent.AXIS_VSCROLL), 0f)
    }

    @Test
    fun wheelEventIsPositionedAndAimedAtTheStreamsDisplay() {
        scroll(displayId = 7, nx = 0.25f, ny = 0.75f, v = 1f)

        val e = captured.single()
        assertEquals(listOf(7), displays)
        assertEquals(250f, e.x, 0.01f)
        assertEquals(1500f, e.y, 0.01f)
    }

    @Test
    fun positionIsClampedToTheDisplay() {
        scroll(nx = -2f, ny = 3f, v = 1f)

        val e = captured.single()
        assertEquals(0f, e.x, 0f)
        assertEquals(2000f, e.y, 0f)
    }
}
