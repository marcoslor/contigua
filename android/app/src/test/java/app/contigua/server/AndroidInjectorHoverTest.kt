package app.contigua.server

import android.view.InputDevice
import android.view.MotionEvent
import androidx.test.ext.junit.runners.AndroidJUnit4
import app.contigua.proto.Frames
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.annotation.Config

/**
 * Hover events are real MotionEvents here (Robolectric), so the assertions are
 * about what apps read: a mouse pointer that moves without touching anything.
 */
@RunWith(AndroidJUnit4::class)
@Config(sdk = [34])
class AndroidInjectorHoverTest {

    private val captured = mutableListOf<MotionEvent>()
    private val displays = mutableListOf<Int>()
    private val injector = AndroidInjector(log = {}, sink = { e, displayId ->
        displays += displayId
        captured += MotionEvent.obtain(e as MotionEvent)
    })

    private fun hover(action: Int, displayId: Int = 7, nx: Float = 0.25f, ny: Float = 0.75f) {
        injector.hover(displayId, action, nx, ny, IntSize(1000, 2000))
    }

    @Test
    fun enterIsAMouseHoverOnTheStreamsDisplay() {
        hover(Frames.HOVER_ENTER)

        val e = captured.single()
        assertEquals(MotionEvent.ACTION_HOVER_ENTER, e.actionMasked)
        assertEquals(InputDevice.SOURCE_MOUSE, e.source)
        assertTrue(e.isFromSource(InputDevice.SOURCE_CLASS_POINTER))
        assertEquals(MotionEvent.TOOL_TYPE_MOUSE, e.getToolType(0))
        assertEquals(listOf(7), displays)
        assertEquals(250f, e.x, 0.01f)
        assertEquals(1500f, e.y, 0.01f)
    }

    @Test
    fun moveAndExitUseTheirHoverActions() {
        hover(Frames.HOVER_MOVE)
        hover(Frames.HOVER_EXIT, nx = 0.5f, ny = 0.5f)

        assertEquals(MotionEvent.ACTION_HOVER_MOVE, captured[0].actionMasked)
        assertEquals(MotionEvent.ACTION_HOVER_EXIT, captured[1].actionMasked)
        assertEquals(500f, captured[1].x, 0.01f)
        assertEquals(1000f, captured[1].y, 0.01f)
        assertTrue(captured.all { it.getToolType(0) == MotionEvent.TOOL_TYPE_MOUSE })
    }

    @Test
    fun hoverTouchesNothing() {
        hover(Frames.HOVER_MOVE)

        val e = captured.single()
        assertEquals(1, e.pointerCount)
        assertEquals(0f, e.getPressure(0), 0f)
        assertEquals(0, e.buttonState)
    }

    @Test
    fun positionIsClampedToTheDisplay() {
        hover(Frames.HOVER_MOVE, nx = -2f, ny = 3f)

        val e = captured.single()
        assertEquals(0f, e.x, 0f)
        assertEquals(2000f, e.y, 0f)
    }
}
