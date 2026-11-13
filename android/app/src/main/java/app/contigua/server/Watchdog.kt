package app.contigua.server

import android.content.Context
import android.os.SystemClock
import android.util.Log
import android.view.Display
import java.io.File
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.util.concurrent.TimeUnit

/**
 * What the watchdog does when the server's socket closes without the clean byte.
 */
internal data class WatchdogPlan(val restorePanel: Boolean, val sleep: Boolean) {
    val act: Boolean get() = restorePanel || sleep
}

/**
 * The crash decision, as pure logic: the marker file says whether a panel
 * override was live, and the panel's own state says whether restoring NORMAL is
 * still needed (the platform believes it is on while SurfaceFlinger shows off).
 * With no marker there is nothing to do, whatever the crash was.
 */
internal object WatchdogPolicy {
    fun onServerGone(markerExists: Boolean, panelOn: Boolean): WatchdogPlan =
        if (!markerExists) WatchdogPlan(restorePanel = false, sleep = false)
        else WatchdogPlan(restorePanel = panelOn, sleep = true)
}

/**
 * Crash-safe cleanup for the panel override.
 *
 * "Turn Off Phone Screen" ([PanelHold]) writes `POWER_MODE_OFF` straight into
 * SurfaceFlinger, which the platform does not know about: if the server process
 * dies while the override is applied, a locked phone would keep a dark panel
 * that the platform thinks is on (and no session to ever restore it). While an override is live, a
 * tiny second `app_process` (the same APK, no framework UI, no wake lock) holds a
 * loopback socket to the server and blocks on a read. EOF without the clean byte
 * means the server died; the watchdog then restores the panel only when the
 * marker file — written just before the override is applied and deleted once the
 * server restored the panel itself — exists, puts the phone back to sleep, and
 * exits.
 *
 * The watchdog is started lazily, only when the hold actually forces the panel
 * off, and stopped as soon as the hold ends, so a session that never holds the
 * panel never pays for it. Orphan virtual displays are not its job:
 * system_server releases the displays of a dead owner (verified on the emulator,
 * see the report).
 */
internal class Watchdog(private val ctx: Context?, private val log: (String) -> Unit) {

    private var serverSocket: ServerSocket? = null
    private var socket: Socket? = null
    private var process: Process? = null

    /** Bumped by every stop: an in-flight start from an older episode is discarded. */
    private var generation = 0
    private var starter: Thread? = null

    /**
     * Starts the watchdog if it is not already watching. Returns immediately: the
     * child's `app_process` start must not delay the panel-off, and the child
     * treats "could not connect" as "the server is gone", so the guard is
     * effective as soon as the child is up.
     */
    fun ensure() = synchronized(this) {
        if (process?.isAlive == true && socket?.isClosed == false) return
        if (starter?.isAlive == true) return
        val gen = ++generation
        starter = Thread({ startNow(gen) }, "contigua-watchdog-start").also { it.start() }
    }

    private fun startNow(gen: Int) {
        val ss = runCatching { ServerSocket(0, 1, InetAddress.getLoopbackAddress()) }.getOrNull()
        if (ss == null) {
            log("watchdog unavailable: cannot bind the liveness socket")
            return
        }
        ss.soTimeout = ACCEPT_TIMEOUT_MS.toInt()
        val apk = apkPath()
        if (apk == null) {
            log("watchdog unavailable: cannot locate the app's APK for app_process")
            runCatching { ss.close() }
            return
        }
        val cmd = listOf(
            APP_PROCESS,
            "-Djava.class.path=$apk",
            "/system/bin",
            "--nice-name=$PROCESS_NAME",
            WatchdogMain::class.java.name,
            ss.localPort.toString(),
            MARKER,
        )
        val proc = runCatching {
            ProcessBuilder(cmd)
                .redirectOutput(DEV_NULL)
                .redirectError(DEV_NULL)
                .start()
        }.getOrNull()
        if (proc == null) {
            log("watchdog unavailable: app_process did not start")
            runCatching { ss.close() }
            return
        }
        val accepted = runCatching { ss.accept() }.getOrNull()
        runCatching { ss.close() }
        if (accepted == null) {
            runCatching { proc.destroy() }
            log("watchdog unavailable: it did not connect back")
            return
        }
        synchronized(this) {
            if (gen != generation) {
                runCatching { accepted.close() }
                runCatching { proc.destroy() }
                return
            }
            socket = accepted
            process = proc
        }
        log("watchdog up, guarding the panel override")
    }

