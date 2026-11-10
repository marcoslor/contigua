package dev.pocketdeck.app

import android.content.Context
import dev.pocketdeck.proto.Json
import java.io.File

/**
 * The phone-side record for windows that got no picture (WIN-66, ISS-10).
 *
 * The field log rotates in minutes, which is why the 2026-11-05 episode (one
 * window in 18, no picture for 22 s) left nothing behind. The app process owns
 * durable state, so the shell service hands each episode here over AIDL: one
 * JSON line per episode, newest [KEEP] kept, and an episode that ends updates
 * its own line instead of adding a second one.
 *
 * Ids, counts, durations and closed tokens only — the shell builds the line and
 * never puts an app name, label, title or text in it (privacy rule, AGENTS.md).
 */
internal object NoFrameStore {

    private const val FILE = "no-frame-episodes.jsonl"
    private const val KEEP = 20
    private val lock = Any()

    /** Records or updates one episode in the app's private files dir. */
    fun record(ctx: Context, episode: Int, json: String) {
        record(File(ctx.filesDir, FILE), episode, json)
    }

    /** Upserts by episode id and keeps the newest [KEEP] lines. */
    internal fun record(file: File, episode: Int, json: String) {
        synchronized(lock) {
            val lines = read(file).toMutableList()
            val existing = lines.indexOfFirst { episodeOf(it) == episode }
            if (existing >= 0) {
                lines[existing] = json
            } else {
                lines.add(json)
            }
            while (lines.size > KEEP) lines.removeAt(0)
            val temporary = File(file.parentFile, file.name + ".new")
            temporary.writeText(lines.joinToString(separator = "\n", postfix = "\n"))
            if (!temporary.renameTo(file)) {
                file.writeText(lines.joinToString(separator = "\n", postfix = "\n"))
                temporary.delete()
            }
        }
    }

    /** The stored lines, oldest first. A missing or unreadable file reads empty. */
    internal fun read(file: File): List<String> = runCatching {
        if (!file.exists()) emptyList() else file.readLines().filter { it.isNotBlank() }
    }.getOrDefault(emptyList())

    /** The `ep` of one stored line, or -1 when it is not an episode object. */
    internal fun episodeOf(line: String): Int =
        runCatching { Json.int(Json.parseObject(line)["ep"]) }.getOrNull() ?: -1
}
