package dev.pocketdeck.server

import android.content.Context
import android.os.Process as AndroidProcess
import java.io.BufferedInputStream
import java.io.BufferedOutputStream
import java.io.DataInputStream
import java.io.DataOutputStream
import java.io.EOFException
import java.io.FileDescriptor
import java.io.FileInputStream
import java.io.FileOutputStream
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.util.concurrent.Executors
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

/**
 * The lifecycle of the clipboard helper (ISS-27), one explicit machine:
 * Off → Starting → Ready → Failed(reason), with a bounded restart on a death.
 * [ClipHelperState.Starting] is the first start, which tries each spawn form
 * until one answers ready; [ClipHelperState.Restarting] is a bounded retry of
 * the form that worked. The transition is pure; the actions it returns are run
 * by [ClipHelper].
 */
internal sealed interface ClipHelperState {
    data object Off : ClipHelperState
    data class Starting(val attempt: Int, val form: Int) : ClipHelperState
    data class Restarting(val attempt: Int, val form: Int) : ClipHelperState
    data class Ready(val attempt: Int, val form: Int) : ClipHelperState
    data class Failed(val reason: String) : ClipHelperState
}

internal sealed interface ClipHelperEvent {
    /** The clipboard sync started. */
    data object Start : ClipHelperEvent
    /** The spawned process answered ready; a stale form or attempt is ignored. */
    data class Started(val attempt: Int, val form: Int) : ClipHelperEvent
    /** The process died or could not be started. */
    data class Died(val attempt: Int, val form: Int, val reason: String) : ClipHelperEvent
    /** The clipboard sync ended. */
    data object Stop : ClipHelperEvent
}

internal sealed interface ClipHelperAction {
    data class Spawn(val attempt: Int, val form: Int) : ClipHelperAction
    data class SpawnAfter(val attempt: Int, val form: Int, val delayMs: Long) : ClipHelperAction
    data object Kill : ClipHelperAction
}

internal data class ClipHelperStep(val state: ClipHelperState, val actions: List<ClipHelperAction>)

/** The first start plus at most three restarts. */
internal const val CLIP_HELPER_MAX_ATTEMPTS = 4

/**
 * The two ways to start the helper, in order: a root manager's `su` takes
 * `-c`, AOSP's userdebug `su` takes `sh -c` (it has no `-c` of its own). The
 * first form is unchanged, so a device where it works behaves exactly as
 * before; the second is only tried when the first dies before ready.
 */
internal const val CLIP_HELPER_SPAWN_FORMS = 2

internal fun clipHelperSpawnForms(cmd: String): List<List<String>> = listOf(
    listOf("su", "2000", "-c", cmd),
    listOf("su", "2000", "sh", "-c", cmd),
)

/** One machine step; every state/event pair is exhaustive here. */
internal fun clipHelperStep(state: ClipHelperState, event: ClipHelperEvent): ClipHelperStep = when (state) {
    ClipHelperState.Off -> when (event) {
        ClipHelperEvent.Start -> ClipHelperStep(
            ClipHelperState.Starting(1, 1),
            listOf(ClipHelperAction.Spawn(1, 1)),
        )
        ClipHelperEvent.Stop -> ClipHelperStep(state, emptyList())
        is ClipHelperEvent.Started, is ClipHelperEvent.Died -> ClipHelperStep(state, emptyList())
    }
    is ClipHelperState.Starting -> when (event) {
        is ClipHelperEvent.Started ->
            if (event.attempt == state.attempt && event.form == state.form) {
                ClipHelperStep(ClipHelperState.Ready(state.attempt, state.form), emptyList())
            } else {
                ClipHelperStep(state, emptyList())
            }
        is ClipHelperEvent.Died ->
            if (event.attempt == state.attempt && event.form == state.form) {
                clipHelperFormDied(state)
            } else {
                ClipHelperStep(state, emptyList())
            }
        ClipHelperEvent.Start -> ClipHelperStep(state, emptyList())
        ClipHelperEvent.Stop -> ClipHelperStep(ClipHelperState.Off, listOf(ClipHelperAction.Kill))
    }
    is ClipHelperState.Restarting -> when (event) {
        is ClipHelperEvent.Started ->
            if (event.attempt == state.attempt && event.form == state.form) {
                ClipHelperStep(ClipHelperState.Ready(state.attempt, state.form), emptyList())
            } else {
                ClipHelperStep(state, emptyList())
            }
        is ClipHelperEvent.Died ->
            if (event.attempt == state.attempt && event.form == state.form) {
                clipHelperRestart(state.attempt, state.form, event.reason)
            } else {
                ClipHelperStep(state, emptyList())
            }
        ClipHelperEvent.Start -> ClipHelperStep(state, emptyList())
        ClipHelperEvent.Stop -> ClipHelperStep(ClipHelperState.Off, listOf(ClipHelperAction.Kill))
    }
    is ClipHelperState.Ready -> when (event) {
        is ClipHelperEvent.Died ->
            if (event.attempt == state.attempt && event.form == state.form) {
                clipHelperRestart(state.attempt, state.form, event.reason)
            } else {
                ClipHelperStep(state, emptyList())
            }
        ClipHelperEvent.Stop -> ClipHelperStep(ClipHelperState.Off, listOf(ClipHelperAction.Kill))
        ClipHelperEvent.Start -> ClipHelperStep(state, emptyList())
        is ClipHelperEvent.Started -> ClipHelperStep(state, emptyList())
    }
    is ClipHelperState.Failed -> when (event) {
        ClipHelperEvent.Start -> ClipHelperStep(
            ClipHelperState.Starting(1, 1),
            listOf(ClipHelperAction.Spawn(1, 1)),
        )
        ClipHelperEvent.Stop -> ClipHelperStep(ClipHelperState.Off, emptyList())
        is ClipHelperEvent.Started, is ClipHelperEvent.Died -> ClipHelperStep(state, emptyList())
    }
}

