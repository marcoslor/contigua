package app.contigua.server

import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/**
 * The person's own `text` path (WIN-80), as it stands until plan T14 moves it
 * off the clipboard: kept here as the record of #173's bug.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class AndroidInjectorTest {

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
