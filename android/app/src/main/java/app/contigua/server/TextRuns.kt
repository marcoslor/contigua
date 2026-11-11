package app.contigua.server

/**
 * Splits typed text into runs that [android.view.KeyCharacterMap] can turn into
 * key events (ASCII) and runs it cannot (anything non-ASCII — `é`, `ç`, `ã`,
 * emoji, …), which must be delivered through the clipboard instead.
 *
 * Pure (no Android imports) so the split can be JVM-tested.
 */
internal object TextRuns {

    sealed class Run {
        /** Typeable through `KeyCharacterMap.getEvents`. */
        data class Keys(val text: String) : Run()

        /** Only deliverable by setting the clipboard and injecting paste. */
        data class Clip(val text: String) : Run()
    }

    fun split(text: String): List<Run> {
        val runs = ArrayList<Run>()
        val buf = StringBuilder()
        var ascii = true
        for (ch in text) {
            val isAscii = ch.code <= 0x7F
            if (buf.isNotEmpty() && isAscii != ascii) {
                runs.add(run(ascii, buf.toString()))
                buf.setLength(0)
            }
            ascii = isAscii
            buf.append(ch)
        }
        if (buf.isNotEmpty()) runs.add(run(ascii, buf.toString()))
        return runs
    }

    private fun run(ascii: Boolean, text: String): Run =
        if (ascii) Run.Keys(text) else Run.Clip(text)
}
