package app.contigua.server

import android.view.KeyEvent
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import java.util.concurrent.CopyOnWriteArrayList

/**
 * `ui.type`'s decisions (docs/PROTOCOL.md "UI tree" item 10, MCP-109) and its
 * one rule: no route touches the clipboard (MCP-110). One test per decision;
 * the focused node and the keyboard are recorders, so each test says exactly
 * which actions and keys a call performs.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class TextEntryTest {

    /** The key map has printable ASCII only, one down/up per character. */
    private class RecordingKeys : TextEntry.Keys {
        val pressed = mutableListOf<KeyStroke>()
        override fun strokes(text: String): List<KeyStroke>? =
            if (text.all { it.code in 0x20..0x7E }) text.flatMap { listOf(KeyStroke(DOWN, it.code), KeyStroke(UP, it.code)) } else null
        override fun press(strokes: List<KeyStroke>) {
            pressed += strokes
        }
    }

    /** A focused node that records its actions; [accepts] and [selects] say whether the app takes them. */
    private class RecordingFocus(
        override val field: TextEntry.Field,
        private val accepts: Boolean = true,
        private val selects: Boolean = true,
    ) : TextEntry.Focus {
        val actions = mutableListOf<String>()
        override fun setText(text: String): Boolean {
            actions += "set_text:$text"
            return accepts
        }
        override fun setSelection(start: Int, end: Int): Boolean {
            actions += "set_selection:$start,$end"
            return selects
        }
    }

    private val keys = RecordingKeys()

    private fun type(text: String, focus: TextEntry.Focus?, clear: Boolean = false, submit: Boolean = false) =
        TextEntry.type(3, text, clear, submit, focus, keys)

    private fun strokesOf(text: String) = text.flatMap { listOf(KeyStroke(DOWN, it.code), KeyStroke(UP, it.code)) }

    private val typed = TextEntry.Outcome::Typed

    @Test
    fun testKeyMapTextIsKeys() { // [MCP-109]
        val focus = RecordingFocus(TextEntry.Field("lista", 5))
        assertEquals(typed(TextEntry.INSERTED, TextEntry.VIA_KEYS), type("milk 42", focus))
        assertEquals(strokesOf("milk 42"), keys.pressed)
        assertEquals("keys at the cursor: the node's text is never set", emptyList<String>(), focus.actions)
    }

    @Test
    fun testOtherTextIsSetAtTheCursor() { // [MCP-109]
        val focus = RecordingFocus(TextEntry.Field("garrafa 500ml", 8, 8))
        assertEquals(typed(TextEntry.INSERTED, TextEntry.VIA_SET_TEXT), type("térmica ", focus))
        assertEquals(listOf("set_text:garrafa térmica 500ml", "set_selection:16,16"), focus.actions)
        assertEquals(emptyList<KeyStroke>(), keys.pressed)
    }

    @Test
    fun testASelectionIsReplaced() { // [MCP-109]
        val focus = RecordingFocus(TextEntry.Field("garrafa 500ml", 0, 7))
        assertEquals(typed(TextEntry.INSERTED, TextEntry.VIA_SET_TEXT), type("térmica", focus))
        assertEquals(listOf("set_text:térmica 500ml", "set_selection:7,7"), focus.actions)
        // A selection made backwards (the anchor after the focus) is the same span.
        val backwards = RecordingFocus(TextEntry.Field("garrafa 500ml", 7, 0))
        type("térmica", backwards)
        assertEquals(listOf("set_text:térmica 500ml", "set_selection:7,7"), backwards.actions)
    }

    @Test
    fun testNoSelectionGoesAtTheEnd() { // [MCP-109]
        val focus = RecordingFocus(TextEntry.Field("garrafa", -1, -1))
        assertEquals(typed(TextEntry.INSERTED, TextEntry.VIA_SET_TEXT), type(" térmica", focus))
        assertEquals(listOf("set_text:garrafa térmica", "set_selection:15,15"), focus.actions)
    }

    @Test
    fun testAShownHintCountsAsEmpty() { // [MCP-109]
        // The node reports its hint as its text while the hint shows (MCP-104).
        val focus = RecordingFocus(TextEntry.Field("Search", 0, 0, showingHint = true))
        assertEquals(typed(TextEntry.INSERTED, TextEntry.VIA_SET_TEXT), type("café", focus))
        assertEquals(listOf("set_text:café", "set_selection:4,4"), focus.actions)
    }

    @Test
    fun testClearReplaces() { // [MCP-109]
        // With set text: key-map text and other text alike are set whole.
        val sets = RecordingFocus(TextEntry.Field("old text", 3, 3))
        assertEquals(typed(TextEntry.REPLACED, TextEntry.VIA_SET_TEXT), type("milk 42", sets, clear = true))
        assertEquals(listOf("set_text:milk 42", "set_selection:7,7"), sets.actions)
        val setsOther = RecordingFocus(TextEntry.Field("old text", 3, 3))
        assertEquals(typed(TextEntry.REPLACED, TextEntry.VIA_SET_TEXT), type("café", setsOther, clear = true))
        assertEquals(listOf("set_text:café", "set_selection:4,4"), setsOther.actions)
        assertEquals(emptyList<KeyStroke>(), keys.pressed)

        // Without set text, key-map text goes as ctrl+A, DEL, then its keys.
        val noSet = RecordingFocus(TextEntry.Field("old text", 3, 3, setsText = false))
        assertEquals(typed(TextEntry.REPLACED, TextEntry.VIA_KEYS), type("milk 42", noSet, clear = true))
        val ctrl = KeyEvent.META_CTRL_ON or KeyEvent.META_CTRL_LEFT_ON
        val clearing = listOf(
            KeyStroke(DOWN, KeyEvent.KEYCODE_A, ctrl), KeyStroke(UP, KeyEvent.KEYCODE_A, ctrl),
            KeyStroke(DOWN, KeyEvent.KEYCODE_DEL), KeyStroke(UP, KeyEvent.KEYCODE_DEL),
        )
        assertEquals(clearing + strokesOf("milk 42"), keys.pressed)
        assertEquals(emptyList<String>(), noSet.actions)
    }

    @Test
    fun testAPasswordWithTextNeedsClear() { // [MCP-109]
        // Its text reads as dots, so before + typed + after cannot be built.
        val holding = RecordingFocus(TextEntry.Field("••••", 4, 4, password = true))
        val refused = type("senhá", holding)
        assertTrue(refused is TextEntry.Outcome.Refused)
        assertEquals(TextEntry.NOT_SUPPORTED, (refused as TextEntry.Outcome.Refused).code)
        assertEquals(emptyList<String>(), holding.actions)
        assertEquals(emptyList<KeyStroke>(), keys.pressed)
        // With clear it is replaced whole.
        assertEquals(typed(TextEntry.REPLACED, TextEntry.VIA_SET_TEXT), type("senhá", holding, clear = true))
        assertEquals(listOf("set_text:senhá", "set_selection:5,5"), holding.actions)
        // Key-map text needs no reading: it goes as keys at the cursor.
        val keyed = RecordingFocus(TextEntry.Field("••••", 4, 4, password = true))
        assertEquals(typed(TextEntry.INSERTED, TextEntry.VIA_KEYS), type("abc1", keyed))
        assertEquals(emptyList<String>(), keyed.actions)
        // An empty password field holds nothing to keep.
        val empty = RecordingFocus(TextEntry.Field(null, password = true))
        assertEquals(typed(TextEntry.INSERTED, TextEntry.VIA_SET_TEXT), type("senhá", empty))
        assertEquals(listOf("set_text:senhá", "set_selection:5,5"), empty.actions)
    }

    @Test
    fun testNoFocusForOtherTextIsNoField() { // [MCP-109]
        assertEquals(
            TextEntry.Outcome.Refused(TextEntry.NO_FIELD, "Window 3 has no focused text field. Tap the field first."),
            type("café", null),
        )
        assertEquals(TextEntry.NO_FIELD, (type("café", null, clear = true) as TextEntry.Outcome.Refused).code)
        assertEquals(emptyList<KeyStroke>(), keys.pressed)
    }

    @Test
    fun testNoFocusForKeyMapTextIsUnknown() { // [MCP-109]
        assertEquals(typed(TextEntry.UNKNOWN, TextEntry.VIA_KEYS), type("milk 42", null))
        assertEquals(strokesOf("milk 42"), keys.pressed)
    }

    /**
     * #270 item 2: `clear` with no focused field sent ctrl+A and DEL to
     * whatever held key focus (a mail or file list selects everything and
     * deletes it), which breaks "never remove anything on the phone". Clearing
     * needs a field to clear, so it refuses `no_field` and sends nothing —
     * key-map text included.
     */
    @Test
    fun testClearWithNoFocusIsNoField() { // [MCP-109]
        assertEquals(
            TextEntry.Outcome.Refused(TextEntry.NO_FIELD, "Window 3 has no focused text field. Tap the field first."),
            type("milk 42", null, clear = true),
        )
        assertEquals("ctrl+A and DEL went to whatever had focus", emptyList<KeyStroke>(), keys.pressed)
        assertEquals(TextEntry.NO_FIELD, (type("café", null, clear = true) as TextEntry.Outcome.Refused).code)
        assertEquals(emptyList<KeyStroke>(), keys.pressed)
        assertEquals(TextEntry.NO_FIELD,
            (type("milk 42", null, clear = true, submit = true) as TextEntry.Outcome.Refused).code)
        assertEquals("no ENTER either", emptyList<KeyStroke>(), keys.pressed)
    }

    @Test
    fun testNoSetTextActionIsNotSupported() { // [MCP-109]
        val canvas = RecordingFocus(TextEntry.Field("draw", 4, 4, setsText = false))
        assertEquals(
            TextEntry.Outcome.Refused(
                TextEntry.NOT_SUPPORTED,
                "The focused field on window 3 can't take this text: type only letters, digits and symbols " +
                    "a keyboard has, or pass clear: true to replace what is there.",
            ),
            type("café", canvas),
        )
        assertEquals(TextEntry.NOT_SUPPORTED, (type("café", canvas, clear = true) as TextEntry.Outcome.Refused).code)
        assertEquals(emptyList<String>(), canvas.actions)
        assertEquals(emptyList<KeyStroke>(), keys.pressed)
    }

    @Test
    fun testNotSupportedWithClearAlreadyTrueDoesNotSuggestClear_MCP109() {
        // S3: a booking app's destination field offers no set text; the caller
        // passed clear: true, so suggesting it again hides the real fix (plain
        // keyboard characters, no accents).
        val canvas = RecordingFocus(TextEntry.Field("Florianópolis", 12, 12, setsText = false))
        val refused = type("Florianópolis", canvas, clear = true)
        assertTrue(refused is TextEntry.Outcome.Refused)
        val sentence = (refused as TextEntry.Outcome.Refused).sentence
        assertEquals(TextEntry.NOT_SUPPORTED, refused.code)
        assertFalse("the sentence suggests clear again: $sentence", sentence.contains("clear: true"))
        assertTrue("the sentence does not name the keyboard: $sentence", sentence.contains("keyboard"))
        assertTrue("the sentence does not rule out accents: $sentence", sentence.contains("no accents"))
        assertEquals(emptyList<String>(), canvas.actions)
        assertEquals(emptyList<KeyStroke>(), keys.pressed)
        // Without clear the way through is still named.
        val plain = type("Florianópolis", RecordingFocus(TextEntry.Field("x", 1, 1, setsText = false)))
        assertTrue((plain as TextEntry.Outcome.Refused).sentence.contains("clear: true"))
    }

    @Test
    fun testARefusedActionFails() { // [MCP-109]
        val refusing = RecordingFocus(TextEntry.Field("garrafa", -1, -1), accepts = false)
        val outcome = type("térmica", refusing, submit = true)
        assertTrue(outcome is TextEntry.Outcome.Refused)
        assertEquals(UiCodes.FAILED, (outcome as TextEntry.Outcome.Refused).code)
        assertEquals("the set was tried once, then nothing else", listOf("set_text:garrafatérmica"), refusing.actions)
        assertEquals("no ENTER after a failure", emptyList<KeyStroke>(), keys.pressed)
    }

    @Test
    fun testSubmitPressesEnterLast() { // [MCP-109]
        val enter = listOf(KeyStroke(DOWN, KeyEvent.KEYCODE_ENTER), KeyStroke(UP, KeyEvent.KEYCODE_ENTER))
        type("milk 42", RecordingFocus(TextEntry.Field("", 0, 0)), submit = true)
        assertEquals(strokesOf("milk 42") + enter, keys.pressed)
        keys.pressed.clear()
        val focus = RecordingFocus(TextEntry.Field("", 0, 0))
        type("café", focus, submit = true)
        assertEquals(listOf("set_text:café", "set_selection:4,4"), focus.actions)
        assertEquals(enter, keys.pressed)
    }

    // MARK: the field (MCP-105, MCP-109)

    /** A node of a window's tree: its two flags and its children, and how often its children were read. */
    private class Node(val name: String, val editable: Boolean = false, val focused: Boolean = false, vararg kids: Node) {
        val children = kids.toList()
        var reads = 0
    }

    private fun focusOf(found: Node?) = TextEntry.inputFocus(
        found,
        shape = { TextEntry.Shape(it.editable, it.focused) },
        children = { it.reads++; it.children },
    )?.name

    /**
     * B5's emulator proof: the page's <input>, pressed and focused, answered
     * `not_supported` for "térmica " and for `clear`. `findFocus(FOCUS_INPUT)`
     * found the WebView itself (its provider reports no input focus, so the
     * framework answers the host view), which offers no ACTION_SET_TEXT; the
     * input is the focused editable node of the host's virtual tree.
     */
    @Test
    fun testAWebViewsFocusedInputIsTheField() { // [MCP-109] [MCP-105]
        val input = Node("input", editable = true, focused = true)
        val page = Node("page", false, false, Node("heading"), Node("form", false, false, Node("label"), input))
        val webView = Node("webview", false, true, page)
        assertEquals("input", focusOf(webView))
    }

    @Test
    fun testAnEditableFocusIsTheFieldAsFound() { // [MCP-109] [MCP-105]
        val editText = Node("edittext", editable = true, focused = true)
        assertEquals("edittext", focusOf(editText))
        assertEquals("an editable focus is never searched under", 0, editText.reads)
        assertNull(focusOf(null))
    }

    @Test
    fun testAHostWithNoFocusedEditableStaysTheField() { // [MCP-109] [MCP-105]
        // The canvas page: its focused node takes keys and is not editable, and
        // an editable node elsewhere has no focus: the host stays the field, so
        // other text is still refused not_supported.
        val canvas = Node("canvas", editable = false, focused = true)
        val other = Node("other-input", editable = true, focused = false)
        val webView = Node("webview", false, true, Node("page", false, false, canvas, other))
        assertEquals("webview", focusOf(webView))
    }

    // MARK: MCP-110

    /** Records every call; a call of any kind is a failure of MCP-110. */
    private class RecordingClipboard : ClipboardPort {
        val calls = CopyOnWriteArrayList<String>()
        override fun getText(): ClipText? {
            calls += "getText"
            return null
        }
        override fun setText(text: String) {
            calls += "setText"
        }
        override fun listen(onChange: () -> Unit): ClipRegistration {
            calls += "listen"
            return ClipRegistration(onChange)
        }
        override fun stop(registration: ClipRegistration?) {
            calls += "stop"
        }
    }

    @Test
    fun testNoRouteTouchesTheClipboard() { // [MCP-110]
        val clipboard = RecordingClipboard()
        val delivered = CopyOnWriteArrayList<Int>()
        // The real injector holds the clipboard its `text` path pastes through:
        // `ui.type`'s keys go through the same injector and must never reach it.
        val injector = AndroidInjector(log = {}, sink = { e, _ -> delivered += (e as KeyEvent).keyCode }, clipboard = clipboard)
        val keys = object : TextEntry.Keys {
            override fun strokes(text: String) = injector.keyStrokes(text)
            override fun press(strokes: List<KeyStroke>) {
                for (s in strokes) injector.key(0, s.action, s.keycode, s.metaState, 1L, 1L)
            }
        }
        assertNotNull("key-map text has keys", injector.keyStrokes("milk 42"))
        assertNull("é has no key in the virtual key map", injector.keyStrokes("café"))

        fun field(text: String?, setsText: Boolean = true, password: Boolean = false) =
            RecordingFocus(TextEntry.Field(text, 2, 2, password = password, setsText = setsText))
        val outcomes = listOf(
            TextEntry.type(3, "milk 42", false, true, field("ab"), keys),
            TextEntry.type(3, "café", false, true, field("ab"), keys),
            TextEntry.type(3, "milk 42", true, false, field("ab"), keys),
            TextEntry.type(3, "milk 42", true, false, field("ab", setsText = false), keys),
            TextEntry.type(3, "café", true, false, field("ab"), keys),
            TextEntry.type(3, "café", false, false, field("••", password = true), keys),
            TextEntry.type(3, "café", true, false, field("••", password = true), keys),
            TextEntry.type(3, "café", false, false, field("ab", setsText = false), keys),
            TextEntry.type(3, "café", false, false, RecordingFocus(TextEntry.Field("ab", 2, 2), accepts = false), keys),
            TextEntry.type(3, "café", false, false, null, keys),
            TextEntry.type(3, "milk 42", false, false, null, keys),
        )
        // Every route ran: keys, set text, both refusals and the failure.
        assertEquals(
            listOf("keys", "set_text", "set_text", "keys", "set_text", TextEntry.NOT_SUPPORTED, "set_text",
                TextEntry.NOT_SUPPORTED, UiCodes.FAILED, TextEntry.NO_FIELD, "keys"),
            outcomes.map { if (it is TextEntry.Outcome.Typed) it.via else (it as TextEntry.Outcome.Refused).code },
        )
        assertTrue("keys were injected", delivered.isNotEmpty())
        assertEquals("no route touches the clipboard", emptyList<String>(), clipboard.calls.toList())
    }

    private companion object {
        const val DOWN = KeyEvent.ACTION_DOWN
        const val UP = KeyEvent.ACTION_UP
    }
}
