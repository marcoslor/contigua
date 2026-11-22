package app.contigua.server

/** One key event of the virtual keyboard's key map: what a KEY frame carries. */
data class KeyStroke(val action: Int, val keycode: Int, val metaState: Int = 0)

/**
 * `ui.type` (docs/PROTOCOL.md "UI tree" item 10, MCP-109, MCP-110): typing
 * into the focused field without the clipboard. Stub: B5's tests come first.
 */
object TextEntry {

    const val INSERTED = "inserted"
    const val REPLACED = "replaced"
    const val UNKNOWN = "unknown"
    const val VIA_KEYS = "keys"
    const val VIA_SET_TEXT = "set_text"
    const val NO_FIELD = "no_field"
    const val NOT_SUPPORTED = "not_supported"

    /** The node with input focus as read now. */
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
        fun setText(text: String): Boolean
        fun setSelection(start: Int, end: Int): Boolean
    }

    /** The keyboard: the virtual key map and the injector. */
    interface Keys {
        fun strokes(text: String): List<KeyStroke>?
        fun press(strokes: List<KeyStroke>)
    }

    sealed class Outcome {
        data class Typed(val entry: String, val via: String) : Outcome()
        data class Refused(val code: String, val sentence: String) : Outcome()
    }

    fun type(window: Int, text: String, clear: Boolean, submit: Boolean, focus: Focus?, keys: Keys): Outcome =
        TODO("B5")
}

/** The shell side of `ui.type`. */
interface UiTypeSource {
    fun type(displayId: Int, window: Int, text: String, clear: Boolean, submit: Boolean, keys: TextEntry.Keys): TextEntry.Outcome
}
