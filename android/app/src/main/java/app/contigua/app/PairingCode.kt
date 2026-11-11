package app.contigua.app

/**
 * Renders a six-digit pairing code the way docs/DESIGN.md §2 specifies: grouped
 * 3+3, e.g. `482913` -> `482 913`. Anything else is returned unchanged.
 */
fun formatPairingCode(code: String): String {
    val digits = code.filter { it.isDigit() }
    if (digits.length != 6) return code
    return digits.substring(0, 3) + " " + digits.substring(3)
}