/** A death before ready moves to the next form, and only the last one fails. */
private fun clipHelperFormDied(state: ClipHelperState.Starting): ClipHelperStep =
    if (state.form < CLIP_HELPER_SPAWN_FORMS) {
        val form = state.form + 1
        ClipHelperStep(
            ClipHelperState.Starting(state.attempt, form),
            listOf(ClipHelperAction.Spawn(state.attempt, form)),
        )
    } else {
        ClipHelperStep(ClipHelperState.Failed("no su form"), emptyList())
    }

/** A death after ready keeps its form and spends one of the three restarts. */
private fun clipHelperRestart(attempt: Int, form: Int, reason: String): ClipHelperStep =
    if (attempt < CLIP_HELPER_MAX_ATTEMPTS) {
        val next = attempt + 1
        ClipHelperStep(
            ClipHelperState.Restarting(next, form),
            listOf(ClipHelperAction.SpawnAfter(next, form, clipHelperBackoffMs(next))),
        )
    } else {
        ClipHelperStep(ClipHelperState.Failed(reason), emptyList())
    }

/** 500 ms, 1 s, 2 s: a short backoff, capped so a crash loop stays cheap. */
internal fun clipHelperBackoffMs(attempt: Int): Long =
    (500L shl (attempt - 2).coerceAtLeast(0)).coerceAtMost(2_000L)

/** The helper's stdin/stdout frames: a length, a type, a request id, bytes. */
internal data class ClipHelperFrame(val type: Int, val id: Int, val payload: ByteArray)

internal object ClipHelperFrames {
    const val TEXT = 1
    const val IMAGE = 2
    const val TEXT_REPLY = 3
    const val IMAGE_REPLY = 4
    const val CHANGED = 5
    const val READY = 6

    /** The image cap plus room for the MIME type and the frame header. */
    const val MAX_FRAME_BYTES = ClipImagePolicy.MAX_BYTES + 64 * 1024
    private val EMPTY = ByteArray(0)

    /** Binary-safe: the payload is written verbatim, images included. */
    fun write(out: OutputStream, type: Int, id: Int, payload: ByteArray = EMPTY) {
        val data = DataOutputStream(out)
        synchronized(out) {
            data.writeInt(payload.size + 5)
            data.writeByte(type)
            data.writeInt(id)
            data.write(payload)
            data.flush()
        }
    }

    /** Null on EOF or a broken/corrupt frame; callers treat that as a dead helper. */
    fun read(input: InputStream): ClipHelperFrame? {
        val data = DataInputStream(input)
        val length = try {
            data.readInt()
        } catch (_: EOFException) {
            return null
        } catch (_: IOException) {
            return null
        }
        if (length < 5 || length > MAX_FRAME_BYTES) return null
        val type = try {
            data.readUnsignedByte()
        } catch (_: IOException) {
            return null
        }
        val id = try {
            data.readInt()
        } catch (_: IOException) {
            return null
        }
        val payload = ByteArray(length - 5)
        return try {
            data.readFully(payload)
            ClipHelperFrame(type, id, payload)
        } catch (_: IOException) {
            null
        }
    }
}

