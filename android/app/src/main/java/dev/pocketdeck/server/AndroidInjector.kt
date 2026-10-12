package dev.pocketdeck.server

import android.content.ClipData
import android.os.SystemClock
import android.view.InputDevice
import android.view.InputEvent
import android.view.KeyCharacterMap
import android.view.KeyEvent
import android.view.MotionEvent
import java.lang.reflect.Method
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledExecutorService
import java.util.concurrent.TimeUnit

/**
 * Injects input on a virtual display through `IInputManager.injectInputEvent`.
 * Handles are resolved once; the hot path only sets the display id and calls the
 * binder. Times come from the session so nothing here sleeps.
 */
internal class AndroidInjector(private val log: (String) -> Unit) : Injector {

    private val inputManager: Any? =
        Hidden.proxy("android.hardware.input.IInputManager", "input")
            ?: Hidden.proxy("android.os.IInputManager", "input")

    private val injectMethod: Method? =
        Hidden.method(Hidden.iface("android.hardware.input.IInputManager"), "injectInputEvent", InputEvent::class.java, Hidden.T_INT)
            ?: Hidden.method(Hidden.iface("android.os.IInputManager"), "injectInputEvent", InputEvent::class.java, Hidden.T_INT)

    private val setDisplayId: Method? =
        runCatching { InputEvent::class.java.getMethod("setDisplayId", Hidden.T_INT) }.getOrNull()

    private val setAxisValue: Method? =
        runCatching { MotionEvent::class.java.getMethod("setAxisValue", Hidden.T_INT, Hidden.T_FLOAT) }.getOrNull()

    private val clipboard: Any? = Hidden.proxy("android.os.IClipboard", "clipboard")
    private val clipboardClass = Hidden.iface("android.os.IClipboard")

    private val setPrimaryClipMethod: Method? =
        Hidden.method(clipboardClass, "setPrimaryClip", ClipData::class.java, String::class.java, Hidden.T_INT)
            ?: Hidden.method(clipboardClass, "setPrimaryClip", ClipData::class.java, String::class.java, String::class.java, Hidden.T_INT)

    private val getPrimaryClipMethod: Method? =
        Hidden.method(clipboardClass, "getPrimaryClip", String::class.java, Hidden.T_INT)
            ?: Hidden.method(clipboardClass, "getPrimaryClip", String::class.java, String::class.java, Hidden.T_INT)

    /**
     * Restores the previous clipboard text a moment after a paste. The paste key
     * is processed asynchronously by the app, so restoring immediately would race
     * it; a scheduled single-thread executor defers the restore without a sleep.
     */
    private val clipboardScheduler: ScheduledExecutorService =
        Executors.newSingleThreadScheduledExecutor { r -> Thread(r, "pocketdeck-clipboard").apply { isDaemon = true } }

    private var loggedFailure = false
    private var loggedClipboard = false

    override fun touch(
        displayId: Int,
        action: Int,
        pointerId: Int,
        nx: Float,
        ny: Float,
        size: IntSize,
        downTime: Long,
        eventTime: Long,
    ) {
        // The wire action enum matches MotionEvent's ACTION_* constants.
        val x = nx.coerceIn(0f, 1f) * size.w
        val y = ny.coerceIn(0f, 1f) * size.h
        val e = MotionEvent.obtain(downTime, eventTime, action, x, y, 0)
        try {
            e.setSource(InputDevice.SOURCE_TOUCHSCREEN)
            setDisplay(e, displayId)
            inject(e)
        } finally {
            e.recycle()
        }
    }

    override fun scroll(displayId: Int, nx: Float, ny: Float, hscroll: Float, vscroll: Float, size: IntSize) {
        val x = nx.coerceIn(0f, 1f) * size.w
        val y = ny.coerceIn(0f, 1f) * size.h
        val t = SystemClock.uptimeMillis()
        val e = MotionEvent.obtain(t, t, MotionEvent.ACTION_SCROLL, x, y, 0)
        try {
            e.setSource(InputDevice.SOURCE_MOUSE)
            setAxisValue?.let {
                runCatching {
                    it.invoke(e, MotionEvent.AXIS_HSCROLL, hscroll)
                    it.invoke(e, MotionEvent.AXIS_VSCROLL, vscroll)
                }
            }
            setDisplay(e, displayId)
            inject(e)
        } finally {
            e.recycle()
        }
    }

