package dev.pocketdeck.server

import android.content.Context

/**
 * [PackageShell] over the `pm` command, run as an argv array (never `sh -c`) at
 * shell UID. `install-write ... -` reads the part from stdin, so the APK is
 * never stored by us anywhere on the phone.
 */
internal class ShellPackages(private val ctx: Context, private val log: (String) -> Unit) : PackageShell {

    override fun create(totalBytes: Long): String = run("pm", "install-create", "-S", totalBytes.toString())

    override fun write(session: Int, name: String, size: Long): PartWriter {
        val process = ProcessBuilder("pm", "install-write", "-S", size.toString(), session.toString(), name, "-")
            .redirectErrorStream(true)
            .start()
        val stdin = process.outputStream
        return object : PartWriter {
            override fun write(bytes: ByteArray, offset: Int, length: Int) = stdin.write(bytes, offset, length)

            override fun finish(): String {
                stdin.close()
                val out = process.inputStream.bufferedReader().readText()
                process.waitFor()
                return out
            }

            override fun abort() {
                runCatching { stdin.close() }
                process.destroy()
            }
        }
    }

    override fun commit(session: Int): String = run("pm", "install-commit", session.toString())

    override fun abandon(session: Int) {
        run("pm", "install-abandon", session.toString())
    }

    override fun newestSince(sinceMs: Long): InstalledApp? {
        val pm = ctx.packageManager
        @Suppress("DEPRECATION")
        val info = pm.getInstalledPackages(0)
            .filter { it.lastUpdateTime >= sinceMs }
            .maxByOrNull { it.lastUpdateTime } ?: return null
        val label = info.applicationInfo?.loadLabel(pm)?.toString() ?: info.packageName
        return InstalledApp(info.packageName, label, info.versionName ?: "")
    }

    private fun run(vararg argv: String): String {
        val process = ProcessBuilder(*argv).redirectErrorStream(true).start()
        process.outputStream.close()
        val out = process.inputStream.bufferedReader().readText()
        process.waitFor()
        log("${argv.take(2).joinToString(" ")}: ${out.trim().take(200)}")
        return out
    }
}
