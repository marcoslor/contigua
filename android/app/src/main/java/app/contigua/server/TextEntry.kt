package app.contigua.server

/** One key event of the virtual keyboard's key map: what a KEY frame carries. */
data class KeyStroke(val action: Int, val keycode: Int, val metaState: Int = 0)

/**
 * `ui.type` (docs/PROTOCOL.md "UI tree" item 10, MCP-109, MCP-110): typing
 * into the focused field of a display without ever touching the clipboard.
 *
 * Two routes (docs/design/mcp.md "Typing without the clipboard"): text the
 * virtual keyboard's key map can produce goes as KEY events at the cursor;
 * any other text is set whole on the focused node with `ACTION_SET_TEXT` —
 * the text before its selection + the typed text + the text after it — and
 * the cursor is put after the typed text with `ACTION_SET_SELECTION`. There is
 * no third route: what neither can type is refused, and nothing is typed.
 *
 * Pure: the focused node and the keyboard are ports, so every decision is a
 * JVM test (TextEntryTest). Nothing here logs; the session logs counts only.
 */
object TextEntry {

    const val INSERTED = "inserted"
    const val REPLACED = "replaced"
    const val UNKNOWN = "unknown"
    const val VIA_KEYS = "keys"
    const val VIA_SET_TEXT = "set_text"
    const val NO_FIELD = "no_field"
    const val NOT_SUPPORTED = "not_supported"

    /** The longest text item 10 takes, in characters (code points). */
    const val MAX_CHARACTERS = 2_000

    /**
     * The node with input focus as read now: its text (the hint, on some
     * nodes, while [showingHint]), its selection (`-1` when it reports none),
     * whether it is a password field, and whether it offers `ACTION_SET_TEXT`.
     */
    data class Field(
        val text: String?,
        val selectionStart: Int = -1,
        val selectionEnd: Int = selectionStart,
        val showingHint: Boolean = false,
        val password: Boolean = false,
        val setsText: Boolean = true,
    )

    /** The node with input focus: what it holds and its two actions. */
    interface Focus {
        val field: Field

        /** `ACTION_SET_TEXT`; false when the app refused it. */
        fun setText(text: String): Boolean

        /** `ACTION_SET_SELECTION`; false when the app refused it. */
        fun setSelection(start: Int, end: Int): Boolean
    }

    /** The keyboard: the virtual key map and the injector, never the clipboard. */
    interface Keys {
        /** [text]'s key events from `KeyCharacterMap.VIRTUAL_KEYBOARD`, or null when a character has none. */
        fun strokes(text: String): List<KeyStroke>?

        /** Injects [strokes] in order, stamped as KEY frames from the Mac are. */
        fun press(strokes: List<KeyStroke>)
    }

    sealed class Outcome {
        /** Typed: `entry` and `via` as item 10 answers them. */
        data class Typed(val entry: String, val via: String) : Outcome()

        /** Nothing typed: one of item 10's codes and its sentence. */
        data class Refused(val code: String, val sentence: String) : Outcome()
    }

    /** What a call will do, decided before anything is performed. */
    private sealed class Plan {
        data class Keys(val strokes: List<KeyStroke>, val entry: String) : Plan()
        data class Set(val text: String, val cursor: Int, val entry: String) : Plan()
        data class Refuse(val code: String) : Plan()
    }

    /**
     * Types [text] into [focus] (null: no node has input focus in the active
     * layer) on window [window], replacing what it holds when [clear], and
     * presses ENTER after when [submit]. Refused calls perform nothing; a set
     * action the app refuses stops there, with no selection and no ENTER.
     */
    fun type(window: Int, text: String, clear: Boolean, submit: Boolean, focus: Focus?, keys: Keys): Outcome {
        when (val plan = plan(text, clear, focus?.field, keys.strokes(text))) {
            is Plan.Refuse -> return Outcome.Refused(plan.code, sentence(plan.code, window))
            is Plan.Keys -> {
                keys.press(plan.strokes)
                if (submit) keys.press(ENTER)
                return Outcome.Typed(plan.entry, VIA_KEYS)
            }
            is Plan.Set -> {
                // Only a Set plan exists with a focus to set it on.
                if (!focus!!.setText(plan.text)) return Outcome.Refused(UiCodes.FAILED, sentence(UiCodes.FAILED, window))
                // The text is in: a refused cursor move does not undo it, so the
                // answer stays the typed one (item 10 has no partial code).
                focus.setSelection(plan.cursor, plan.cursor)
                if (submit) keys.press(ENTER)
                return Outcome.Typed(plan.entry, VIA_SET_TEXT)
            }
        }
    }

