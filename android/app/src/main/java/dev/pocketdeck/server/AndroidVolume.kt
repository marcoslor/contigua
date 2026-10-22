package dev.pocketdeck.server

import android.content.Context
import android.media.AudioManager
import java.util.concurrent.TimeUnit

/**
 * STREAM_MUSIC at shell UID (docs/PROTOCOL.md "Volume").
 *
 * Reading and writing go through AudioManager first. The shell process is UID
 * 2000, which is how `adb shell` reaches the volume service, and
 * `cmd media_session volume` is the same command the emulator rehearsal uses;
 * it is the fallback when this build's AudioManager refuses the call.
 *
 * This platform's public API has no volume callback, so [VolumeControl]'s poll
 * is the only source for a change made on the phone: late by at most one
 * interval, never lost.
 */
internal class AndroidVolumeSettings(
    base: Context,
    private val log: (String) -> Unit,
) : VolumeSettings {

    private val audio: AudioManager? = runCatching {
        base.getSystemService(Context.AUDIO_SERVICE) as? AudioManager
    }.getOrNull()

    override fun read(): Pair<Int, Int>? {
        val manager = audio ?: return readByCommand()
        return runCatching {
            val max = manager.getStreamMaxVolume(AudioManager.STREAM_MUSIC)
            val level = manager.getStreamVolume(AudioManager.STREAM_MUSIC)
            if (max <= 0) null else level to max
        }.getOrNull() ?: readByCommand()
    }

    override fun set(level: Int): Boolean {
        val manager = audio
        if (manager != null) {
            val ok = runCatching {
                manager.setStreamVolume(AudioManager.STREAM_MUSIC, level, 0)
                true
            }.getOrDefault(false)
            if (ok) return true
        }
        return runCatching {
            run("cmd", "media_session", "volume", "--stream", "3", "--set", level.toString()) != null
        }.getOrDefault(false)
    }

    override fun listen(onChange: () -> Unit): AutoCloseable? = null

    /** `cmd media_session volume --stream 3 --get` prints "volume is N in range [0..M]". */
    private fun readByCommand(): Pair<Int, Int>? = runCatching {
        val out = run("cmd", "media_session", "volume", "--stream", "3", "--get") ?: return null
        val numbers = Regex("-?\\d+").findAll(out).map { it.value.toInt() }.toList()
        if (numbers.size < 2) null else numbers[0] to numbers[1]
    }.getOrNull()

    /** Runs a command at this process's UID; null on a non-zero exit or timeout. */
    private fun run(vararg command: String): String? = runCatching {
        val process = ProcessBuilder(*command).redirectErrorStream(true).start()
        process.outputStream.close()
        val out = process.inputStream.bufferedReader().readText().trim()
        val finished = process.waitFor(5, TimeUnit.SECONDS)
        if (!finished) process.destroy()
        if (!finished || process.exitValue() != 0) null else out
    }.getOrNull()
}
