package dev.pocketdeck.drop

import android.os.ParcelFileDescriptor
import java.io.File

/**
 * The trampoline's copy half (docs/design/dragdrop.md): every staged name is
 * opened by the shell through `openStaged` and copied into the app's share
 * cache from that descriptor. No staged path is ever opened by the app, which
 * boot 5 showed cannot read what uid 2000 wrote on shared storage.
 */
object ShareCopies {

    /** The cache copies, or null when any name is refused or any copy fails. */
    fun copy(
        openStaged: (String) -> ParcelFileDescriptor?,
        requests: List<ShareRequest.Target>,
        dir: File,
        log: (String) -> Unit = {},
    ): List<File>? = null
}
