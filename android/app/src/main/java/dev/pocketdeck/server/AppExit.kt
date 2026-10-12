package dev.pocketdeck.server

/**
 * Decides which window streams to close because the app they were showing left
 * its virtual display (the user backed out of it). Pure so it is JVM-tested.
 *
 * Only a stream that *had* a task in the previous snapshot and has none now is
 * closed. A stream that never showed a task is left alone: the launch may still
 * be starting, and a genuinely failed launch is reported separately as
 * `launch_failed`. Phone-mode streams are filtered out by the caller.
 */
internal object AppExit {

    fun exited(previous: Map<Int, Boolean>, current: Map<Int, Boolean>): List<Int> =
        previous.entries.filter { (stream, had) -> had && current[stream] != true }
            .map { it.key }
}
