package app.contigua.server

/**
 * Which URLs `link.open` may hand to `ACTION_VIEW` (docs/design/links.md).
 *
 * The Mac validates too, but this process is the shell UID: an `intent:` or
 * `content:` URL could start any component or read private files, so the phone
 * never trusts the Mac's check.
 */
object LinkPolicy {
    val ALLOWED_SCHEMES = setOf("http", "https", "geo", "tel", "mailto")
    const val MAX_BYTES = 8 * 1024

    /** The trimmed URL when it may be opened, else null. */
    fun validate(raw: String?): String? {
        val url = raw?.trim() ?: return null
        if (url.isEmpty() || url.toByteArray(Charsets.UTF_8).size > MAX_BYTES) return null
        if (url.any { it.isWhitespace() || it.isISOControl() }) return null
        val colon = url.indexOf(':')
        if (colon <= 0) return null
        val scheme = url.substring(0, colon)
        if (!scheme[0].isLetter() || !scheme.all { it.isLetterOrDigit() || it in "+-." }) return null
        val lower = scheme.lowercase()
        if (lower !in ALLOWED_SCHEMES) return null
        val rest = url.substring(colon + 1)
        if (lower == "http" || lower == "https") {
            if (!rest.startsWith("//")) return null
            val host = rest.substring(2).takeWhile { it != '/' && it != '?' && it != '#' }
                .substringAfterLast('@').substringBefore(':')
            if (host.isEmpty()) return null
        } else if (rest.isEmpty()) {
            return null
        }
        return url
    }
}
