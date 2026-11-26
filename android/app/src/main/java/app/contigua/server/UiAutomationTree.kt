package app.contigua.server

import android.accessibilityservice.AccessibilityServiceInfo
import android.app.UiAutomation
import android.content.Context
import android.graphics.Rect
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.view.accessibility.AccessibilityNodeInfo
import android.view.accessibility.AccessibilityWindowInfo
import java.util.Collections
import java.util.WeakHashMap
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.locks.ReentrantLock
import kotlin.concurrent.withLock

/**
 * The shell side of `ui.tree` (docs/PROTOCOL.md "UI tree", WIN-79): one
 * `UiAutomation` connection, held on a looper thread of its own, that reads the
 * accessibility tree of a stream's display.
 *
 * This is the slot no ordinary accessibility service fills: a service only sees
 * the display it is running on, and `uiautomator dump` only reads display 0, so
 * neither can see an app window on its own virtual display (ISS-143). At the
 * shell UID the platform hands out every display, with no service the person
 * has to enable.
 *
 * The connection is made by reflection, exactly as the debug dump proved on a
 * real phone (ISS-141): `UiAutomation` and its constructor are hidden, and
 * `UiAutomationConnection` is the platform's own. Nothing here reads a node's
 * text into a log; only counts and codes leave.
 */
internal class UiAutomationTree(private val log: (String) -> Unit) : UiTreeSource, UiPressSource, UiTypeSource, FocusedFieldSource {

    private val lock = Any()

    /** Tests only: stands in for [connect] (the platform's hidden connection). */
    @Volatile internal var connector: (() -> UiAutomation)? = null
    private val startLock = Any()

    /**
     * The sessions that ended before this tree's watch thread existed (#273):
     * `cancel` has nothing to cancel then (no looper, no [SettleWatches]), and
     * the session's own `ui.settle` would start the thread and watch on a dead
     * session (MCP-81). Kept here instead, so that watch never starts. Guarded
     * by itself; weak keys, so an entry goes with its session.
     */
    private val ended: MutableSet<Any> = Collections.newSetFromMap(WeakHashMap())
    /**
     * One read or action at a time. Internal so the JVM tests can hold it:
     * the person's typing waits on it for [FOCUS_WAIT_MS] only (WIN-80).
     */
    internal val readLock = ReentrantLock()

    @Volatile private var looperThread: Thread? = null
    @Volatile private var handler: Handler? = null
    private var automation: UiAutomation? = null
    private var failure: String? = null

    /** Whether [disconnect] was called; a disconnected source answers `no_a11y`. */
    @Volatile var disconnected = false
        private set

    override fun dump(displayId: Int, size: IntSize): UiTree.Answer = readLock.withLock {
        if (disconnected) {
            return@withLock UiTree.Answer.Failure(
                UiCodes.NO_A11Y, "This phone cannot read an accessibility tree right now.",
            )
        }
        val automation = ensureAutomation() ?: return@withLock UiTree.Answer.Failure(
            UiCodes.NO_A11Y, failure ?: "This phone cannot read an accessibility tree right now.",
        )
        try {
            read(automation, displayId)
        } catch (t: Throwable) {
            log("ui.tree: read ${t.javaClass.simpleName}") // log-ok: class only
            restart()
            val again = ensureAutomation() ?: return@withLock UiTree.Answer.Failure(
                UiCodes.NO_A11Y, "This phone cannot read an accessibility tree right now.",
            )
            try {
                read(again, displayId)
            } catch (t: Throwable) {
                log("ui.tree: read again ${t.javaClass.simpleName}") // log-ok: class only
                restart()
                UiTree.Answer.Failure(UiCodes.NO_A11Y, "This phone cannot read an accessibility tree right now.")
            }
        }
    }

    // MARK: the press (docs/PROTOCOL.md "UI tree" item 8, MCP-86/MCP-89)

