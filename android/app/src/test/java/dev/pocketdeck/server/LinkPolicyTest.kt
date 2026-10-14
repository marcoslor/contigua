package dev.pocketdeck.server

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class LinkPolicyTest {
    @Test
    fun allowsTheViewSchemes() {
        for (url in listOf(
            "https://example.com", "http://example.com:8080/x?y#z", "HTTPS://Example.com",
            "https://maps.google.com/?q=Lisbon", "https://www.youtube.com/watch?v=abc",
            "geo:38.72,-9.14?q=Lisbon", "tel:+351210000000", "mailto:a@example.com?subject=hi",
            "https://user@example.com/",
        )) assertEquals(url, LinkPolicy.validate(url))
    }

    @Test
    fun trimsSurroundingWhitespace() {
        assertEquals("https://example.com", LinkPolicy.validate("  https://example.com\n"))
    }

    @Test
    fun rejectsEverythingElse() {
        for (url in listOf(
            null, "", "   ", "intent://scan/#Intent;scheme=zxing;end", "INTENT:#Intent;end",
            "file:///etc/hosts", "content://com.android.contacts/contacts", "javascript:alert(1)",
            "android-app://com.x/https/example.com", "market://details?id=x", "example.com",
            "https:example.com", "https://", "https:///path", "https://exa mple.com", "https://a.com/\u0000",
            "tel:", ":https://x", "1http://x", "https://a.com/" + "a".repeat(LinkPolicy.MAX_BYTES),
        )) assertNull("accepted '$url'", LinkPolicy.validate(url))
    }

    @Test
    fun limitIsInUtf8Bytes() {
        val base = "https://a.com/"
        val fits = base + "a".repeat(LinkPolicy.MAX_BYTES - base.length)
        assertEquals(fits, LinkPolicy.validate(fits))
        val tooLong = base + "é".repeat((LinkPolicy.MAX_BYTES - base.length) / 2 + 1)
        assertNull(LinkPolicy.validate(tooLong))
    }
}
