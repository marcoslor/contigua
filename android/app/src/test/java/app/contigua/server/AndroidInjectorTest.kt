package app.contigua.server

import android.view.KeyEvent
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/**
 * The injector's KEY path, which `ui.type`'s keys and the Mac's KEY frames
 * share, and the person's own `text` path (WIN-80), as it stands until plan
 * T14 moves it off the clipboard: kept here as the record of #173's bug.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class AndroidInjectorTest {

    private fun keysDelivered(): Pair<AndroidInjector, MutableList<KeyEvent>> {
        val events = mutableListOf<KeyEvent>()
        return AndroidInjector(log = {}, sink = { e, _ -> events += e as KeyEvent }) to events
    }

    /**
     * B5's emulator proof typed "X" by keys right after a set-text insert and
     * read back a lowercase x: the injector built `KeyEvent(down, time, action,
     * code, metaState)`, whose fifth argument is the repeat count, so the key
     * map's SHIFT never reached the app (a full keyboard reads only the event's
     * own meta).
     */
    @Test
    fun testUiTypeKeysKeepTheKeyMapsShift() { // [MCP-109]
        val (injector, events) = keysDelivered()
        val strokes = injector.keyStrokes("X")
        assertNotNull("X has keys in the virtual key map", strokes)
        for (s in strokes!!) injector.key(0, s.action, s.keycode, s.metaState, 5L, 5L)
        val x = events.first { it.keyCode == KeyEvent.KEYCODE_X && it.action == KeyEvent.ACTION_DOWN }
        assertTrue("the X down carries SHIFT", x.isShiftPressed)
        assertEquals("a fresh press, not a repeat", 0, x.repeatCount)
        assertEquals('X'.code, x.getUnicodeChar(x.metaState))
    }

    /**
     * B5's MCP-110 proof copies the field's text with ctrl+A, ctrl+C sent as
     * KEY frames before the run: with the meta dropped they typed "a" and "c"
     * and nothing was copied, so the clip pasted after the run never matched.
     */
    @Test
    fun testAKeyFramesCtrlReachesTheApp() { // [MCP-110]
        val (injector, events) = keysDelivered()
        val ctrl = KeyEvent.META_CTRL_ON or KeyEvent.META_CTRL_LEFT_ON
        injector.key(0, KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_C, ctrl, 7L, 7L)
        injector.key(0, KeyEvent.ACTION_UP, KeyEvent.KEYCODE_C, ctrl, 7L, 8L)
        assertEquals(listOf(ctrl, ctrl), events.map { it.metaState })
        assertTrue("ctrl+C is a shortcut, so the app copies", events[0].isCtrlPressed)
        assertEquals(listOf(0, 0), events.map { it.repeatCount })
        assertEquals(listOf(7L, 7L), events.map { it.downTime })
        assertEquals(listOf(7L, 8L), events.map { it.eventTime })
    }

    /** A clipboard holding an image clip (no text) until something writes text over it. */
    private class ImageClipboard : ClipboardPort {
        @Volatile var holdsTheImage = true
        override fun getText(): ClipText? = null
        override fun setText(text: String) {
            holdsTheImage = false
        }
        override fun listen(onChange: () -> Unit): ClipRegistration = ClipRegistration(onChange)
        override fun stop(registration: ClipRegistration?) = Unit
    }

    /**
     * #173: typing non-ASCII text through `text` pastes it via the clipboard
     * and never puts a non-text clip back, so the person's copied image is lost.
     * Expected to fail (the AssertionError is the bug) until the person's path
     * moves off the clipboard (plan T14, WIN-80; docs/specs/mcp.md's open
     * question): when that ships this test fails, and its `expected` goes.
     */
    @Test(expected = AssertionError::class)
    fun testANonTextClipSurvivesTyping() { // [MCP-110]
        val clipboard = ImageClipboard()
        val injector = AndroidInjector(log = {}, sink = { _, _ -> }, clipboard = clipboard)
        injector.text(0, "café")
        // The paste path restores 400 ms after the paste; wait past it.
        Thread.sleep(800) // real-time: the old paste path restores the clip 400 ms later on a real executor
        assertTrue("the person's image clip is still on the clipboard", clipboard.holdsTheImage)
    }
}
