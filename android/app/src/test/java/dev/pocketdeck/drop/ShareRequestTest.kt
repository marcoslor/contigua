package dev.pocketdeck.drop

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * The trampoline's name check (docs/design/dragdrop.md): an exported activity
 * anyone can start must share a staged file only when the name is a bare name
 * the drop's own sanitiser leaves alone.
 */
class ShareRequestTest {

    @Test
    fun plainNamesAreAccepted() {
        assertEquals("report.pdf", ShareRequest.parse("report.pdf", "application/pdf")?.name)
        assertEquals("report 2.pdf", ShareRequest.parse("report 2.pdf", "application/pdf")?.name)
        // A name whose extension is not in the MIME table keeps the empty extension.
        assertEquals("notes", ShareRequest.parse("notes", "application/octet-stream")?.name)
    }

    @Test
    fun pathsAndTraversalAreRefused() {
        assertNull(ShareRequest.parse("../../../data/x", "text/plain"))
        assertNull(ShareRequest.parse("a/b.txt", "text/plain"))
        assertNull(ShareRequest.parse("/sdcard/Download/PocketDeck/x.txt", "text/plain"))
        assertNull(ShareRequest.parse("..\\..\\x.txt", "text/plain"))
        assertNull(ShareRequest.parse("..", "text/plain"))
        assertNull(ShareRequest.parse(".hidden.txt", "application/pdf"))
    }

    @Test
    fun namesTheSanitiserWouldRewriteAreRefused() {
        // Unicode, a stray character, a missing extension and an over-long name all
        // come out of the sanitiser differently: never the same file name twice.
        assertNull(ShareRequest.parse("写真.pdf", "application/pdf"))
        assertNull(ShareRequest.parse("report*.pdf", "application/pdf"))
        assertNull(ShareRequest.parse("notes", "text/plain"))
        assertNull(ShareRequest.parse("N".repeat(150) + ".pdf", "application/pdf"))
        assertNull(ShareRequest.parse("", "text/plain"))
        assertNull(ShareRequest.parse(null, "text/plain"))
    }

    @Test
    fun theMimeTypeIsCheckedToo() {
        assertEquals(ShareRequest.DEFAULT_MIME, ShareRequest.parse("a.bin", null)?.mime)
        assertEquals(ShareRequest.DEFAULT_MIME, ShareRequest.parse("a.bin", "")?.mime)
        assertEquals("image/jpeg", ShareRequest.parse("a.jpg", "image/jpeg")?.mime)
        assertNull(ShareRequest.parse("a.bin", "text"))
        assertNull(ShareRequest.parse("a.bin", "text/plain; charset=utf-8"))
        assertNull(ShareRequest.parse("a.bin", "text/plain "))
    }
}
