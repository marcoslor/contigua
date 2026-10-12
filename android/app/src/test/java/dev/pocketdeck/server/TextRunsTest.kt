package dev.pocketdeck.server

import org.junit.Assert.assertEquals
import org.junit.Test

class TextRunsTest {

    @Test
    fun plainAsciiIsOneKeysRun() {
        assertEquals(listOf(TextRuns.Run.Keys("hello world")), TextRuns.split("hello world"))
    }

    @Test
    fun emptyTextHasNoRuns() {
        assertEquals(emptyList<TextRuns.Run>(), TextRuns.split(""))
    }

    @Test
    fun nonAsciiBecomesAClipboardRun() {
        assertEquals(
            listOf(TextRuns.Run.Keys("caf"), TextRuns.Run.Clip("é")),
            TextRuns.split("café"),
        )
    }

    @Test
    fun runsAlternateAndPreserveOrder() {
        // c a f are ASCII, é is not, the space is ASCII again, ☕ is not.
        assertEquals(
            listOf(
                TextRuns.Run.Keys("caf"),
                TextRuns.Run.Clip("é"),
                TextRuns.Run.Keys(" "),
                TextRuns.Run.Clip("☕"),
            ),
            TextRuns.split("café ☕"),
        )
    }

    @Test
    fun surrogatePairEmojiStaysIntact() {
        val recombined = TextRuns.split("😀").joinToString("") {
            when (it) {
                is TextRuns.Run.Keys -> it.text
                is TextRuns.Run.Clip -> it.text
            }
        }
        assertEquals("😀", recombined)
        assertEquals(listOf(TextRuns.Run.Clip("😀")), TextRuns.split("😀"))
    }

    @Test
    fun leadingNonAsciiStartsWithClip() {
        assertEquals(
            listOf(TextRuns.Run.Clip("ã"), TextRuns.Run.Keys("b")),
            TextRuns.split("ãb"),
        )
    }
}
