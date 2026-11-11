package app.contigua.app

import app.contigua.server.ShareSender
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class OpenOnMacIntentTest {

    @Test
    fun processTextUrlIsALink() {
        assertEquals(ShareItem.Text("https://example.com/pt", true), ShareIntent.parseProcessText(" https://example.com/pt\n"))
    }

    @Test
    fun processTextPlainIsText() {
        assertEquals(ShareItem.Text("hello there", false), ShareIntent.parseProcessText("hello there"))
    }

    @Test
    fun processTextEmptyAndTooLong() {
        assertEquals(ShareItem.Unsupported("empty"), ShareIntent.parseProcessText(null))
        assertEquals(ShareItem.Unsupported("empty"), ShareIntent.parseProcessText("  \n"))
        assertEquals(ShareItem.Unsupported(ShareIntent.TOO_LARGE),
            ShareIntent.parseProcessText("a".repeat(ShareSender.MAX_TEXT_BYTES + 1)))
    }

    @Test
    fun viewAcceptsHttpAndHttps() {
        assertEquals(ShareItem.Text("http://example.com/a", true), ShareIntent.parseView("http://example.com/a"))
        assertEquals(ShareItem.Text("https://example.com/view?q=1", true), ShareIntent.parseView("https://example.com/view?q=1"))
    }

    @Test
    fun viewRejectsOtherSchemes() {
        for (u in listOf("file:///etc/hosts", "content://x/1", "intent://x#Intent;end", "javascript:alert(1)",
                "contigua://pair", "", null)) {
            assertNull(u, ShareIntent.parseView(u))
        }
    }

    @Test
    fun viewRejectsOverLinkPolicyMax() {
        assertNull(ShareIntent.parseView("https://example.com/" + "a".repeat(8 * 1024)))
    }
}