    override fun key(displayId: Int, action: Int, keycode: Int, metaState: Int, downTime: Long, eventTime: Long) {
        val e = KeyEvent(downTime, eventTime, action, keycode, metaState)
        e.setSource(InputDevice.SOURCE_KEYBOARD)
        setDisplay(e, displayId)
        inject(e)
    }

    override fun text(displayId: Int, s: String) {
        val runs = TextRuns.split(s)
        if (runs.all { it is TextRuns.Run.Keys }) {
            typeAscii(displayId, s)
            return
        }
        // Non-ASCII runs go through the clipboard: set the primary clip, inject
        // paste, then put the user's previous clip back.
        val previous = getClipText()
        for (run in runs) {
            when (run) {
                is TextRuns.Run.Keys -> typeAscii(displayId, run.text)
                is TextRuns.Run.Clip -> pasteViaClipboard(displayId, run.text)
            }
        }
        if (previous != null) {
            clipboardScheduler.schedule({ setClipText(previous) }, CLIPBOARD_RESTORE_DELAY_MS, TimeUnit.MILLISECONDS)
        }
    }

    private fun typeAscii(displayId: Int, s: String) {
        val kcm = KeyCharacterMap.load(KeyCharacterMap.VIRTUAL_KEYBOARD)
        for (ch in s) {
            val events = kcm.getEvents(charArrayOf(ch)) ?: continue
            for (e in events) {
                setDisplay(e, displayId)
                inject(e)
            }
        }
    }

    private fun pasteViaClipboard(displayId: Int, text: String) {
        if (!setClipText(text)) {
            if (!loggedClipboard) {
                loggedClipboard = true
                log("clipboard unavailable: cannot type non-ASCII text")
            }
            return
        }
        val t = SystemClock.uptimeMillis()
        key(displayId, KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_PASTE, 0, t, t)
        key(displayId, KeyEvent.ACTION_UP, KeyEvent.KEYCODE_PASTE, 0, t, t + 1)
    }

    private fun setClipText(s: String): Boolean {
        val m = setPrimaryClipMethod ?: return false
        return runCatching {
            val clip = ClipData.newPlainText("pocketdeck", s)
            if (m.parameterTypes.size == 3) {
                m.invoke(clipboard, clip, CLIP_PACKAGE, 0)
            } else {
                m.invoke(clipboard, clip, CLIP_PACKAGE, null as String?, 0)
            }
            true
        }.getOrDefault(false)
    }

    private fun getClipText(): String? {
        val m = getPrimaryClipMethod ?: return null
        return runCatching {
            val data = if (m.parameterTypes.size == 2) {
                m.invoke(clipboard, CLIP_PACKAGE, 0)
            } else {
                m.invoke(clipboard, CLIP_PACKAGE, null as String?, 0)
            }
            (data as? ClipData)?.getItemAt(0)?.text?.toString()
        }.getOrNull()
    }

    private fun setDisplay(e: InputEvent, displayId: Int) {
        setDisplayId?.let { runCatching { it.invoke(e, displayId) } }
    }

    private fun inject(e: InputEvent) {
        val m = injectMethod ?: return
        try {
            m.invoke(inputManager, e, INJECT_MODE_ASYNC)
        } catch (t: Throwable) {
            if (!loggedFailure) {
                loggedFailure = true
                log("input inject failed: ${t.message}")
            }
        }
    }

    private companion object {
        const val INJECT_MODE_ASYNC = 0
        const val CLIP_PACKAGE = "com.android.shell"
        const val CLIPBOARD_RESTORE_DELAY_MS = 400L
    }
}