    /**
     * Resolves [k] in [displayId]'s latest read, refreshes that node and
     * decides the press ([UiPress.decide]). `covered` is computed as a read
     * computes it (item 9) over a fresh walk of the display, keyed through the
     * display's own table, so `coveredBy` is a key the Mac already knows or a
     * new one, never a reused one. Never reads a node's text into a log.
     */
    override fun press(displayId: Int, size: IntSize, k: Int, expect: String?): UiPress.Decision =
        readLock.withLock {
            val failed = UiPress.Decision.Refuse(
                UiCodes.FAILED, UiTree.failure(UiCodes.FAILED, "This phone cannot read an accessibility tree right now."),
            )
            if (disconnected) return@withLock failed
            val automation = ensureAutomation() ?: return@withLock failed
            val keys = tables.table(displayId) { true }
            val latestNode = keys.identity(k)?.let { latestNode(displayId, it) }
            val target = latestNode?.let { found ->
                object : UiPress.Target {
                    override fun refresh(): Boolean = runCatching { found.refresh() }.getOrDefault(false)
                    override fun read(): UiTree.Node = this@UiAutomationTree.node(found, 0, HashMap())
                }
            }
            UiPress.decide(target, size, expect) { coverNow(automation, displayId, size, keys, k) }
        }

    /** What covers [k]'s centre on a fresh walk of [displayId]: a key, `"window"`, or null. */
    private fun coverNow(automation: UiAutomation, displayId: Int, size: IntSize, keys: UiTreeKeys, k: Int): Any? {
        freshNodes(automation)
        val windows = automation.windowsOnAllDisplays.get(displayId) ?: return null
        val layers = windows.map { window ->
            val bounds = Rect().also { window.getBoundsInScreen(it) }
            UiTree.Layer(
                title = null,
                type = typeName(window.type),
                focused = window.isFocused,
                nodes = window.root?.let { children(it, 0, HashMap()) } ?: emptyList(),
                windowLayer = window.layer,
                bounds = UiTree.Box(bounds.left, bounds.top, bounds.right, bounds.bottom),
            )
        }
        @Suppress("UNCHECKED_CAST")
        val rows = UiTree.reply(displayId, size, layers, keys)["nodes"] as List<Map<String, Any?>>
        return rows.firstOrNull { it["k"] == k }?.get("covered")
    }

    // MARK: the typing (docs/PROTOCOL.md "UI tree" item 10, MCP-109/MCP-110)

    /**
     * Finds the node with input focus in [displayId]'s active layer (MCP-105)
     * and types into it ([TextEntry.type]): `ACTION_SET_TEXT` and
     * `ACTION_SET_SELECTION` are performed here, on the session's worker
     * thread, never the connection's looper. No clipboard is reachable from
     * here (MCP-110). Never reads the field's text into a log.
     */
    override fun type(
        displayId: Int,
        window: Int,
        text: String,
        clear: Boolean,
        submit: Boolean,
        keys: TextEntry.Keys,
    ): TextEntry.Outcome = readLock.withLock { focused(displayId) { focus -> TextEntry.type(window, text, clear, submit, focus, keys) } }
        ?: TextEntry.Outcome.Refused(UiCodes.FAILED, "This phone cannot read the focused field right now.")

    /**
     * The person's typing (WIN-80): [displayId]'s node with input focus, under
     * the one read at a time, waited on for [FOCUS_WAIT_MS] at most because
     * the caller is the session's reader thread. Null when the tree is busy or
     * cannot be read; nothing runs then.
     *
     * The wait is the whole bound: it never connects (a connect can take
     * seconds) and never waits for the settle (a window that lists its nodes a
     * moment later is not the person's to wait for), so an unconnected tree or
     * one whose window shows no focused field is unreadable at once and the run
     * takes the fallback under its guards. An agent's own `ui.type` still goes
     * through [focused], which connects and settles (#270).
     */
    override fun <T> withFocus(displayId: Int, block: (TextEntry.Focus?) -> T): T? {
        if (!readLock.tryLock(FOCUS_WAIT_MS, TimeUnit.MILLISECONDS)) return null
        try {
            if (disconnected) return null
            val automation = synchronized(lock) { automation } ?: return null
            val node = inputFocusOn(automation, displayId)
            return block(node?.let { NodeFocus(it) })
        } finally {
            readLock.unlock()
        }
    }

