package dev.pocketdeck.server

import android.content.Context
import android.database.ContentObserver
import android.net.Uri
import android.os.Handler
import android.os.HandlerThread
import android.provider.Settings
import java.util.concurrent.TimeUnit

/**
 * `Settings.Global.mode_ringer` (docs/design/controls.md). The spike found the
 * setting tracks `cmd audio set-ringer-mode` exactly at shell UID (0 silent,
 * 1 vibrate, 2 normal); the AudioService's own `cmd audio get-ringer-mode`
 * prints nothing on API 36, so the setting is the read path. A ContentObserver
 * on the same key carries a person's change to the session without polling.
 */
internal class AndroidRingerSettings(
    private val ctx: Context,
    private val log: (String) -> Unit,
) : RingerSettings {

    override fun read(): RingerMode? = runCatching {
        RingerMode.fromAndroid(Settings.Global.getInt(ctx.contentResolver, MODE_RINGER))
    }.getOrElse {
        readByCommand()
    }

    private fun readByCommand(): RingerMode? = runCatching {
        val process = ProcessBuilder("settings", "get", "global", MODE_RINGER)
            .redirectErrorStream(true)
            .start()
        process.outputStream.close()
        val out = process.inputStream.bufferedReader().readText().trim()
        if (!process.waitFor(5, TimeUnit.SECONDS)) {
            process.destroy()
            return@runCatching null
        }
        if (process.exitValue() != 0) return@runCatching null
        RingerMode.fromAndroid(out.toIntOrNull() ?: return@runCatching null)
    }.getOrNull()

    override fun listen(onChange: (RingerMode?) -> Unit): AutoCloseable? {
        val thread = runCatching { HandlerThread("pocketdeck-ringer").also { it.start() } }.getOrNull() ?: return null
        val observer = object : ContentObserver(Handler(thread.looper)) {
            override fun onChange(selfChange: Boolean, uri: Uri?) {
                onChange(read())
            }
        }
        return runCatching {
            ctx.contentResolver.registerContentObserver(Settings.Global.getUriFor(MODE_RINGER), false, observer)
            AutoCloseable {
                runCatching { ctx.contentResolver.unregisterContentObserver(observer) }
                thread.quitSafely()
            }
        }.getOrElse {
            thread.quitSafely()
            log("ringer: no mode_ringer observer (${it.javaClass.simpleName}); polling")
            null
        }
    }

    private companion object {
        const val MODE_RINGER = "mode_ringer"
    }
}

/**
 * `cmd audio set-ringer-mode <NORMAL|VIBRATE|SILENT>` at shell UID. The spike
 * verified it writes both the AudioService mode and `mode_ringer`; a non-zero
 * exit is a refusal. No volume level is ever sent.
 */
internal class ShellRingerSetter(private val log: (String) -> Unit) : RingerSetter {

    override fun set(mode: RingerMode): Boolean = runCatching {
        val process = ProcessBuilder("cmd", "audio", "set-ringer-mode", mode.name)
            .redirectErrorStream(true)
            .start()
        process.outputStream.close()
        val out = process.inputStream.bufferedReader().readText().trim()
        val finished = process.waitFor(5, TimeUnit.SECONDS)
        if (!finished) process.destroy()
        val ok = finished && process.exitValue() == 0
        // Mode names only: no other state is logged.
        log("ringer: cmd audio set-ringer-mode ${mode.name} -> ${if (ok) "ok" else "failed"}${if (out.isEmpty()) "" else " (reported)"}")
        ok
    }.getOrElse {
        log("ringer: cmd audio set-ringer-mode ${mode.name} -> error")
        false
    }
}
