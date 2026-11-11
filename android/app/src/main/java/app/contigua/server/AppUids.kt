package app.contigua.server

import android.content.Context

/**
 * Package name → UID for the audio follow rules (AudioFollow.kt).
 *
 * The user service is UID 2000 (com.android.shell), which always sees every
 * package, so the PackageManager lookup is enough; `pm list packages -U` is
 * the fallback for images where that call is filtered.
 */
internal class AppUids(ctx: Context, private val log: (String) -> Unit) {

    private val pm = ctx.packageManager

    /** The UID of [pkg] at user 0, or null when the package cannot be read. */
    fun uidOf(pkg: String): Int? {
        if (pkg.isEmpty()) return null
        val direct = runCatching { pm.getPackageUid(pkg, 0) }.getOrNull()
        if (direct != null) return direct
        val listed = fromPm(pkg)
        if (listed == null) log("audio: no uid for $pkg")
        return listed
    }

    private fun fromPm(pkg: String): Int? = runCatching {
        val process = ProcessBuilder("pm", "list", "packages", "-U", pkg)
            .redirectErrorStream(true)
            .start()
        process.outputStream.close()
        val out = process.inputStream.bufferedReader().readText()
        process.waitFor()
        Regex("package:$pkg uid:(\\d+)").find(out)?.groupValues?.get(1)?.toInt()
    }.getOrNull()
}
