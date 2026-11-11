package app.contigua.server

/**
 * Parses the two shell-side dumps behind `state.secure` (docs/PROTOCOL.md
 * "Secure screens"). Pure so the format that a real API 36 build prints —
 * flag *names* on a continuation line, not the old hex `fl=` — is pinned by a
 * JVM test instead of a device boot.
 *
 * A `dumpsys window` excerpt is expected to keep the display block's focus
 * line, the window headers, the `mAttrs` lines and the `fl=` lines.
 */
internal object SecureDump {

    /** FLAG_SECURE's bit in the numeric form some builds print. */
    const val FLAG_SECURE = 0x00002000

    /**
     * Display 0's focused window has FLAG_SECURE; null when the dump has no
     * focus line or no flag line for that window (unreadable, not "not secure").
     */
    fun focusedSecure(dump: String): Boolean? {
        var display = -1
        var token: String? = null
        for (line in dump.lineSequence()) {
            val header = DISPLAY.find(line)
            if (header != null) {
                display = header.groupValues[1].toIntOrNull() ?: -1
                continue
            }
            val focus = FOCUS.find(line) ?: continue
            if (display == 0) token = focus.groupValues[1]
        }
        val focused = token ?: return null

        var inWindow = false
        for (line in dump.lineSequence()) {
            val header = WINDOW_HEADER.find(line)
            if (header != null) {
                // A second window header means the focused block ended without
                // flag lines, which no known build does.
                if (inWindow) return null
                inWindow = header.groupValues[1] == focused
                continue
            }
            if (!inWindow) continue
            // API 36 puts the names on their own `fl=` line; some builds keep
            // the numeric value inside the mAttrs line.
            ATTRS_FLAGS.find(line)?.let { return hasSecure(it.groupValues[1]) }
            val flags = FLAGS.find(line) ?: continue
            return hasSecure(flags.groupValues[1])
        }
        return null
    }

    /** SystemUI's keyguard view manager says the bouncer is up. */
    fun bouncerShowing(dump: String): Boolean = BOUNCER.containsMatchIn(dump)

    private fun hasSecure(value: String): Boolean {
        val text = value.trim()
        if (text.startsWith("0x")) {
            return ((text.removePrefix("0x").toLongOrNull(16) ?: 0L) and FLAG_SECURE.toLong()) != 0L
        }
        // API 36 prints names: `fl=NOT_FOCUSABLE ... SECURE ...`.
        return text.split(' ', '\t').any { it == "SECURE" }
    }

    private val DISPLAY = Regex("^\\s*Display: mDisplayId=(\\d+)")
    private val FOCUS = Regex("^\\s*mCurrentFocus=Window\\{([0-9a-f]+) ")
    private val WINDOW_HEADER = Regex("^\\s*Window #\\d+ Window\\{([0-9a-f]+) ")
    private val FLAGS = Regex("^\\s*fl=(.*)$")
    private val ATTRS_FLAGS = Regex("\\bfl=(0x[0-9a-fA-F]+)")
    private val BOUNCER = Regex("isBouncerShowing\\(\\):\\s*true")
}
