package app.contigua.server

import java.security.MessageDigest

/**
 * The `clip.set` rules from docs/PROTOCOL.md "Clipboard sync", for both
 * directions: the size limit and the hash of the text last sent or received.
 * Remembering that hash is what keeps received text from being sent back.
 */
internal class ClipSync {
    private val lock = Any()
    private var synced: ByteArray? = null

    /** Whether a local change to [text] goes out. Records the text when it does. */
    fun shouldSend(text: String): Boolean {
        val bytes = text.toByteArray(Charsets.UTF_8)
        if (bytes.isEmpty() || bytes.size > MAX_BYTES) return false
        val hash = MessageDigest.getInstance("SHA-256").digest(bytes)
        synchronized(lock) {
            if (synced?.contentEquals(hash) == true) return false
            synced = hash
            return true
        }
    }

    /**
     * Whether a received [text] is written to the clipboard. Records it first,
     * so the change the write causes is not sent back.
     */
    fun accept(text: String): Boolean {
        val bytes = text.toByteArray(Charsets.UTF_8)
        if (bytes.isEmpty() || bytes.size > MAX_BYTES) return false
        val hash = MessageDigest.getInstance("SHA-256").digest(bytes)
        synchronized(lock) { synced = hash }
        return true
    }

    companion object {
        const val MAX_BYTES = 1_048_576
    }
}

/**
 * The phone's clipboard gate (SHARE-13): the Mac's `clip.enable` is the only
 * switch, the same shape as the notification gate. The phone starts Off, so
 * nothing leaves it until the Mac's own setting says otherwise; off also stops
 * what the Mac sends from being written here.
 */
internal enum class ClipGate { OFF, ON }

internal sealed interface ClipGateEvent {
    /** The Mac's setting arrived over the session. */
    data class MacSaid(val on: Boolean) : ClipGateEvent
}

/** The one transition: the Mac's word is the state. */
internal fun clipGate(state: ClipGate, event: ClipGateEvent): ClipGate = when (event) {
    is ClipGateEvent.MacSaid -> if (event.on) ClipGate.ON else ClipGate.OFF
}
