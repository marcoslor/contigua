package dev.pocketdeck.drop

import android.os.ParcelFileDescriptor
import java.io.File

/**
 * The names the shell has staged for one pending SEND (docs/design/dragdrop.md).
 * The app can stat a shell-written file on shared storage but not open it
 * (boot 5), so the shell opens it and hands the app a file descriptor through
 * `IDeckService.openStaged`.
 *
 * A name is valid only while it is in the set: 60 s after staging, or as soon
 * as it is opened, and the file is unlinked then — the open descriptor keeps
 * the bytes alive for the reader.
 */
class ShareStaging(
    private val ttlMs: Long = TTL_MS,
    private val clock: () -> Long = System::currentTimeMillis,
    private val log: (String) -> Unit = {},
) {
    fun expect(name: String, file: File) = Unit

    fun open(name: String): ParcelFileDescriptor? = null

    /** Deletes every entry past its deadline. */
    fun sweep() = Unit

    /** Deletes every staged copy (the service is going away). */
    fun clear() = Unit

    companion object {
        const val TTL_MS = 60_000L
    }
}
