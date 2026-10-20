package dev.pocketdeck.app

/**
 * The camera foreground-service probe's request and its one result line, kept
 * free of Android types so JVM tests pin the parsing and formatting
 * (CamFgsProbeArgsTest). The service, its receiver and the camera work live in
 * CamFgsProbe.kt.
 */
internal data class CamFgsRequest(
    val stage: String,
    /** How long the repeating request runs, in seconds. */
    val seconds: Int,
    /** Save one decoded frame as evidence (the probe never stores more). */
    val saveFrame: Boolean,
) {
    companion object {
        const val DEFAULT_SECONDS = 5
        const val MAX_SECONDS = 60

        /** Stage labels are lowercase and hyphenated: they go into logcat greps. */
        private val STAGE = Regex("^[a-z0-9][a-z0-9-]{0,31}$")

        /** Null on a missing/odd label or an out-of-range duration. */
        fun parse(stage: String?, seconds: Int, saveFrame: Boolean): CamFgsRequest? {
            val name = stage?.trim().orEmpty()
            if (!STAGE.matches(name)) return null
            if (seconds !in 1..MAX_SECONDS) return null
            return CamFgsRequest(name, seconds, saveFrame)
        }
    }
}

/**
 * One run's answer: `stage=<name> ok=<bool> started_fg=<bool> opened=<bool>
 * frames=<n> error=<class:msg>`, logged once under the fixed `PdCamFgs` tag.
 * `ok` means the probe got frames; `error` still names a late eviction so P5
 * keeps its evidence.
 */
internal data class CamFgsResult(
    val stage: String,
    val ok: Boolean,
    val startedFg: Boolean,
    val opened: Boolean,
    val frames: Int,
    val error: String,
) {
    fun line(): String = buildString {
        append("stage=").append(value(stage))
        append(" ok=").append(ok)
        append(" started_fg=").append(startedFg)
        append(" opened=").append(opened)
        append(" frames=").append(frames)
        append(" error=").append(value(error))
    }

    companion object {
        /** No whitespace or newlines: the line stays one greppable record. */
        fun value(raw: String): String {
            val flat = raw.replace('\n', ' ').replace('\r', ' ').replace('\t', ' ').trim()
            val compact = flat.replace(Regex("\\s+"), "_")
            return compact.ifEmpty { "-" }
        }

        /** `SecurityException: Given calling package...` — the class plus its message. */
        fun describe(t: Throwable): String = "${t.javaClass.simpleName}:${t.message ?: "-"}"
    }
}