/** [flags: present|sensitive][UTF-8 text]; never a length prefix the reader could misread. */
internal fun clipTextPayload(clip: ClipText?): ByteArray {
    if (clip == null) return byteArrayOf(0)
    val bytes = clip.text.toByteArray(Charsets.UTF_8)
    val flags = 1 or (if (clip.sensitive) 2 else 0)
    return byteArrayOf(flags.toByte()) + bytes
}

internal fun parseClipTextReply(payload: ByteArray): ClipText? {
    if (payload.isEmpty() || payload[0].toInt() and 1 == 0) return null
    val text = String(payload, 1, payload.size - 1, Charsets.UTF_8)
    return ClipText(text, sensitive = payload[0].toInt() and 2 != 0)
}

/** [flags: present][u16 mime length][mime][bytes]; the image cap is the existing one. */
internal fun clipImagePayload(image: ClipImage?): ByteArray {
    if (image == null || image.bytes.isEmpty() || image.bytes.size > ClipImagePolicy.MAX_BYTES) {
        return byteArrayOf(0)
    }
    val mime = image.mime.toByteArray(Charsets.UTF_8)
    val out = ByteArray(3 + mime.size + image.bytes.size)
    out[0] = 1
    out[1] = (mime.size shr 8).toByte()
    out[2] = mime.size.toByte()
    mime.copyInto(out, 3)
    image.bytes.copyInto(out, 3 + mime.size)
    return out
}

internal fun parseClipImageReply(payload: ByteArray): ClipImage? {
    if (payload.size < 4 || payload[0].toInt() and 1 == 0) return null
    val mimeLength = ((payload[1].toInt() and 0xFF) shl 8) or (payload[2].toInt() and 0xFF)
    if (mimeLength <= 0 || payload.size <= 3 + mimeLength) return null
    val mime = String(payload, 3, mimeLength, Charsets.UTF_8)
    val bytes = payload.copyOfRange(3 + mimeLength, payload.size)
    if (bytes.size > ClipImagePolicy.MAX_BYTES) return null
    return ClipImage(bytes, mime)
}

/**
 * The clipboard helper (ISS-27): a tiny `app_process` started as the real shell
 * user through `su 2000`, because a process with root privileges has no package
 * that AOSP's clipboard owner check accepts. [clipHelperSpawnForms] carries the
 * two ways to ask `su`; the first one that answers ready is kept for restarts.
 * Requests and replies are framed on
 * stdin/stdout; the process exits when its stdin reaches EOF, so it dies with
 * the server. Its stderr is drained and reduced to counts, never copied to a
 * log.
 */
