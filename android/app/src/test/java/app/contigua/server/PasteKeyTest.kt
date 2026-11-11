package app.contigua.server

import android.content.Context
import android.net.Uri
import android.view.KeyEvent
import androidx.test.core.app.ApplicationProvider
import app.contigua.proto.Frames
import app.contigua.proto.KeyPayload
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import java.security.MessageDigest

/**
 * SHARE-16's phone half: the image clip shape A2 asks for, the `clip.image.done`
 * answer, and the paste key the Mac sends (KEYCODE_PASTE 279, no modifiers).
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class PasteKeyTest {

    private fun sha(bytes: ByteArray): String =
        MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }

    private val uri: Uri get() = Uri.parse("content://app.contigua.fileprovider/downloads/Clip%201.png")

    /**
     * Measured on the emulator (boot 3): a URI-only item pastes nothing in a
     * plain field (a content:// URI that cannot serve text coerces to null)
     * and does reach an image field's listener. So the item carries no text at
     * all, rather than an empty one that would have to be maintained.
     */
    @Test
    fun aUriOnlyImageItemNeverBecomesText() {
        val item = imageClipItem(uri)
        assertNull(item.text)
        assertEquals(uri, item.uri)
        val context = ApplicationProvider.getApplicationContext<Context>()
        assertEquals("a field with no image receiver must paste nothing, never a content:// string",
            "", item.coerceToText(context).toString())
    }

    @Test
    fun thePasteKeyIsAndroidKeycode279WithNoModifiers() {
        assertEquals(279, KeyEvent.KEYCODE_PASTE)
        val payload = Frames.encodeKey(KeyPayload(Frames.ACTION_DOWN, KeyEvent.KEYCODE_PASTE, 0))
        val decoded = Frames.decodeKey(payload)
        assertEquals(KeyEvent.KEYCODE_PASTE, decoded.keycode)
        assertEquals(0, decoded.metaState)
    }

    @Test
    fun aWrittenImageAnswersDone() {
        val bytes = byteArrayOf(9, 8, 7)
        val answers = mutableListOf<Pair<Int, Boolean>>()
        val receiver = ClipImageReceiver(sink = { _, _, done -> done(true) }, done = { id, ok -> answers += id to ok })
        receiver.begin(7, "image/png", bytes.size.toLong())
        receiver.data(7, bytes)
        receiver.end(7, bytes.size.toLong(), sha(bytes))
        assertEquals(listOf(7 to true), answers)
    }

    @Test
    fun aRefusedImageAnswersDoneFalse() {
        val bytes = byteArrayOf(1, 2, 3)
        val answers = mutableListOf<Pair<Int, Boolean>>()
        val receiver = ClipImageReceiver(sink = { _, _, done -> done(false) }, done = { id, ok -> answers += id to ok })
        receiver.begin(7, "image/png", bytes.size.toLong())
        receiver.data(7, bytes)
        receiver.end(7, bytes.size.toLong(), sha(bytes))
        assertEquals(listOf(7 to false), answers)
    }

    @Test
    fun aChecksumMismatchAnswersDoneFalse() {
        val bytes = byteArrayOf(4, 5, 6)
        val answers = mutableListOf<Pair<Int, Boolean>>()
        val receiver = ClipImageReceiver(sink = { _, _, done -> done(true) }, done = { id, ok -> answers += id to ok })
        receiver.begin(7, "image/png", bytes.size.toLong())
        receiver.data(7, bytes)
        receiver.end(7, bytes.size.toLong(), "0".repeat(64))
        assertEquals(listOf(7 to false), answers)
    }

    /**
     * The shell no longer sets an image clip: the bytes go to the app, and the
     * Mac's `clip.image.done` is sent only from the app's answer, even when it
     * arrives after the read returns.
     */
    @Test
    fun anImageGoesToTheAppAndItsLateAnswerIsTheDone() {
        var offered: Triple<Int, String, ByteArray>? = null
        var appAnswer: ((Boolean) -> Unit)? = null
        val answers = mutableListOf<Pair<Int, Boolean>>()
        val host = ClipImageHost { id, mime, bytes, done ->
            offered = Triple(id, mime, bytes)
            appAnswer = done
        }
        val receiver = ClipImageReceiver(sink = ClipImageLand(host),
                                          done = { id, ok -> answers += id to ok })
        val bytes = byteArrayOf(8, 9)

        receiver.begin(7, "image/png", bytes.size.toLong())
        receiver.data(7, bytes)
        receiver.end(7, bytes.size.toLong(), sha(bytes))

        assertEquals(7, offered!!.first)
        assertEquals("image/png", offered!!.second)
        assertTrue(offered!!.third.contentEquals(bytes))
        assertEquals("no answer until the app answers", emptyList<Pair<Int, Boolean>>(), answers)
        appAnswer!!(true)
        assertEquals(listOf(7 to true), answers)
        appAnswer!!(false)
        assertEquals("the answer is delivered once", listOf(7 to true), answers)
    }

    @Test
    fun withoutAnAppWriterTheAnswerIsFalse() {
        val answers = mutableListOf<Pair<Int, Boolean>>()
        val receiver = ClipImageReceiver(sink = ClipImageLand(null),
                                          done = { id, ok -> answers += id to ok })
        val bytes = byteArrayOf(1)

        receiver.begin(7, "image/png", bytes.size.toLong())
        receiver.data(7, bytes)
        receiver.end(7, bytes.size.toLong(), sha(bytes))

        assertEquals(listOf(7 to false), answers)
    }
}
