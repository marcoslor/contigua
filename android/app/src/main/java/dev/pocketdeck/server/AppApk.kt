package dev.pocketdeck.server

import android.content.Context
import java.io.File

/** The package this server runs as. */
internal const val APP_PACKAGE = "dev.pocketdeck"

/**
 * The APK this process runs from; a second `app_process` starts from the same
 * file. The package manager is the normal answer, and the code source covers a
 * process whose package is not visible (the shell context names
 * `com.android.shell`, so the package is asked for by our own name).
 */
internal fun appApkPath(ctx: Context?): String? {
    val fromPackage = runCatching {
        ctx?.packageManager?.getApplicationInfo(APP_PACKAGE, 0)?.sourceDir
    }.getOrNull()
    if (fromPackage != null && File(fromPackage).isFile) return fromPackage
    return runCatching {
        DeckService::class.java.protectionDomain?.codeSource?.location?.path
    }.getOrNull()?.takeIf { File(it).isFile }
}
