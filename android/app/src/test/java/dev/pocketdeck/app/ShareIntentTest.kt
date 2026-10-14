package dev.pocketdeck.app

import dev.pocketdeck.server.ShareStatus
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.ByteArrayInputStream
import java.io.InputStream

class ShareIntentTest {

    private val send = ShareIntent.ACTION_SEND
    private val sendMultiple = ShareIntent.ACTION_SEND_MULTIPLE

    @Test
    fun textThatIsALinkIsALink() {
        assertEquals(ShareItem.Text("https://example.com/a?b=1", true),
            ShareIntent.parse(send, "text/plain", "  https://example.com/a?b=1 \n", emptyList<String>()))
    }

    @Test
    fun textHoldingOneLinkIsALink() {
        val item = ShareIntent.parse(send, "text/plain", "Look at this https://example.com/x", emptyList<String>())
        assertEquals(ShareItem.Text("Look at this https://example.com/x", true), item)
    }

    @Test
    fun plainTextAndTwoLinksAreText() {
        assertEquals(ShareItem.Text("hello world", false),
            ShareIntent.parse(send, "text/plain", "hello world", emptyList<String>()))
        assertEquals(false, (ShareIntent.parse(send, "text/plain", "http://a.com http://b.com", emptyList<String>()) as ShareItem.Text).isLink)
        assertEquals(false, (ShareIntent.parse(send, "text/plain", "file:///etc/hosts", emptyList<String>()) as ShareItem.Text).isLink)
    }

    @Test
    fun singleImageStream() {
        assertEquals(ShareItem.Images(listOf("content://x/1"), "image/png"),
            ShareIntent.parse(send, "image/png", null, listOf("content://x/1")))
    }

    @Test
    fun multipleImagesAreCapped() {
        val uris = (1..12).map { "content://x/$it" }
        val item = ShareIntent.parse(sendMultiple, "image/*", null, uris) as ShareItem.Images
        assertEquals(ShareIntent.MAX_IMAGES, item.streams.size)
    }

    @Test
    fun unsupportedTypes() {
        assertTrue(ShareIntent.parse(send, "image/jpeg", null, emptyList<String>()) is ShareItem.Unsupported)
        assertTrue(ShareIntent.parse(send, "application/pdf", null, listOf("content://x/1")) is ShareItem.Unsupported)
        assertTrue(ShareIntent.parse(send, "text/plain", "   ", emptyList<String>()) is ShareItem.Unsupported)
        assertTrue(ShareIntent.parse(sendMultiple, "video/mp4", null, listOf("content://x/1")) is ShareItem.Unsupported)
        assertTrue(ShareIntent.parse("android.intent.action.VIEW", "text/plain", "hi", emptyList<String>()) is ShareItem.Unsupported)
    }

    @Test
    fun oversizedTextIsTooLarge() {
        val item = ShareIntent.parse(send, "text/plain", "x".repeat(1_048_577), emptyList<String>())
        assertEquals(ShareStatus.TOO_LARGE, ShareDispatch.send(item, emptyList(), RecordingTarget()))
    }

    @Test
    fun noSessionMeansNoMacConnected() {
        val item = ShareItem.Text("hi", false)
        val unbound = ShareDispatch.send(item, emptyList(), null)
        assertEquals(ShareStatus.NO_SESSION, unbound)
        assertEquals("No Mac connected", ShareIntent.message(unbound, item))
        val target = RecordingTarget(status = ShareStatus.NO_SESSION)
        assertEquals("No Mac connected", ShareIntent.message(ShareDispatch.send(item, emptyList(), target), item))
    }

    @Test
    fun noSessionClosesOpenedImages() {
        val input = TrackingStream()
        val item = ShareItem.Images(listOf("content://x/1"), "image/png")
        assertEquals(ShareStatus.NO_SESSION, ShareDispatch.send(item, listOf(OpenedImage("a.png", "image/png", 3, input)), null))
        assertTrue(input.closed)
    }

    @Test
    fun imagesAreSentInOrderAndReportedSizeIsChecked() {
        val target = RecordingTarget()
        val item = ShareItem.Images(listOf("1", "2"), "image/*")
        val images = listOf(OpenedImage("a.png", "image/png", 3, ByteArrayInputStream(byteArrayOf(1))),
            OpenedImage("b.jpg", "image/jpeg", null, ByteArrayInputStream(byteArrayOf(2))))
        assertEquals(ShareStatus.OK, ShareDispatch.send(item, images, target))
        assertEquals(listOf("a.png", "b.jpg"), target.files)
        val huge = listOf(OpenedImage("c.png", "image/png", 52_428_801, ByteArrayInputStream(byteArrayOf())))
        assertEquals(ShareStatus.TOO_LARGE, ShareDispatch.send(item, huge, target))
        assertEquals(2, target.files.size)
    }

    private class RecordingTarget(val status: Int = ShareStatus.OK) : ShareTarget {
        val files = mutableListOf<String>()
        override fun text(text: String): Int = status
        override fun file(name: String, mime: String, input: InputStream): Int {
            files += name
            return status
        }
    }

    private class TrackingStream : InputStream() {
        var closed = false
        override fun read(): Int = -1
        override fun close() { closed = true }
    }
}
