package dev.pocketdeck.server

/**
 * PROTOCOL "Video rules": `window.opened` goes out before `window.content`,
 * VIDEO_CONFIG and frames. `window.opened` carries the display's task id
 * (WIN-32), which only exists once the launch has landed, so video that reaches
 * the session while the opener waits is held here: the last CONFIG (small) and
 * the newest keyframe (one access unit). Delta frames are dropped meanwhile —
 * the keyframe after the CONFIG is what a decoder needs to start.
 *
 * Two states per stream, one transition each: HELD (nothing has gone out yet)
 * and OPEN (everything goes straight through).
 */
internal class OpenGate(
    private val sendJson: (stream: Int, json: String) -> Unit,
    private val sendControl: (stream: Int, bytes: ByteArray) -> Unit,
    private val sendDelta: (stream: Int, ptsUs: Long, bytes: ByteArray) -> Unit,
) {

    private enum class State { HELD, OPEN }

    private class Stream(var state: State, var content: String? = null, var config: ByteArray? = null,
                         var keyframe: ByteArray? = null)

    private val streams = HashMap<Int, Stream>()

    /** A stream is about to open: hold its video until [announce]. */
    @Synchronized
    fun expect(stream: Int) {
        streams[stream] = Stream(State.HELD)
    }

    /** The stream's `window.content` and VIDEO_CONFIG (sent together, in this order). */
    @Synchronized
    fun config(stream: Int, content: String, config: ByteArray) {
        when (val s = streams[stream]) {
            null -> {
                sendJson(stream, content)
                sendControl(stream, config)
            }
            else -> when (s.state) {
                State.OPEN -> {
                    sendJson(stream, content)
                    sendControl(stream, config)
                }
                State.HELD -> {
                    s.content = content
                    s.config = config
                }
            }
        }
    }

    @Synchronized
    fun frame(stream: Int, ptsUs: Long, key: Boolean, bytes: ByteArray) {
        when (val s = streams[stream]) {
            null -> emit(stream, ptsUs, key, bytes)
            else -> when (s.state) {
                State.OPEN -> emit(stream, ptsUs, key, bytes)
                State.HELD -> if (key) s.keyframe = bytes
            }
        }
    }

    /**
     * `window.opened` goes out, then whatever arrived before it: the content and
     * CONFIG with the keyframe that followed. Runs both inside one lock so no
     * config can slip in front of the opener.
     */
    @Synchronized
    fun announce(stream: Int, opened: () -> Unit) {
        // A forgotten stream (closed while its opener waited) says nothing.
        val s = streams[stream] ?: return
        opened()
        if (s.state == State.OPEN) return
        s.state = State.OPEN
        s.content?.let { sendJson(stream, it) }
        s.config?.let { sendControl(stream, it) }
        s.keyframe?.let { sendControl(stream, it) }
        s.content = null
        s.config = null
        s.keyframe = null
    }

    /** The stream closed: nothing held for it may go out (a later stream reuses the id). */
    @Synchronized
    fun forget(stream: Int) {
        streams.remove(stream)
    }

    private fun emit(stream: Int, ptsUs: Long, key: Boolean, bytes: ByteArray) {
        if (key) sendControl(stream, bytes) else sendDelta(stream, ptsUs, bytes)
    }
}
