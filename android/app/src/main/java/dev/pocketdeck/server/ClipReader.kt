package dev.pocketdeck.server

/**
 * Who may read the primary clip for this process (ISS-27, SHARE-19).
 *
 * AOSP's `getPrimaryClip` checks that the caller's UID owns the package it
 * names; at UID 2000 the process owns `com.android.shell`, while root (UID 0)
 * owns no package at all and every read clears the clip. [Direct] is the shell
 * user, [Helper] a reader already running as the shell user, and [Off] no read
 * at all with the reason the log names.
 */
internal sealed interface ClipReader {
    data object Direct : ClipReader
    data object Helper : ClipReader
    data class Off(val reason: String) : ClipReader
}

/** The real shell user (Shizuku's non-root mode). */
internal const val SHELL_UID = 2000

/**
 * The one reader policy. Pure: the caller's UID and whether a helper is ready
 * decide everything, and [ClipReader.Off] never falls back to a direct read.
 */
internal fun clipReader(uid: Int, helperAvailable: Boolean): ClipReader = when {
    uid == SHELL_UID -> ClipReader.Direct
    uid == 0 && helperAvailable -> ClipReader.Helper
    uid == 0 -> ClipReader.Off("uid 0, no helper")
    else -> ClipReader.Off("uid $uid")
}
