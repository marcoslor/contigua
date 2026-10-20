package dev.pocketdeck.server

/**
 * The camera probe's command line and its one result line, kept free of
 * Android types so the JVM tests can pin the parsing and the formatting
 * (CameraProbeArgsTest). The stages themselves live in CameraProbe.
 */
internal data class ProbeStage(
    val name: String,
    /** How long the stage captures or waits, in seconds. */
    val seconds: Int,
    /** Camera id, or null for the phone's first camera. */
    val camera: String?,
    /** Where `evict` writes its "capture is running" marker; null writes none. */
    val ready: String?,
) {
    companion object {
        val NAMES = listOf("list", "open", "locked", "feed", "evict")

        const val DEFAULT_SECONDS = 5
        const val MAX_SECONDS = 120

        /** Parses `[stage] [--seconds N] [--camera ID] [--ready PATH]`; null on anything unknown. */
        fun parse(args: Array<String>): ProbeStage? {
            if (args.isEmpty()) return null
            val name = args[0]
            if (name !in NAMES) return null
            var seconds = DEFAULT_SECONDS
            var camera: String? = null
            var ready: String? = null
            var i = 1
            while (i < args.size) {
                val flag = args[i]
                val value = args.getOrNull(i + 1) ?: return null
                when (flag) {
                    "--seconds" -> {
                        val parsed = value.toIntOrNull() ?: return null
                        if (parsed !in 1..MAX_SECONDS) return null
                        seconds = parsed
                    }
                    "--camera" -> {
                        if (value.isBlank()) return null
                        camera = value
                    }
                    "--ready" -> {
                        if (value.isBlank()) return null
                        ready = value
                    }
                    else -> return null
                }
                i += 2
            }
            return ProbeStage(name, seconds, camera, ready)
        }
    }
}

/** One stage's answer: a single `cam: result ...` line and the process exit code. */
internal data class ProbeResult(
    val stage: String,
    val ok: Boolean,
    val fields: List<Pair<String, String>> = emptyList(),
) {
    /** `cam: result stage=feed ok=true camFps=29.9 ...`, one line, no whitespace in values. */
    fun line(): String = buildString {
        append("cam: result stage=").append(stage).append(" ok=").append(ok)
        for ((key, value) in fields) {
            append(' ').append(key).append('=').append(resultValue(value))
        }
    }

    companion object {
        /** A result value never carries a space or a newline: the line stays greppable. */
        fun resultValue(raw: String): String {
            val flat = raw.replace('\n', ' ').replace('\r', ' ').replace('\t', ' ').trim()
            val compact = flat.replace(Regex("\\s+"), "_")
            return compact.ifEmpty { "-" }
        }
    }
}

/**
 * Writes named fields on an object by reflection. The probe uses it to give the
 * framework base context the shell package (mPackageName, mOpPackageName,
 * mAttributionSource); the test drives it with a fake that has those fields,
 * so the rewrite is pinned on the JVM instead of on an emulator boot.
 */
internal object ReflectionFields {
    /** @return the names it could not set (missing field or refused write). */
    fun write(target: Any, values: Map<String, Any?>): List<String> {
        val failed = ArrayList<String>()
        for ((name, value) in values) {
            val field = runCatching { target.javaClass.getDeclaredField(name) }.getOrNull()
            if (field == null) {
                failed += name
                continue
            }
            runCatching {
                field.isAccessible = true
                field.set(target, value)
            }.onFailure { failed += name }
        }
        return failed
    }
}
