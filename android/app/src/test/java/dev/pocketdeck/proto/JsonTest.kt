package dev.pocketdeck.proto

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

class JsonTest {

    @Test
    fun parsesNestedStructures() {
        val v = Json.parseObject("""{"a":{"b":[1,2,{"c":"d"}],"e":true},"f":null}""")
        @Suppress("UNCHECKED_CAST")
        val a = v["a"] as Map<String, Any?>
        val b = a["b"] as List<Any?>
        assertEquals(3, b.size)
        assertEquals(1L, b[0])
        assertEquals(2L, b[1])
        assertEquals("d", (b[2] as Map<*, *>)["c"])
        assertEquals(true, a["e"])
        assertNull(v["f"])
    }

    @Test
    fun decodesEscapes() {
        val v = Json.parseObject("""{"s":"a\"b\\c\/d\b\f\n\r\t\u0041\u00e9"}""")
        assertEquals("a\"b\\c/d\b\u000C\n\r\tA\u00e9", v["s"])
    }

    @Test
    fun decodesSurrogatePair() {
        val v = Json.parseObject("""{"s":"\ud83d\ude00"}""")
        assertEquals("\uD83D\uDE00", v["s"])
    }

    @Test
    fun encodesEscapesAndRoundTrips() {
        val original = mapOf(
            "quote" to "he said \"hi\"\nback\\slash",
            "emoji" to "\uD83D\uDE00",
            "tab" to "a\tb",
        )
        val text = Json.encode(original)
        val back = Json.parseObject(text)
        assertEquals(original, back)
    }

    @Test
    fun parsesNumbers() {
        val v = Json.parseObject("""{"i":42,"neg":-7,"d":1.5,"e":2e3,"big":1234567890123}""")
        assertEquals(42L, v["i"])
        assertEquals(-7L, v["neg"])
        assertEquals(1.5, v["d"])
        assertEquals(2000.0, v["e"])
        assertEquals(1234567890123L, v["big"])
    }

    @Test
    fun encodesLongAndDoubleDistinctly() {
        assertEquals("""{"a":1,"b":1.0}""", Json.encode(mapOf("a" to 1L, "b" to 1.0)))
    }

    @Test
    fun rejectsTrailingInput() {
        try {
            Json.parse("{} extra")
            fail("expected JsonException")
        } catch (expected: JsonException) {
            assertTrue(expected.message!!.contains("trailing"))
        }
    }

    @Test
    fun capsNestingDepth() {
        // 10 000 `[` must fail as a JsonException, not with a StackOverflowError.
        try {
            Json.parse("[".repeat(10_000))
            fail("expected JsonException for a deeply nested payload")
        } catch (e: JsonException) {
            assertTrue("unexpected message: ${e.message}", e.message!!.contains("nesting"))
        }
        // 64 levels parse; 65 are refused.
        assertTrue(Json.parse("[".repeat(64) + "]".repeat(64)) is List<*>)
        try {
            Json.parse("[".repeat(65) + "]".repeat(65))
            fail("65 levels must be rejected")
        } catch (_: JsonException) {
            // expected
        }
    }

    @Test
    fun rejectsMalformed() {
        for (bad in listOf("{", "{\"a\":}", "[1,]", "\"unterminated", "01x", "tru")) {
            try {
                Json.parse(bad)
                fail("expected JsonException for $bad")
            } catch (_: JsonException) {
                // expected
            }
        }
    }
}