    /** [displayId]'s node with input focus, the read lock held: the field `ui.type` and the person's typing act on. */
    private fun <T> focused(displayId: Int, block: (TextEntry.Focus?) -> T): T? {
        if (disconnected) return null
        val automation = ensureAutomation() ?: return null
        // A connection just made lists its windows only after its flags land
        // (read() waits for the same reason): one wait, then once more.
        val node = inputFocusOn(automation, displayId) ?: run {
            Thread.sleep(SETTLE_MS)
            inputFocusOn(automation, displayId)
        }
        return block(node?.let { NodeFocus(it) })
    }

    /** The node with input focus in [displayId]'s active layer, or null. */
    private fun inputFocusOn(automation: UiAutomation, displayId: Int): AccessibilityNodeInfo? {
        freshNodes(automation)
        val windows = automation.windowsOnAllDisplays.get(displayId) ?: return null
        val active = windows.firstOrNull { it.isFocused } ?: return null
        val root = active.root ?: return null
        return focusUnder(root)
    }

    /**
     * The node with input focus under [root] (MCP-105): `findFocus(FOCUS_INPUT)`,
     * resolved into a WebView's tree by [TextEntry.inputFocus].
     */
    private fun focusUnder(root: AccessibilityNodeInfo): AccessibilityNodeInfo? = runCatching {
        TextEntry.inputFocus(
            root.findFocus(AccessibilityNodeInfo.FOCUS_INPUT),
            shape = { TextEntry.Shape(it.isEditable, it.isFocused) },
            children = { node -> (0 until node.childCount).mapNotNull { runCatching { node.getChild(it) }.getOrNull() } },
        )
    }.getOrNull()

    /** A focused node as [TextEntry] reads and acts on it. */
    private class NodeFocus(private val node: AccessibilityNodeInfo) : TextEntry.Focus {
        override val field = TextEntry.Field(
            text = node.text?.toString(),
            selectionStart = node.textSelectionStart,
            selectionEnd = node.textSelectionEnd,
            showingHint = node.isShowingHintText,
            password = node.isPassword,
            setsText = node.actionList.any { it.id == AccessibilityNodeInfo.ACTION_SET_TEXT },
        )

        override fun setText(text: String): Boolean = runCatching {
            val args = Bundle()
            args.putCharSequence(AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE, text)
            node.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, args)
        }.getOrDefault(false)