internal class ClipHelper(
    private val ctx: Context?,
    private val log: (String) -> Unit,
    private val isRoot: () -> Boolean = { AndroidProcess.myUid() == 0 },
    private val requestTimeoutMs: Long = 5_000L,
) : ClipboardHelperPort {

    @Volatile private var state: ClipHelperState = ClipHelperState.Off
    private val lock = Any()
    private var epoch = 0L
    @Volatile private var process: Process? = null
    @Volatile private var stdin: OutputStream? = null
    @Volatile private var onChange: (() -> Unit)? = null

    /** One request at a time: the helper answers in order and the poll is cheap. */
    private val requestLock = Any()
    private val nextId = AtomicInteger(1)
    @Volatile private var pending: Pending? = null

    private val scheduler = Executors.newSingleThreadScheduledExecutor { runnable ->
        Thread(runnable, "pocketdeck-cliphelper").apply { isDaemon = true }
    }
    private val changes = Executors.newSingleThreadExecutor { runnable ->
        Thread(runnable, "pocketdeck-cliphelper-change").apply { isDaemon = true }
    }

    override val available: Boolean get() = state is ClipHelperState.Ready

    override fun start() = onEvent(ClipHelperEvent.Start)

    override fun stop() = onEvent(ClipHelperEvent.Stop)

    override fun listen(onChange: () -> Unit) {
        this.onChange = onChange
    }

    override fun getText(): ClipText? = request(ClipHelperFrames.TEXT)?.let(::parseClipTextReply)

    override fun readImage(): ClipImage? = request(ClipHelperFrames.IMAGE)?.let(::parseClipImageReply)

    private fun request(type: Int): ByteArray? {
        if (!available) return null
        val out = stdin ?: return null
        synchronized(requestLock) {
            if (!available) return null
            val id = nextId.getAndIncrement()
            val waiter = Pending(id)
            pending = waiter
            try {
                ClipHelperFrames.write(out, type, id)
            } catch (_: IOException) {
                pending = null
                return null
            }
            val reply = try {
                waiter.reply.poll(requestTimeoutMs, TimeUnit.MILLISECONDS)
            } catch (_: InterruptedException) {
                null
            }
            pending = null
            return reply?.payload
        }
    }

    private fun onEvent(event: ClipHelperEvent) {
        val (previous, step, eventEpoch) = synchronized(lock) {
            val before = state
            val next = clipHelperStep(before, event)
            state = next.state
            if (before != next.state) epoch += 1
            Triple(before, next, epoch)
        }
        log("cliphelper: ${previous.label()} --${event.label()}--> ${step.state.label()}")
        for (action in step.actions) when (action) {
            is ClipHelperAction.Spawn -> spawnLater(action.attempt, action.form, 0, eventEpoch)
            is ClipHelperAction.SpawnAfter -> spawnLater(action.attempt, action.form, action.delayMs, eventEpoch)
            ClipHelperAction.Kill -> kill()
        }
    }

    private fun spawnLater(attempt: Int, form: Int, delayMs: Long, eventEpoch: Long) {
        scheduler.schedule({ spawn(attempt, form, eventEpoch) }, delayMs, TimeUnit.MILLISECONDS)
    }

    private fun spawn(attempt: Int, form: Int, eventEpoch: Long) {
        if (!currentSpawn(attempt, form) || epoch != eventEpoch) return
        if (!isRoot()) {
            onEvent(ClipHelperEvent.Died(attempt, form, "not root"))
            return
        }
        val apk = appApkPath(ctx) ?: run {
            onEvent(ClipHelperEvent.Died(attempt, form, "no apk"))
            return
        }
        val command = clipHelperSpawnForms(clipHelperCommand(apk))[form - 1]
        val started = runCatching { ProcessBuilder(command).start() }.getOrNull()
        if (started == null) {
            onEvent(ClipHelperEvent.Died(attempt, form, "no su"))
            return
        }
        synchronized(lock) {
            if (!currentSpawn(attempt, form) || epoch != eventEpoch) {
                runCatching { started.destroy() }
                return
            }
            process = started
            stdin = started.outputStream
        }
        drainErrors(started)
        readReplies(started, attempt, form)
        watchExit(started, attempt, form)
    }

    /** The transition that asked for this process is still the current one. */
    private fun currentSpawn(attempt: Int, form: Int): Boolean = when (val current = state) {
        is ClipHelperState.Starting -> current.attempt == attempt && current.form == form
        is ClipHelperState.Restarting -> current.attempt == attempt && current.form == form
        else -> false
    }

    /** The one helper command line; the form only decides how `su` is asked. */
    private fun clipHelperCommand(apk: String): String =
        "CLASSPATH='${apk.replace("'", "'\\''")}' exec app_process /system/bin ${ClipHelperMain::class.java.name}"

    private fun readReplies(started: Process, attempt: Int, form: Int) {
        Thread({
            runCatching {
                while (true) {
                    val frame = ClipHelperFrames.read(started.inputStream) ?: break
                    when (frame.type) {
                        ClipHelperFrames.READY -> onEvent(ClipHelperEvent.Started(attempt, form))
                        ClipHelperFrames.CHANGED -> changes.execute { onChange?.invoke() }
                        ClipHelperFrames.TEXT_REPLY, ClipHelperFrames.IMAGE_REPLY -> {
                            val waiter = pending
                            if (waiter != null && waiter.id == frame.id) waiter.reply.offer(frame)
                        }
                    }
                }
            }
        }, "cliphelper-reader").apply { isDaemon = true; start() }
    }

    private fun watchExit(started: Process, attempt: Int, form: Int) {
        Thread({
            val code = runCatching { started.waitFor() }.getOrDefault(-1)
            // Let the reader take the last frames before the state changes.
            runCatching { Thread.sleep(20) }
            // A stopped or replaced process must not push the new attempt down.
            if (process !== started) return@Thread
            onEvent(ClipHelperEvent.Died(attempt, form, "exit $code"))
        }, "cliphelper-watcher").apply { isDaemon = true; start() }
    }

    /** The helper's own stderr could carry a path or a line; keep counts only. */
    private fun drainErrors(started: Process) {
        Thread({
            var lines = 0
            var fatal = 0
            var exceptions = 0
            var errors = 0
            runCatching {
                started.errorStream.bufferedReader().useLines { sequence ->
                    for (line in sequence) {
                        lines += 1
                        when {
                            line.contains("FATAL EXCEPTION") -> fatal += 1
                            line.contains("Exception") -> exceptions += 1
                            line.contains("Error") -> errors += 1
                        }
                    }
                }
            }
            if (lines > 0) {
                log("cliphelper: stderr lines=$lines fatal=$fatal exceptions=$exceptions errors=$errors")
            }
        }, "cliphelper-stderr").apply { isDaemon = true; start() }
    }

    private fun kill() {
        val current = synchronized(lock) {
            val running = process
            process = null
            stdin = null
            running
        } ?: return
        // EOF on stdin is the helper's own exit path; destroy is only the guard.
        runCatching { current.outputStream.close() }
        Thread({
            if (!runCatching { current.waitFor(500, TimeUnit.MILLISECONDS) }.getOrDefault(false)) {
                runCatching { current.destroy() }
            }
        }, "cliphelper-kill").apply { isDaemon = true; start() }
    }

    private class Pending(val id: Int) {
        val reply = LinkedBlockingQueue<ClipHelperFrame>(1)
    }
}

