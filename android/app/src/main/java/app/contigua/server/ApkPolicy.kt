package app.contigua.server

/** Validation and `pm` output parsing for APK installs (docs/design/apk.md). */
object ApkPolicy {
    const val MAX_TOTAL_BYTES = 1L shl 30
    const val MAX_PARTS = 64
    private val NAME = Regex("[A-Za-z0-9._-]{1,100}")
    private val SHA = Regex("[0-9a-f]{64}")
    private val CREATED = Regex("""\[(\d+)]""")
    private val FAILURE = Regex("""Failure \[([A-Z0-9_]+)(?::\s*([^\]]*))?]""")

    data class Part(val name: String, val size: Long, val sha256: String)

    /** Part names go to pm as argv; only a plain file name ending in `.apk` is accepted. */
    fun validName(name: String?): Boolean =
        name != null && NAME.matches(name) && name.endsWith(".apk") && name != ".apk" && !name.startsWith(".") && !name.startsWith("-")

    /** The parts of an `apk.install`, or null when any is malformed or the total is too large. */
    fun parts(raw: Any?): List<Part>? {
        val list = raw as? List<*> ?: return null
        if (list.isEmpty() || list.size > MAX_PARTS) return null
        val parts = list.map { item ->
            val m = item as? Map<*, *> ?: return null
            val name = m["name"] as? String
            val size = (m["size"] as? Number)?.toLong() ?: return null
            val sha = (m["sha256"] as? String)?.lowercase() ?: return null
            if (!validName(name) || size <= 0 || !SHA.matches(sha)) return null
            Part(name!!, size, sha)
        }
        if (parts.map { it.name }.toSet().size != parts.size) return null
        return parts
    }

    fun total(parts: List<Part>): Long = parts.sumOf { it.size }

    fun sessionId(output: String): Int? =
        if (output.trim().startsWith("Success")) CREATED.find(output)?.groupValues?.get(1)?.toIntOrNull() else null

    fun isSuccess(output: String): Boolean = output.lineSequence().any { it.trim().startsWith("Success") }

    /** pm's failure code and detail; unknown text maps to `failed`. */
    fun failure(output: String): Pair<String, String> {
        val m = FAILURE.find(output) ?: return "failed" to output.trim().take(300)
        return m.groupValues[1] to m.groupValues[2].trim().take(300)
    }
}