        override fun setSelection(start: Int, end: Int): Boolean = runCatching {
            val args = Bundle()
            args.putInt(AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_START_INT, start)
            args.putInt(AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_END_INT, end)
            node.performAction(AccessibilityNodeInfo.ACTION_SET_SELECTION, args)
        }.getOrDefault(false)
    }

    // MARK: the settle watch (docs/PROTOCOL.md "UI tree" item 7, MCP-81/MCP-107)

    /** The watches, confined to the looper thread; made with it. */
    @Volatile private var watches: SettleWatches? = null

    /** What the watches read through the current connection. */
    private val port = object : SettlePort {
        override fun windows(): Map<Int, List<Int>>? {
            val automation = synchronized(lock) { automation } ?: return null
            val all = automation.windowsOnAllDisplays
            val out = HashMap<Int, List<Int>>()
            for (i in 0 until all.size()) out[all.keyAt(i)] = all.valueAt(i).map { it.id }
            return out
        }

        override fun loading(displayId: Int, stale: () -> Boolean): Boolean? {
            val automation = synchronized(lock) { automation } ?: throw IllegalStateException("no connection")
            return loadingOn(automation, displayId, stale)
        }

        override fun setEventTypes(mask: Int) {
            val automation = synchronized(lock) { automation } ?: return
            runCatching {
                val info = automation.serviceInfo
                info.eventTypes = mask
                automation.serviceInfo = info
            }
        }
    }

    /**
     * Watches [displayId] until no content change came for [quietMs] and nothing
     * on it is loading, or [timeoutMs] passes, counting from [arrivedAt].
     * Blocking: the session calls it off its reader thread. The whole call is
     * bounded by `arrivedAt + timeoutMs + WATCH_MARGIN_MS + FINISH_MS`, under
     * the Mac's `timeoutMs + 5 s`, however long the connect took. A watch that
     * cannot start answers `not_available` (item 7), never `ui.tree`'s `no_a11y`.
     */
    override fun settle(displayId: Int, quietMs: Long, timeoutMs: Long, arrivedAt: Long, owner: Any): SettleAnswer {
        val deadline = arrivedAt + timeoutMs + WATCH_MARGIN_MS
        // #273: its session ended before this tree's watch thread existed. The
        // watch would never listen, so it does not even connect (MCP-81).
        if (hasEnded(owner)) return SettleAnswer.Cancelled
        if (disconnected) return SettleAnswer.Failure(UiCodes.NOT_AVAILABLE, NO_WATCH)
        if (ensureAutomation() == null) {
            return SettleAnswer.Failure(UiCodes.NOT_AVAILABLE, synchronized(lock) { failure } ?: NO_WATCH)
        }
        val all = watches ?: return SettleAnswer.Failure(UiCodes.NOT_AVAILABLE, NO_WATCH)
        // The end can land while the thread starts (the first check missed it).
        if (hasEnded(owner)) return SettleAnswer.Cancelled
        val watch = all.start(owner, displayId, quietMs, timeoutMs, arrivedAt)
            ?: return SettleAnswer.Failure(UiCodes.NOT_AVAILABLE, NO_WATCH)
        if (!watch.gate.await(maxOf(0L, deadline - now()), TimeUnit.MILLISECONDS)) {
            all.fail(watch, SettleAnswer.Failure(UiCodes.FAILED, "The display could not be watched."))
            watch.gate.await(FINISH_MS, TimeUnit.MILLISECONDS)
        }
        return watch.answer ?: SettleAnswer.Failure(UiCodes.FAILED, "The display could not be watched.")
    }

    override fun cancel(owner: Any) {
        // #273: no watch thread exists yet (no `ui.tree` or `ui.settle` started
        // it), so there is nothing to post to: record the end here, and the
        // session's own watch never listens (MCP-81). With a thread, the
        // watches hold it (weak, cleared with its session).
        synchronized(ended) { ended.add(owner) }
        watches?.cancel(owner)
    }

    /** Whether [owner]'s session ended; guarded by [ended] itself. */
    private fun hasEnded(owner: Any): Boolean = synchronized(ended) { owner in ended }

    /**
     * Whether any node on [displayId] is a loading signal (MCP-103), or the
     * display is listed with no window yet (MCP-107: still opening); null when
     * it is not listed. Walks at most [LOADING_WALK_NODES] nodes, stops at the
     * first signal or once [stale] (a change dropped the check, or the watch
     * ended); never reads a node's text.
     */
    private fun loadingOn(automation: UiAutomation, displayId: Int, stale: () -> Boolean): Boolean? {
        freshNodes(automation)
        val windows = automation.windowsOnAllDisplays.get(displayId) ?: return null
        if (windows.isEmpty()) return true
        var budget = LOADING_WALK_NODES
        fun walk(node: AccessibilityNodeInfo, depth: Int): Boolean {
            if (--budget < 0 || depth >= UiTree.MAX_DEPTH || stale()) return false
            val children = node.childCount
            if (LoadingSignal.loading(node.className?.toString() ?: "", node.isVisibleToUser, node.rangeInfo != null, children)) {
                return true
            }
            for (index in 0 until children) {
                val child = runCatching { node.getChild(index) }.getOrNull() ?: continue
                if (walk(child, depth + 1)) return true
            }
            return false
        }
        return windows.any { window -> window.root?.let { walk(it, 0) } ?: false }
    }

    /** The service's session clock (DeckService passes `uptimeMillis`), so [settle]'s `arrivedAt` is on it. */
    private fun now() = SystemClock.uptimeMillis()

    /**
     * The one connection this process owns is dropped here, never by a session
     * ending (WIN-79 F3). Idempotent: the service stops once, a second stop is
     * a no-op.
     */
    fun disconnect() {
        readLock.withLock {
            if (disconnected) return
            disconnected = true
            restart()
            val threadHandler = handler
            val running = watches
            handler = null
            watches = null
            // A running watch answers now instead of waiting out its deadline.
            running?.stopAll(SettleAnswer.Failure(UiCodes.NOT_AVAILABLE, NO_WATCH))
            looperThread = null
            threadHandler?.post { Looper.myLooper()?.quitSafely() }
        }
    }

    // MARK: the connection

    /**
     * The one connection, made once. Another client taking the automation
     * makes the next read fail, and [restart] gives this one a fresh connection.
     */
    internal fun ensureAutomation(): UiAutomation? {
        synchronized(lock) { automation?.let { return it } }
        startThread()
        val gate = CountDownLatch(1)
        val posted = handler?.post {
            // A connect that outlasted an earlier read's wait lands before this
            // runs (one looper): keep it. The platform refuses a second
            // connection while one is held, and that refusal must not drop it.
            if (synchronized(lock) { automation } != null) {
                gate.countDown()
                return@post
            }
            val made = try {
                connector?.invoke() ?: connect()
            } catch (t: Throwable) {
                synchronized(lock) { failure = sentence(t) } // WIN-79 F10: under the lock
                log(connectFailureLine(t)) // log-ok: class names only
                null
            }
            if (made != null) synchronized(lock) {
                automation = made
                failure = null
            }
            gate.countDown()
        } ?: return null
        if (!posted) return null
        if (!gate.await(CONNECT_TIMEOUT_MS, TimeUnit.MILLISECONDS)) {
            synchronized(lock) { failure = "The accessibility connection did not answer." }
            return null
        }
        return synchronized(lock) { automation }
    }

    /** Drops the connection so the next read makes a new one. */
    private fun restart() {
        val current = synchronized(lock) { automation.also { automation = null } } ?: return
        runCatching { UiAutomation::class.java.getDeclaredMethod("disconnect").invoke(current) }
    }

    private fun startThread() {
        synchronized(startLock) {
            if (looperThread != null) return
            val ready = CountDownLatch(1)
            val thread = Thread({
                Looper.prepare()
                val h = Handler(Looper.myLooper()!!)
                watches = SettleWatches(h, port, log, debug = app.contigua.BuildConfig.DEBUG)
                handler = h
                looperThread = Thread.currentThread()
                ready.countDown()
                Looper.loop()
            }, "contigua-ui-tree")
            thread.isDaemon = true
            thread.start()
            ready.await(THREAD_START_MS, TimeUnit.MILLISECONDS)
        }
    }

    /**
     * Connects without disturbing the phone's own accessibility services: the
     * person's screen reader keeps running (the debug dump's flag).
     */
    private fun connect(): UiAutomation {
        val context = systemContext()
            ?: throw IllegalStateException("no system context")
        val iface = Class.forName("android.app.IUiAutomationConnection")
        val connection = Class.forName("android.app.UiAutomationConnection")
            .getDeclaredConstructor().newInstance()
        val made = runCatching {
            UiAutomation::class.java.getDeclaredConstructor(Context::class.java, iface)
                .newInstance(context, connection)
        }.getOrElse {
            UiAutomation::class.java.getDeclaredConstructor(Looper::class.java, iface)
                .newInstance(Looper.myLooper(), connection)
        }
        UiAutomation::class.java.getDeclaredMethod("connect", Int::class.javaPrimitiveType)
            .invoke(made, CONNECT_FLAGS)
        val info = made.serviceInfo
        configure(info)
        // A connection made while a watch runs (after a restart) hears it again.
        if (watches?.listeningNow == true) info.eventTypes = SettleWatch.EVENT_MASK
        made.serviceInfo = info
        // The listener's thread is the platform's choice: copy the two fields
        // (the event is recycled after this returns) and hand them to the looper.
        made.setOnAccessibilityEventListener { event ->
            watches?.deliver(event.eventType, event.windowId)
        }
        return made
    }

    private fun systemContext(): Context? = runCatching {
        val threadClass = Class.forName("android.app.ActivityThread")
        val thread = runCatching { threadClass.getMethod("currentActivityThread").invoke(null) }.getOrNull()
            ?: threadClass.getMethod("systemMain").invoke(null)
        threadClass.getMethod("getSystemContext").invoke(thread) as Context
    }.getOrNull()

    private fun sentence(t: Throwable): String {
        val cause = generateSequence(t) { it.cause }.last()
        val name = cause.javaClass.simpleName
        return when {
            name.contains("Security") -> "This phone does not let its shell read the accessibility tree."
            else -> "The accessibility tree could not be read ($name)."
        }
    }

    // MARK: the read

    private fun read(automation: UiAutomation, displayId: Int): UiTree.Answer {
        // The window list fills in after the flags land; the debug dump waits
        // 300 ms for the same reason.
        Thread.sleep(SETTLE_MS)
        freshNodes(automation)
        val all = automation.windowsOnAllDisplays
        val windows = all.get(displayId)
            ?: return UiTree.Answer.Failure(
                UiCodes.NO_DISPLAY, "That window is not on a display this phone can read.",
            )
        if (windows.isEmpty()) {
            return UiTree.Answer.Failure(UiCodes.NO_DISPLAY, "That display has no windows.")
        }
        // A display no longer listed drops its table, never its next key (MCP-71).
        val keys = tables.table(displayId) { all.get(it) != null }
        synchronized(latest) { latest.keys.retainAll { all.get(it) != null } }
        val nodes = HashMap<Any, AccessibilityNodeInfo>()
        val trees = windows.map { window ->
            val bounds = Rect().also { window.getBoundsInScreen(it) }
            UiTree.Layer(
                title = UiTree.label(window.title?.toString()),
                type = typeName(window.type),
                focused = window.isFocused,
                nodes = window.root?.let { root -> children(root, 0, nodes, inputFocus(window, root)) } ?: emptyList(),
                windowLayer = window.layer,
                bounds = UiTree.Box(bounds.left, bounds.top, bounds.right, bounds.bottom),
            )
        }
        // The latest read's nodes, by identity, for `ui.press` (B3).
        synchronized(latest) { latest[displayId] = nodes }
        return UiTree.Answer.Tree(trees, keys)
    }

    /** Each display's key table (MCP-71). */
    private val tables = UiTreeKeyTables()

    /** Each display's latest read: identity → node, for `ui.press` to refresh (B3). */
    private val latest = HashMap<Int, Map<Any, AccessibilityNodeInfo>>()

    /** The node [identity] names in [displayId]'s latest read, or null. */
    fun latestNode(displayId: Int, identity: Any): AccessibilityNodeInfo? =
        synchronized(latest) { latest[displayId]?.get(identity) }

    /**
     * Drops the connection's node cache before a walk (MCP-107): a guard
     * against a suspected cause of reads that came back one row (nodes=1) with
     * the settle watch's listener on — a cached root with no children — not a
     * proven fix: the lead's A/B on #166 did not reproduce it. Kept because a
     * walk from a cleared cache asks the app and costs little.
     * `debug.contigua.ui_cache=keep` (debug builds only) skips the clear, so
     * the rig can A/B it.
     */
    private fun freshNodes(automation: UiAutomation) {
        if (UiCacheDebug.keep()) return
        runCatching { automation.clearCache() }
    }

    /**
     * The identity of the node with input focus in [window] when it is the
     * layer with input focus ([focusUnder] its root), else null: only that
     * node is sent `focus` (MCP-105), the one `ui.type` types into.
     */
    private fun inputFocus(window: AccessibilityWindowInfo, root: AccessibilityNodeInfo): Any? {
        if (!window.isFocused) return null
        return focusUnder(root)?.let { NodeIdentity.of(it) }
    }

    /** [focus] is the identity [inputFocus] found; a node is `focused` only when it is that node. */
    private fun children(
        node: AccessibilityNodeInfo,
        depth: Int,
        seen: MutableMap<Any, AccessibilityNodeInfo>,
        focus: Any? = null,
    ): List<UiTree.Node> {
        if (depth >= UiTree.MAX_DEPTH) return emptyList()
        val out = ArrayList<UiTree.Node>(node.childCount)
        for (index in 0 until node.childCount) {
            val child = runCatching { node.getChild(index) }.getOrNull() ?: continue
            out.add(node(child, depth, seen, focus))
        }
        return out
    }

    private fun node(
        node: AccessibilityNodeInfo,
        depth: Int,
        seen: MutableMap<Any, AccessibilityNodeInfo>,
        focus: Any? = null,
    ): UiTree.Node {
        val box = Rect().also { node.getBoundsInScreen(it) }
        // Deprecated but still filled from the view's own drawing rect: a row
        // its parent clips out keeps its size here (MCP-106).
        @Suppress("DEPRECATION")
        val inParent = Rect().also { node.getBoundsInParent(it) }
        val identity = NodeIdentity.of(node)
        seen[identity] = node
        return UiTree.Node(
            role = node.className?.toString() ?: "?",
            text = node.text?.toString(),
            desc = node.contentDescription?.toString(),
            viewId = node.viewIdResourceName,
            box = UiTree.Box(box.left, box.top, box.right, box.bottom),
            sized = inParent.width() > 0 && inParent.height() > 0,
            clickable = node.isClickable,
            editable = node.isEditable,
            scrollable = node.isScrollable,
            checkable = node.isCheckable,
            checked = node.isChecked,
            selected = node.isSelected,
            focused = focus != null && identity == focus,
            enabled = node.isEnabled,
            password = node.isPassword,
            visibleToUser = node.isVisibleToUser,
            hasRange = node.rangeInfo != null,
            children = children(node, depth + 1, seen, focus),
            childCount = node.childCount,
            heading = node.isHeading,
            drawingOrder = node.drawingOrder,
            identity = identity,
            showingHint = node.isShowingHintText,
            hintText = node.hintText?.toString(),
        )
    }

    private fun typeName(type: Int): String = when (type) {
        AccessibilityWindowInfo.TYPE_APPLICATION -> "app"
        AccessibilityWindowInfo.TYPE_INPUT_METHOD -> "ime"
        AccessibilityWindowInfo.TYPE_SYSTEM -> "system"
        AccessibilityWindowInfo.TYPE_ACCESSIBILITY_OVERLAY -> "overlay"
        AccessibilityWindowInfo.TYPE_SPLIT_SCREEN_DIVIDER -> "divider"
        AccessibilityWindowInfo.TYPE_MAGNIFICATION_OVERLAY -> "magnifier"
        else -> type.toString()
    }

    companion object {
        /**
         * The log line for a failed connect: the thrown class and the root
         * cause's class (reflection wraps the platform's refusal in an
         * `InvocationTargetException`), never a message. B6's rig runs failed
         * here after pairing and logged only the wrapper.
         */
        internal fun connectFailureLine(t: Throwable): String {
            // At most 16 links: a chain can loop (initCause refuses only the
            // throwable itself), and the walk must end.
            val root = generateSequence(t) { it.cause }.take(16).last()
            return "ui.tree: connect ${t.javaClass.simpleName} root=${root.javaClass.simpleName}"
        }

        /**
         * The connection's flags (MCP-107): interactive windows, every view,
         * view ids, and no event types: a watch asks for the five content
         * changes only while it runs ([SettleWatch.EVENT_MASK]).
         */
        fun configure(info: AccessibilityServiceInfo) {
            info.flags = info.flags or
                AccessibilityServiceInfo.FLAG_RETRIEVE_INTERACTIVE_WINDOWS or
                AccessibilityServiceInfo.FLAG_INCLUDE_NOT_IMPORTANT_VIEWS or
                AccessibilityServiceInfo.FLAG_REPORT_VIEW_IDS
            info.eventTypes = 0
        }

        /** `UiAutomation.FLAG_DONT_SUPPRESS_ACCESSIBILITY_SERVICES`. */
        private const val CONNECT_FLAGS = 1
        private const val SETTLE_MS = 300L
        /**
         * How long the person's typing waits for a tree busy with another read
         * (WIN-80): it runs on the session's reader thread, so a busy tree is
         * unreadable after this and the run takes the fallback.
         */
        private const val FOCUS_WAIT_MS = 150L
        // WIN-79 F5: thread start, connect and settle stay under the Mac's 5 s
        // deadline, so a first read answers before the Mac gives up on it.
        private const val CONNECT_TIMEOUT_MS = 2_500L
        private const val THREAD_START_MS = 1_000L
        // The machine answers by arrival + timeoutMs itself; this covers a slow
        // connect and a looper that never runs the watch's last tick. With
        // FINISH_MS the call ends by arrival + timeoutMs + 2.5 s, under the
        // Mac's timeoutMs + 5 s.
        private const val WATCH_MARGIN_MS = 2_000L
        private const val FINISH_MS = 500L
        private const val LOADING_WALK_NODES = 5_000
        private const val NO_WATCH = "This phone cannot watch the display right now."
    }
}

