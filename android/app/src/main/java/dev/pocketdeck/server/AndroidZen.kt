package dev.pocketdeck.server

import android.content.Context
import android.database.ContentObserver
import android.net.Uri
import android.os.Handler
import android.os.HandlerThread
import android.provider.Settings
import java.util.concurrent.TimeUnit

/**
 * `Settings.Global.zen_mode` (docs/design/focus.md). The shell process reads
 * the setting directly; where a build refuses that, `settings get` asks the
 * same provider. A ContentObserver is registered on the same key so a mode the
 * person changes on the phone reaches the session without polling.
 */
internal class AndroidZenSettings(
    private val ctx: Context,
    private val log: (String) -> Unit,
) : ZenSettings {

    override fun read(): DndMode? = runCatching {
        DndMode.fromZen(Settings.Global.getInt(ctx.contentResolver, ZEN_MODE))
    }.getOrElse {
        readByCommand()
    }

    private fun readByCommand(): DndMode? = runCatching {
        val process = ProcessBuilder("settings", "get", "global", ZEN_MODE)
            .redirectErrorStream(true)
            .start()
        process.outputStream.close()
        val out = process.inputStream.bufferedReader().readText().trim()
        if (!process.waitFor(5, TimeUnit.SECONDS)) {
            process.destroy()
            return@runCatching null
        }
        if (process.exitValue() != 0) return@runCatching null
        DndMode.fromZen(out.toIntOrNull() ?: return@runCatching null)
    }.getOrNull()

    override fun listen(onChange: (DndMode?) -> Unit): AutoCloseable? {
        val thread = runCatching { HandlerThread("pocketdeck-zen").also { it.start() } }.getOrNull() ?: return null
        val observer = object : ContentObserver(Handler(thread.looper)) {
            override fun onChange(selfChange: Boolean, uri: Uri?) {
                onChange(read())
            }
        }
        return runCatching {
            ctx.contentResolver.registerContentObserver(Settings.Global.getUriFor(ZEN_MODE), false, observer)
            AutoCloseable {
                runCatching { ctx.contentResolver.unregisterContentObserver(observer) }
                thread.quitSafely()
            }
        }.getOrElse {
            thread.quitSafely()
            log("dnd: no zen observer (${it.javaClass.simpleName}); polling")
            null
        }
    }

    private companion object {
        const val ZEN_MODE = "zen_mode"
    }
}

/**
 * `cmd notification set_dnd <mode>` at shell UID (the brief's one write path).
 * The shell may call NotificationManagerService; a non-zero exit is a refusal.
 */
internal class ShellZenSetter(private val log: (String) -> Unit) : ZenSetter {

    override fun set(mode: DndMode): Boolean = runCatching {
        val process = ProcessBuilder("cmd", "notification", "set_dnd", mode.wire)
            .redirectErrorStream(true)
            .start()
        process.outputStream.close()
        val out = process.inputStream.bufferedReader().readText().trim()
        val finished = process.waitFor(5, TimeUnit.SECONDS)
        if (!finished) process.destroy()
        val ok = finished && process.exitValue() == 0
        // Mode names only: no other state is logged.
        log("dnd: cmd notification set_dnd ${mode.wire} -> ${if (ok) "ok" else "failed"}${if (out.isEmpty()) "" else " (reported)"}")
        ok
    }.getOrElse {
        log("dnd: cmd notification set_dnd ${mode.wire} -> error")
        false
    }
}