    /**
     * The decision (item 10): key-map text goes as keys unless `clear` can set
     * it whole; other text needs a focused node that offers set text and whose
     * text can be read (a password field holding text cannot) unless `clear`.
     * `clear` needs a field to clear: ctrl+A and DEL with none focused would
     * reach whatever else has key focus, so that is `no_field` (#270).
     */
    private fun plan(text: String, clear: Boolean, field: Field?, strokes: List<KeyStroke>?): Plan {
        val typed = text.length
        if (strokes != null) {
            if (!clear) return Plan.Keys(strokes, if (field == null) UNKNOWN else INSERTED)
            // #270: ctrl+A and DEL with no field clear something else (a mail
            // list selects everything and deletes it). Only a field is cleared.
            if (field == null) return Plan.Refuse(NO_FIELD)
            if (field.setsText) return Plan.Set(text, typed, REPLACED)
            return Plan.Keys(CLEAR + strokes, REPLACED)
        }
        if (field == null) return Plan.Refuse(NO_FIELD)
        if (!field.setsText) return Plan.Refuse(NOT_SUPPORTED)
        if (clear) return Plan.Set(text, typed, REPLACED)
        val held = if (field.showingHint) "" else field.text.orEmpty()
        if (field.password && held.isNotEmpty()) return Plan.Refuse(NOT_SUPPORTED)
        val (start, end) = selection(field, held.length)
        return Plan.Set(held.substring(0, start) + text + held.substring(end), start + typed, INSERTED)
    }

    /**
     * The span typing replaces, in UTF-16 units as the node reports it: its
     * selection in order and inside the text, the end when it reports none;
     * a shown hint is no text, so its selection counts for nothing.
     */
    private fun selection(field: Field, length: Int): Pair<Int, Int> {
        val a = field.selectionStart
        val b = field.selectionEnd
        if (field.showingHint || a < 0 || b < 0) return length to length
        return minOf(a, b).coerceIn(0, length) to maxOf(a, b).coerceIn(0, length)
    }

    /** A node as the input-focus search reads it: two flags, never its text. */
    data class Shape(val editable: Boolean, val focused: Boolean)

    /** The most nodes [inputFocus] reads under a host before it keeps the host. */
    const val MAX_FOCUS_SEARCH = 2_000

    /**
     * The node with input focus (MCP-105, MCP-109): what `findFocus(FOCUS_INPUT)`
     * [found], unless it is not editable and hosts a virtual tree with an
     * editable node that reports focus, then that node. A WebView whose
     * provider reports no input focus is answered as the WebView itself, which
     * offers no `ACTION_SET_TEXT`; its focused `<input>` is in its tree. Depth
     * first, at most [UiTree.MAX_DEPTH] deep and [MAX_FOCUS_SEARCH] nodes; no
     * such node keeps [found] (a focused canvas stays the host).
     */
    fun <N : Any> inputFocus(found: N?, shape: (N) -> Shape, children: (N) -> List<N>): N? {
        if (found == null || shape(found).editable) return found
        var read = 0
        fun search(node: N, depth: Int): N? {
            if (depth >= UiTree.MAX_DEPTH) return null
            for (child in children(node)) {
                if (++read > MAX_FOCUS_SEARCH) return null
                val s = shape(child)
                if (s.editable && s.focused) return child
                search(child, depth + 1)?.let { return it }
            }
            return null
        }
        return search(found, 0) ?: found
    }

    /** Item 10's sentence for [code] on window [window]. */
    fun sentence(code: String, window: Int): String = when (code) {
        NO_FIELD -> "Window $window has no focused text field. Tap the field first."
        NOT_SUPPORTED -> "The focused field on window $window can't take this text: type only letters, digits " +
            "and symbols a keyboard has, or pass clear: true to replace what is there."
        else -> "The focused field on window $window refused the text."
    }

    /** `KeyEvent.ACTION_DOWN`, `ACTION_UP`; this file stays free of Android imports. */
    private const val DOWN = 0
    private const val UP = 1
    private const val KEYCODE_A = 29
    private const val KEYCODE_DEL = 67
    private const val KEYCODE_ENTER = 66

    /** `META_CTRL_ON | META_CTRL_LEFT_ON`. */
    private const val CTRL = 0x1000 or 0x2000

    /** ctrl+A, then DEL: select everything and delete it, as a keyboard would. */
    private val CLEAR = listOf(
        KeyStroke(DOWN, KEYCODE_A, CTRL), KeyStroke(UP, KEYCODE_A, CTRL),
        KeyStroke(DOWN, KEYCODE_DEL), KeyStroke(UP, KEYCODE_DEL),
    )

    private val ENTER = listOf(KeyStroke(DOWN, KEYCODE_ENTER), KeyStroke(UP, KEYCODE_ENTER))
}

/**
 * The shell side of `ui.type`: a [UiTreeSource] that can also type into the
 * focused node of a display. Blocking: the session calls it off the reader
 * thread, under the one-`ui.*` rule.
 */
interface UiTypeSource {
    /**
     * Finds the node with input focus in [displayId]'s active layer and types
     * [text] into it through [TextEntry.type]; [keys] is the session's own
     * keyboard. [window] names the stream in a refusal's sentence.
     */
    fun type(displayId: Int, window: Int, text: String, clear: Boolean, submit: Boolean, keys: TextEntry.Keys): TextEntry.Outcome
}