    /**
     * Tells a running watchdog to exit. The clean byte ends the child; the reap
     * happens on its own thread, because waiting for another process's VM to
     * shut down took ~0.9 s on the 16:44 log and that wait sat on the session's
     * reader thread, behind every later `phone.panel` request.
     */
    fun stopCleanly() = synchronized(this) {
        generation++
        val p = process
        process = null
        val s = socket
        socket = null
        if (s != null) {
            runCatching {
                s.getOutputStream().write(CLEAN_BYTE)
                s.getOutputStream().flush()
            }
            runCatching { s.close() }
        }
        runCatching { serverSocket?.close() }
        serverSocket = null
        if (p != null) {
            Thread({
                runCatching { if (!p.waitFor(STOP_TIMEOUT_MS, TimeUnit.MILLISECONDS)) p.destroy() }
                log("watchdog stopped")
            }, "contigua-watchdog-stop").apply { isDaemon = true }.start()
        }
    }

    /** Records that the panel override is live; the watchdog acts on it if we die. */
    fun markPanelForced() {
        runCatching {
            val f = File(MARKER)
            f.parentFile?.mkdirs()
            f.writeText("pid=${android.os.Process.myPid()}\n")
        }.onFailure { log("watchdog: cannot write the panel marker (${it.message})") }
    }

    /** The panel is restored (or the platform owns it again): no cleanup needed. */
    fun clearPanelForced() {
        runCatching { File(MARKER).delete() }
    }

    private fun apkPath(): String? = appApkPath(ctx)

    companion object {        /** Written while the panel override is live, deleted when it is not. */
        const val MARKER = "/data/local/tmp/contigua/panel-off"

        /** Sent on a clean stop; a bare EOF means the server died. */
        const val CLEAN_BYTE = 1

        private const val APP_PROCESS = "/system/bin/app_process"
        private const val PROCESS_NAME = "contigua-watchdog"
        private const val ACCEPT_TIMEOUT_MS = 5_000L
        private const val STOP_TIMEOUT_MS = 2_000L
        private val DEV_NULL = File("/dev/null")
    }
}

/**
 * The watchdog process' entry point. Runs from the same APK through
 * `app_process`, so it reuses [DisplayProbe], [PanelPower] and [SystemSleep]; it
 * never touches the session, the server or the network beyond the liveness
 * socket.
 */
internal object WatchdogMain {

    private const val TAG = "ContiguaWatchdog"

    @JvmStatic
    fun main(args: Array<String>) {
        val port = args.getOrNull(0)?.toIntOrNull() ?: return
        val marker = File(args.getOrNull(1) ?: Watchdog.MARKER)
        // Connect with a bounded retry. The parent starts us asynchronously (so
        // the panel-off is never delayed), and a connect that never succeeds
        // means the parent's listening socket is gone: the server died before we
        // were up, which is exactly the crash the marker cleanup exists for.
        val socket = connect(port, CONNECT_TIMEOUT_MS)
        if (socket == null) {
            Log.i(TAG, "server already gone")
            cleanup(marker)
            return
        }
        // Blocking read: no polling, and the read returns the moment the server
        // process (or its end of the socket) is gone.
        val clean = runCatching { socket.getInputStream().read() >= 0 }.getOrDefault(false)
        runCatching { socket.close() }
        if (clean) {
            Log.i(TAG, "server stopped cleanly")
            return
        }
        Log.i(TAG, "server disappeared")
        cleanup(marker)
    }

    private fun connect(port: Int, timeoutMs: Long): Socket? {
        val deadline = SystemClock.uptimeMillis() + timeoutMs
        while (true) {
            runCatching { Socket(InetAddress.getLoopbackAddress(), port) }.getOrNull()?.let { return it }
            if (SystemClock.uptimeMillis() >= deadline) return null
            runCatching { Thread.sleep(100) }
        }
    }

    private fun cleanup(marker: File) {
        val panelOn = runCatching { DisplayProbe.state(PANEL_DISPLAY_ID) == Display.STATE_ON }.getOrDefault(false)
        val plan = WatchdogPolicy.onServerGone(marker.exists(), panelOn)
        if (!plan.act) {
            Log.i(TAG, "no panel override left behind")
            return
        }
        if (plan.restorePanel) {
            val panel = PanelPower { Log.i(TAG, it) }
            Log.i(TAG, "restoring the panel: ${panel.panelNormal()}")
        }
        if (plan.sleep) Log.i(TAG, "phone back to sleep: ${SystemSleep.goToSleep()}")
        runCatching { marker.delete() }
        Log.i(TAG, "cleanup done")
    }

    /** Display 0 is the panel on every phone. */
    private const val PANEL_DISPLAY_ID = 0
    private const val CONNECT_TIMEOUT_MS = 15_000L
}