private fun ClipHelperState.label(): String = when (this) {
    ClipHelperState.Off -> "off"
    is ClipHelperState.Starting -> "starting($attempt)"
    is ClipHelperState.Restarting -> "restarting($attempt)"
    is ClipHelperState.Ready -> "ready($attempt)"
    is ClipHelperState.Failed -> "failed($reason)"
}

private fun ClipHelperEvent.label(): String = when (this) {
    ClipHelperEvent.Start -> "start"
    is ClipHelperEvent.Started -> "started($attempt)"
    is ClipHelperEvent.Died -> "died($reason)"
    ClipHelperEvent.Stop -> "stop"
}

/**
 * The helper process' entry point. It runs from the same APK through
 * `app_process`, as UID 2000, with no session or network: it registers the real
 * shell user's primary-clip listener and answers framed reads until stdin EOF.
 * It never logs clip text or bytes.
 */
internal object ClipHelperMain {

    private const val TAG = "PocketDeckClipHelper"

    @JvmStatic
    fun main(args: Array<String>) {
        if (AndroidProcess.myUid() != SHELL_UID) {
            android.util.Log.w(TAG, "not the shell user")
            return
        }
        // A system context is enough for the content resolver behind clip image
        // URIs; there is no app process here. ActivityThread is hidden from the
        // SDK, so it is reached the way the rest of the server reaches platform
        // internals.
        val ctx = runCatching {
            val threadClass = Class.forName("android.app.ActivityThread")
            val thread = threadClass.getMethod("systemMain").invoke(null)
            threadClass.getMethod("getSystemContext").invoke(thread) as Context
        }.getOrNull()
        if (ctx == null) android.util.Log.w(TAG, "no system context; images unavailable")
        val clipboard = ShellClipboard(ctx, { code -> android.util.Log.i(TAG, code) }, callerUid = AndroidProcess.myUid())
        val out = BufferedOutputStream(FileOutputStream(FileDescriptor.out))
        val registration = clipboard.listen {
            runCatching { ClipHelperFrames.write(out, ClipHelperFrames.CHANGED, 0) }
        }
        ClipHelperFrames.write(out, ClipHelperFrames.READY, 0)
        android.util.Log.i(TAG, "ready")
        val input = BufferedInputStream(FileInputStream(FileDescriptor.`in`))
        while (true) {
            val frame = ClipHelperFrames.read(input) ?: break
            when (frame.type) {
                ClipHelperFrames.TEXT ->
                    ClipHelperFrames.write(out, ClipHelperFrames.TEXT_REPLY, frame.id, clipTextPayload(clipboard.getText()))
                ClipHelperFrames.IMAGE ->
                    ClipHelperFrames.write(out, ClipHelperFrames.IMAGE_REPLY, frame.id, clipImagePayload(clipboard.readImage()))
            }
        }
        clipboard.stop(registration)
        android.util.Log.i(TAG, "stdin closed")
    }
}
