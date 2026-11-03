package dev.pocketdeck.server

import android.content.Context
import android.net.Uri
import android.view.KeyEvent
import androidx.test.core.app.ApplicationProvider
import dev.pocketdeck.proto.Frames
import dev.pocketdeck.proto.KeyPayload
import org.junit.Assert.assertEquals
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

    private val uri: Uri get() = Uri.parse("content://dev.pocketdeck.fileprovider/downloads/Clip%201.png")

    @Test
    fun anImageClipCarriesEmptyTextSoAPlainFieldPastesNothing() {
        val item = imageClipItem(uri)
        assertEquals("", item.text?.toString())
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
        val receiver = ClipImageReceiver(sink = { true }, done = { id, ok -> answers += id to ok })
        receiver.begin(7, "image/png", bytes.size.toLong())
        receiver.data(7, bytes)
        receiver.end(7, bytes.size.toLong(), sha(bytes))
        assertEquals(listOf(7 to true), answers)
    }

    @Test
    fun aRefusedImageAnswersDoneFalse() {
        val bytes = byteArrayOf(1, 2, 3)
        val answers = mutableListOf<Pair<Int, Boolean>>()
        val receiver = ClipImageReceiver(sink = { false }, done = { id, ok -> answers += id to ok })
        receiver.begin(7, "image/png", bytes.size.toLong())
        receiver.data(7, bytes)
        receiver.end(7, bytes.size.toLong(), sha(bytes))
        assertEquals(listOf(7 to false), answers)
    }

    @Test
    fun aChecksumMismatchAnswersDoneFalse() {
        val bytes = byteArrayOf(4, 5, 6)
        val answers = mutableListOf<Pair<Int, Boolean>>()
        val receiver = ClipImageReceiver(sink = { true }, done = { id, ok -> answers += id to ok })
        receiver.begin(7, "image/png", bytes.size.toLong())
        receiver.data(7, bytes)
        receiver.end(7, bytes.size.toLong(), "0".repeat(64))
        assertEquals(listOf(7 to false), answers)
    }
}