/**
 * A node's identity for its key (MCP-71): its window id and source node id,
 * the pair `AccessibilityNodeInfo.equals` compares. The source node id is
 * hidden, so it is read by reflection; where it cannot be, the node itself
 * stands in, since its `equals` and `hashCode` compare the same pair.
 */
internal data class NodeIdentity(val window: Int, val source: Long) {
    companion object {
        private val sourceNodeId = runCatching {
            AccessibilityNodeInfo::class.java.getDeclaredMethod("getSourceNodeId").apply { isAccessible = true }
        }.getOrNull()

        fun of(node: AccessibilityNodeInfo): Any {
            val source = sourceNodeId?.let { runCatching { it.invoke(node) as Long }.getOrNull() }
            return if (source != null) NodeIdentity(node.windowId, source) else node
        }
    }
}

/** The rig's A/B knob for [UiAutomationTree]'s cache clear; a release build never reads it. */
internal object UiCacheDebug {
    const val CACHE = "debug.contigua.ui_cache"

    fun keep(debug: Boolean, property: String?): Boolean = debug && property == "keep"

    fun keep(): Boolean =
        app.contigua.BuildConfig.DEBUG && keep(true, Hidden.systemProperty(CACHE))
}

/**
 * The one [UiAutomationTree] per process (WIN-79 F3): every session's factory
 * asks [get] and receives the same source, so a session ending never tears down
 * the connection another session still uses. Only [disconnect] — the service's
 * stop — drops it.
 */
internal class UiTreeSourceOwner(private val log: (String) -> Unit) {
    private val source = UiAutomationTree(log)

    fun get(): UiAutomationTree = source
    fun disconnect() = source.disconnect()
}
