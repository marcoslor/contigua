package app.contigua.server

import android.os.SystemClock
import android.view.InputDevice
import android.view.InputEvent
import android.view.KeyCharacterMap
import android.view.KeyEvent
import android.view.MotionEvent
import app.contigua.proto.Frames
import java.lang.reflect.Method
import java.util.concurrent.Executors
import java.util.concurrent.Semaphore
import java.util.concurrent.ScheduledExecutorService
import java.util.concurrent.TimeUnit

/**
 * Injects input on a virtual display through `IInputManager.injectInputEvent`.
 * Handles are resolved once; the hot path only sets the display id and calls the
 * binder. Times come from the session so nothing here sleeps.
 */
internal class AndroidInjector(
    private val log: (String) -> Unit,
    /** Receives every event and its display instead of the input service; the JVM tests capture them here. */
    private val sink: ((InputEvent, Int) -> Unit)? = null,
    /**
     * The clipboard the person's paste fallback borrows (WIN-80). Only a
     * [ClipKeeper] can save the whole clip and put it back, so any other port,
     * or null, means the fallback never pastes.
     */
    private val clipboard: ClipboardPort? = null,
    /** The focused field of each display, which the person's typing sets text on first; null: none. */
    private val fields: FocusedFieldSource? = null,
) : Injector {

    private val inputManager: Any? =
        Hidden.proxy("android.hardware.input.IInputManager", "input")
            ?: Hidden.proxy("android.os.IInputManager", "input")

    private val injectMethod: Method? =
        Hidden.method(Hidden.iface("android.hardware.input.IInputManager"), "injectInputEvent", InputEvent::class.java, Hidden.T_INT)
            ?: Hidden.method(Hidden.iface("android.os.IInputManager"), "injectInputEvent", InputEvent::class.java, Hidden.T_INT)

    private val setDisplayId: Method? =
        runCatching { InputEvent::class.java.getMethod("setDisplayId", Hidden.T_INT) }.getOrNull()

    /**
     * Puts the person's clip back a moment after a paste. The paste key is
     * processed asynchronously by the app, so restoring immediately would race
     * it; a scheduled single-thread executor defers the restore without a sleep.
     */
    private val clipboardScheduler: ScheduledExecutorService =
        Executors.newSingleThreadScheduledExecutor { r -> Thread(r, "contigua-clipboard").apply { isDaemon = true } }

    private val touches = TouchTracker(log)

    private var loggedFailure = false

    /**
     * One paste at a time uses the clipboard (WIN-80): taken before the clip is
     * saved, given back only after it is put back, on whichever thread that is.
     */
    private val pasteTurn = Semaphore(1)

    @Volatile private var runsDropped = 0

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
        val ev = touches.onTouch(displayId, action, pointerId, nx, ny, downTime, eventTime) ?: return
        val count = ev.pointers.size
        val properties = Array(count) { i ->
            MotionEvent.PointerProperties().apply {
                id = ev.pointers[i].id
                toolType = MotionEvent.TOOL_TYPE_FINGER
            }
        }
        val coords = Array(count) { i ->
            MotionEvent.PointerCoords().apply {
                x = ev.pointers[i].nx.coerceIn(0f, 1f) * size.w
                y = ev.pointers[i].ny.coerceIn(0f, 1f) * size.h
                pressure = 1f
                this.size = 1f
            }
        }
        val e = MotionEvent.obtain(
            ev.downTime, ev.eventTime, motionAction(ev), count, properties, coords,
            0, 0, 1f, 1f, 0, 0, InputDevice.SOURCE_TOUCHSCREEN, 0,
        )
        try {
            deliver(e, displayId)
        } finally {
            e.recycle()
        }
    }

    private fun motionAction(ev: TouchTracker.Event): Int = when (ev.kind) {
        TouchTracker.Kind.DOWN -> MotionEvent.ACTION_DOWN
        TouchTracker.Kind.POINTER_DOWN ->
            MotionEvent.ACTION_POINTER_DOWN or (ev.actionIndex shl MotionEvent.ACTION_POINTER_INDEX_SHIFT)
        TouchTracker.Kind.MOVE -> MotionEvent.ACTION_MOVE
        TouchTracker.Kind.POINTER_UP ->
            MotionEvent.ACTION_POINTER_UP or (ev.actionIndex shl MotionEvent.ACTION_POINTER_INDEX_SHIFT)
        TouchTracker.Kind.UP -> MotionEvent.ACTION_UP
        TouchTracker.Kind.CANCEL -> MotionEvent.ACTION_CANCEL
    }

    /**
     * A mouse-wheel event. The axes live on the pointer's coords: the per-event
     * `MotionEvent.setAxisValue` this used to call is gone on Android 16, and its
     * failure was swallowed, so apps got scroll events with both axes at zero.
     */
    override fun scroll(displayId: Int, nx: Float, ny: Float, hscroll: Float, vscroll: Float, size: IntSize) {
        val t = SystemClock.uptimeMillis()
        val properties = arrayOf(
            MotionEvent.PointerProperties().apply {
                id = 0
                toolType = MotionEvent.TOOL_TYPE_MOUSE
            },
        )
        val coords = arrayOf(
            MotionEvent.PointerCoords().apply {
                x = nx.coerceIn(0f, 1f) * size.w
                y = ny.coerceIn(0f, 1f) * size.h
                setAxisValue(MotionEvent.AXIS_HSCROLL, hscroll)
                setAxisValue(MotionEvent.AXIS_VSCROLL, vscroll)
            },
        )
        val e = MotionEvent.obtain(
            t, t, MotionEvent.ACTION_SCROLL, 1, properties, coords,
            0, 0, 1f, 1f, 0, 0, InputDevice.SOURCE_MOUSE, 0,
        )
        try {
            deliver(e, displayId)
        } finally {
            e.recycle()
        }
    }

    /**
     * A hovering mouse: the same motion a real one makes over the display, so
     * hover highlights, tooltips and hover menus react. Nothing is pressed:
     * the pointer only moves. `SOURCE_MOUSE` is what makes Android treat it as
     * a mouse rather than a stylus.
     */
    override fun hover(displayId: Int, action: Int, nx: Float, ny: Float, size: IntSize) {
        val t = SystemClock.uptimeMillis()
        val properties = arrayOf(
            MotionEvent.PointerProperties().apply {
                id = 0
                toolType = MotionEvent.TOOL_TYPE_MOUSE
            },
        )
        val coords = arrayOf(
            MotionEvent.PointerCoords().apply {
                x = nx.coerceIn(0f, 1f) * size.w
                y = ny.coerceIn(0f, 1f) * size.h
                // A hovering pointer touches nothing.
                pressure = 0f
                this.size = 0f
            },
        )
        val e = MotionEvent.obtain(
            t, t, hoverAction(action), 1, properties, coords,
            0, 0, 1f, 1f, 0, 0, InputDevice.SOURCE_MOUSE, 0,
        )
        try {
            deliver(e, displayId)
        } finally {
            e.recycle()
        }
    }

    private fun hoverAction(action: Int): Int = when (action) {
        Frames.HOVER_ENTER -> MotionEvent.ACTION_HOVER_ENTER
        Frames.HOVER_MOVE -> MotionEvent.ACTION_HOVER_MOVE
        Frames.HOVER_EXIT -> MotionEvent.ACTION_HOVER_EXIT
        else -> MotionEvent.ACTION_HOVER_MOVE
    }

    override fun key(displayId: Int, action: Int, keycode: Int, metaState: Int, downTime: Long, eventTime: Long) {
        // Repeat 0, then the meta: the five-argument constructor's last
        // argument is the repeat count, and took the meta for it (B5's proof).
        val e = KeyEvent(downTime, eventTime, action, keycode, 0, metaState)
        e.setSource(InputDevice.SOURCE_KEYBOARD)
        deliver(e, displayId)
    }

    /**
     * The person's typing (WIN-80). Key-map runs go as keys; any other run is
     * set on the focused field by `ui.type`'s route (MCP-109), and only a
     * field that offers no set text gets it by paste, with the person's whole
     * clip saved and put back, or not at all. Runs go in order on the caller's
     * thread, as the KEY frames around them do.
     */
    override fun text(displayId: Int, s: String) {
        for (run in TextRuns.split(s)) {
            when (run) {
                is TextRuns.Run.Keys -> typeAscii(displayId, run.text)
                is TextRuns.Run.Clip -> typeRun(displayId, run.text)
            }
        }
    }

    private enum class Route { TYPED, PASTE, DROP }

    private fun typeRun(displayId: Int, text: String) {
        when (route(displayId, text)) {
            Route.TYPED -> Unit
            Route.PASTE -> pasteKeepingTheClip(displayId, text)
            Route.DROP -> dropped(text, "set_text_refused")
        }
    }

    /**
     * Where a run goes: set text when the focused field offers it, paste when
     * it does not. No focused node, or a tree that cannot be read, is a field
     * with no set text as far as the phone can tell.
     */
    private fun route(displayId: Int, text: String): Route {
        val source = fields ?: return Route.PASTE
        return runCatching { source.withFocus(displayId) { focus -> setTextRoute(focus, text) } }
            .getOrNull() ?: Route.PASTE
    }

    private fun setTextRoute(focus: TextEntry.Focus?, text: String): Route {
        if (focus == null || !focus.field.setsText) return Route.PASTE
        return when (TextEntry.type(0, text, clear = false, submit = false, focus = focus, keys = NO_KEYS)) {
            is TextEntry.Outcome.Typed -> Route.TYPED
            // The field offers set text but did not take this run (a password
            // field holding text, or the app refused): no paste either.
            is TextEntry.Outcome.Refused -> Route.DROP
        }
    }

    /**
     * The fallback, one at a time: save the whole clip, prove it can be put
     * back by putting it back, set the run, paste, and put the clip back a
     * moment later. A clip that cannot be saved or put back is never
     * overwritten: the run is dropped.
     */
    private fun pasteKeepingTheClip(displayId: Int, text: String) {
        val keeper = clipboard as? ClipKeeper ?: return dropped(text, "no_clipboard")
        if (!pasteTurn.tryAcquire(PASTE_TURN_WAIT_MS, TimeUnit.MILLISECONDS)) return dropped(text, "busy")
        var handedOff = false
        try {
            val saved = keeper.saveClip() ?: return dropped(text, "clip_unreadable")
            if (!keeper.putBack(saved)) return dropped(text, "clip_not_restorable")
            if (!keeper.setTyping(text)) return dropped(text, "clip_write_refused")
            val t = SystemClock.uptimeMillis()
            key(displayId, KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_PASTE, 0, t, t)
            key(displayId, KeyEvent.ACTION_UP, KeyEvent.KEYCODE_PASTE, 0, t, t + 1)
            val restore = Runnable {
                try {
                    if (!keeper.putBack(saved)) log("typing: the clip was not put back after a paste")
                } finally {
                    pasteTurn.release()
                }
            }
            handedOff = runCatching {
                clipboardScheduler.schedule(restore, CLIPBOARD_RESTORE_DELAY_MS, TimeUnit.MILLISECONDS)
            }.isSuccess
            if (!handedOff) {
                // No executor to defer it: put it back now rather than never.
                if (!keeper.putBack(saved)) log("typing: the clip was not put back after a paste")
            }
        } finally {
            if (!handedOff) pasteTurn.release()
        }
    }

    /** A run that went nowhere: its length and the reason only, never its text. */
    private fun dropped(text: String, reason: String) {
        runsDropped += 1
        log("typing: dropped a run of ${text.codePointCount(0, text.length)} characters ($reason, $runsDropped so far)")
    }

    /**
     * `ui.type`'s keys (MCP-109): the events `KeyCharacterMap.VIRTUAL_KEYBOARD`
     * makes for [s], or null when a character has none. A map that answers a
     * character with `KEYCODE_UNKNOWN` instead of null has no key for it
     * either. [text] and its clipboard paste are not this path (MCP-110).
     */
    override fun keyStrokes(s: String): List<KeyStroke>? {
        if (s.isEmpty()) return emptyList()
        val events = runCatching {
            KeyCharacterMap.load(KeyCharacterMap.VIRTUAL_KEYBOARD).getEvents(s.toCharArray())
        }.getOrNull() ?: return null
        if (events.any { it.keyCode == KeyEvent.KEYCODE_UNKNOWN }) return null
        return events.map { KeyStroke(it.action, it.keyCode, it.metaState) }
    }

    private fun typeAscii(displayId: Int, s: String) {
        val kcm = KeyCharacterMap.load(KeyCharacterMap.VIRTUAL_KEYBOARD)
        for (ch in s) {
            val events = kcm.getEvents(charArrayOf(ch)) ?: continue
            for (e in events) {
                deliver(e, displayId)
            }
        }
    }

    private fun deliver(e: InputEvent, displayId: Int) {
        sink?.let {
            it(e, displayId)
            return
        }
        setDisplayId?.let { runCatching { it.invoke(e, displayId) } }
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
        const val CLIPBOARD_RESTORE_DELAY_MS = 400L

        /** How long a run waits for an earlier paste's clip to be put back. */
        const val PASTE_TURN_WAIT_MS = 2_000L

        /** The set-text route's keyboard: a run that reaches it has no keys. */
        val NO_KEYS = object : TextEntry.Keys {
            override fun strokes(text: String): List<KeyStroke>? = null
            override fun press(strokes: List<KeyStroke>) = Unit
        }
    }
}

/**
 * The focused field of a display as the person's typing reaches it (WIN-80):
 * the UI tree's node with input focus, read and acted on under the tree's one
 * read at a time.
 */
internal interface FocusedFieldSource {
    /**
     * Runs [block] on [displayId]'s node with input focus (null: none has it)
     * and answers its result, or null when the tree cannot be read.
     */
    fun <T> withFocus(displayId: Int, block: (TextEntry.Focus?) -> T): T?
}
