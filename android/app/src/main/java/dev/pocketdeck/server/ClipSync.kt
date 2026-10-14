package dev.pocketdeck.server

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
