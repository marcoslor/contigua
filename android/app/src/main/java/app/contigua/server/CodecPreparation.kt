package app.contigua.server

/**
 * Builds one stream encoder from the WIN-59 decision. HEVC is tried when it is
 * chosen; a create, configure or start failure is remembered for the process
 * and the same stream is rebuilt once with H.264, so a failing HEVC encoder
 * never loses the window. The failure lines stay closed: `codec=hevc
 * unsupported: configure` for that fallback, the old size line for H.264.
 */
internal object CodecPreparation {

    data class Ready<T, B>(val encoder: T, val kind: VideoCodec, val built: B)

    fun <T : Any, B> prepare(
        strategy: StreamStrategy,
        macCodecs: Set<VideoCodec>,
        size: IntSize,
        state: HevcCodecState,
        label: String,
        create: (VideoCodec) -> T,
        build: (T, VideoCodec) -> B,
        release: (T) -> Unit,
        log: (String) -> Unit,
        stateLog: (String) -> Unit = log,
    ): Ready<T, B>? {
        // The probe runs only when this stream could use HEVC: a forced AVC or
        // a Mac without it never touches an HEVC encoder.
        val encoder = if (strategy.codec == VideoCodec.Hevc && VideoCodec.Hevc in macCodecs) {
            when (val found = state.resolve(stateLog)) {
                is HevcCodecState.State.Available ->
                    CodecChoice.Encoder.Available(found.supports)
                is HevcCodecState.State.Unavailable ->
                    CodecChoice.Encoder.Unavailable(found.reason)
                HevcCodecState.State.Unknown -> CodecChoice.Encoder.Unavailable("encoder")
            }
        } else {
            CodecChoice.Encoder.Unavailable("encoder")
        }
        val choice = CodecChoice.choose(strategy.codec, macCodecs, encoder, size)
        choice.fallbackLine?.let(log)

        val first = attempt(choice.codec, create, build, release)
        first.built?.let { return Ready(it.encoder, choice.codec, it.built) }
        if (choice.codec != VideoCodec.Hevc) {
            log(failureLine(choice.codec, first, label))
            return null
        }

        // The probe said HEVC is possible, but this encoder refused it: retire
        // it for the process and rebuild the same stream with H.264 once.
        state.configureFailed(stateLog)
        log("codec=hevc unsupported: configure")
        val retry = attempt(VideoCodec.Avc, create, build, release)
        retry.built?.let { return Ready(it.encoder, VideoCodec.Avc, it.built) }
        log(failureLine(VideoCodec.Avc, retry, label))
        return null
    }

    private class Built<T, B>(val encoder: T, val built: B)

    private class Attempt<T, B>(
        val built: Built<T, B>?,
        val missing: Boolean,
        val error: Throwable?,
    )

    private fun <T : Any, B> attempt(
        kind: VideoCodec,
        create: (VideoCodec) -> T,
        build: (T, VideoCodec) -> B,
        release: (T) -> Unit,
    ): Attempt<T, B> {
        val encoder = try {
            create(kind)
        } catch (e: Throwable) {
            return Attempt(null, missing = true, error = e)
        }
        return try {
            Attempt(Built(encoder, build(encoder, kind)), missing = false, error = null)
        } catch (e: Throwable) {
            runCatching { release(encoder) }
            Attempt(null, missing = false, error = e)
        }
    }

    private fun failureLine(kind: VideoCodec, attempt: Attempt<*, *>, label: String): String =
        if (attempt.missing) {
            "no ${kind.token} encoder: ${attempt.error?.message}"
        } else {
            "encoder for $label failed: ${attempt.error?.message}"
        }
}
