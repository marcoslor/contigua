package app.contigua.server

/**
 * The accessibility tree of one stream's display, as the Mac's `ui_tree` tool
 * reads it (docs/PROTOCOL.md "UI tree", WIN-79, ISS-160).
 *
 * Pure: the shell side hands in what it read from UiAutomation and this decides
 * what a model sees. The tree is trimmed for a reader, not mirrored: a node
 * with no label and nothing to act on is folded into its children, classes and
 * view ids are shortened, defaults are omitted, and every node carries the
 * centre of its bounds as 0..1 of the window, the same coordinates `tap` takes.
 * A password field never carries its text.
 *
 * The shape follows what accessibility-driven automation clients settled on:
 * a compact, actionable list beats a faithful XML tree (a layout node says
 * nothing a model can act on), the tap point spares the model the arithmetic
 * that goes wrong when a screenshot is scaled, and an empty tree says so
 * instead of reading as a blank screen.
 */
object UiTree {

    /** A node as the accessibility walk read it: full strings, display pixels. */
    data class Node(
        val role: String,
        val text: String? = null,
        val desc: String? = null,
        val viewId: String? = null,
        val box: Box? = null,
        val clickable: Boolean = false,
        val editable: Boolean = false,
        val scrollable: Boolean = false,
        val checkable: Boolean = false,
        val checked: Boolean = false,
        val selected: Boolean = false,
        val focused: Boolean = false,
        val enabled: Boolean = true,
        val password: Boolean = false,
        val children: List<Node> = emptyList(),
    )

    /** A node's bounds in display pixels, origin at the display's top left. */
    data class Box(val left: Int, val top: Int, val right: Int, val bottom: Int) {
        val width: Int get() = right - left
        val height: Int get() = bottom - top
        val empty: Boolean get() = width <= 0 || height <= 0
    }

    /** One window on the display: the app, or the keyboard or a system window over it. */
    data class Window(
        val title: String?,
        val type: String,
        val focused: Boolean,
        val active: Boolean,
        val nodes: List<Node>,
    )

    /** What a read produced: a tree, or the reason there is none. */
    sealed class Answer {
        data class Tree(val windows: List<Window>) : Answer()

        /** A closed code the Mac passes on, and one sentence a person could read. */
        data class Failure(val code: String, val sentence: String) : Answer()
    }

    /**
     * At most this many nodes reach the Mac. A long list is cut with
     * `truncated`, never silently: the model can scroll and ask again.
     */
    const val MAX_NODES = 1_200

    /** Longer labels are cut here; an accessibility label is a line, not a page. */
    const val MAX_TEXT = 200

    /** Deeper than this is a broken tree, not a screen. */
    const val MAX_DEPTH = 60

    /**
     * Builds the `ok: true` reply body for a read. `size` is the stream's
     * pixel size, the space `at` is normalized to.
     */
    fun reply(display: Int, size: IntSize, snapshot: Int, windows: List<Window>): LinkedHashMap<String, Any?> {
        val out = LinkedHashMap<String, Any?>()
        val nodes = ArrayList<LinkedHashMap<String, Any?>>()
        val builder = Builder(size, nodes)
        windows.forEachIndexed { index, window ->
            builder.window(index, window)
        }
        out["ok"] = true
        // The display's own id, not a counter: virtual displays are numbered in
        // the sixties on current Android builds, which reads like a sequence
        // number when the field is called `display`. `snapshot` is the counter.
        out["displayId"] = display
        out["snapshot"] = snapshot
        out["truncated"] = builder.truncated
        out["windows"] = windows.mapIndexed { index, window ->
            linkedMapOf<String, Any?>(
                "i" to index,
                "title" to window.title,
                "type" to window.type,
                "focused" to window.focused,
                "active" to window.active,
            )
        }
        out["nodes"] = nodes
        if (nodes.isEmpty()) {
            // Prior art is blunt about this: an empty list reads as a blank
            // screen, so say what happened.
            out["note"] = "This display has no accessible content; a screenshot may still show one."
        }
        return out
    }

    /** Builds the `ok: false` reply body for a read that could not happen. */
    fun failure(code: String, sentence: String): LinkedHashMap<String, Any?> = linkedMapOf(
        "ok" to false,
        "code" to code,
        "message" to sentence,
    )

    /**
     * Trims one label. Whitespace collapses to one space (an on-screen label is
     * read as one line) and a very long one is cut at [MAX_TEXT].
     *
     * Icon fonts draw their icons as text in Unicode's private use area
     * (U+EF9E, U+EEE8, …): a glyph is art, not a word, so it never reaches the
     * reader. A label made only of glyphs is no label at all.
     */
    fun label(value: String?): String? {
        val trimmed = value?.let(::withoutPrivateUse)
            ?.replace(Regex("\\s+"), " ")
            ?.trim()
            .orEmpty()
        if (trimmed.isEmpty()) return null
        return if (trimmed.length <= MAX_TEXT) trimmed else trimmed.substring(0, MAX_TEXT)
    }

    /** Drops code points U+E000–U+F8FF and the two supplementary private use areas. */
    fun withoutPrivateUse(value: String): String {
        val out = StringBuilder(value.length)
        var i = 0
        while (i < value.length) {
            val cp = value.codePointAt(i)
            val private = cp in 0xE000..0xF8FF || cp in 0xF0000..0xFFFFD || cp in 0x100000..0x10FFFD
            if (!private) out.appendCodePoint(cp)
            i += Character.charCount(cp)
        }
        return out.toString()
    }

    /** `android.widget.Button` becomes `Button`; an unnamed class is `?`. */
    fun role(name: String?): String {
        val short = name?.substringAfterLast('.')?.trim().orEmpty()
        return if (short.isEmpty()) "?" else short
    }

    /** `com.spotify.music:id/chip` becomes `chip`, the part a person can match. */
    fun viewId(id: String?): String? {
        val short = id?.substringAfterLast("/")?.trim().orEmpty()
        return short.ifEmpty { null }
    }

    /**
     * Whether the trimmed tree keeps a node. What is on screen and can be read
     * or acted on: anything else is layout or invisible, and its children take
     * its place. A node with no drawable bounds is not on screen (a collapsed
     * row, a view behind another), so it is never offered as something to tap.
     */
    private fun kept(node: Node): Boolean {
        val box = node.box ?: return false
        if (box.empty) return false
        return node.password || node.clickable || node.editable || node.scrollable ||
            node.checkable || node.selected || node.focused ||
            label(node.text) != null || label(node.desc) != null
    }

    private class Builder(val size: IntSize, val nodes: ArrayList<LinkedHashMap<String, Any?>>) {
        var truncated = false

        fun window(index: Int, window: Window) {
            add(index, window.nodes, -1, 0)
        }

        private fun add(window: Int, list: List<Node>, parent: Int, depth: Int) {
            if (depth > MAX_DEPTH) {
                truncated = true
                return
            }
            for (node in list) {
                if (nodes.size >= MAX_NODES) {
                    truncated = true
                    return
                }
                if (!kept(node)) {
                    // Fold it: its children keep its parent.
                    add(window, node.children, parent, depth + 1)
                    continue
                }
                val index = nodes.size
                nodes.add(row(window, index, parent, node))
                add(window, node.children, index, depth + 1)
            }
        }

        private fun row(window: Int, index: Int, parent: Int, node: Node): LinkedHashMap<String, Any?> {
            val row = LinkedHashMap<String, Any?>()
            row["i"] = index
            // A ref names the element in this tree, for the Mac's tap. A new
            // tree replaces them, so an old ref cannot press what moved.
            row["ref"] = "e$index"
            if (parent >= 0) row["p"] = parent
            row["w"] = window
            row["role"] = role(node.role)
            // A password field says it is one and keeps its text on the phone.
            if (!node.password) {
                label(node.text)?.let { row["text"] = it }
                val desc = label(node.desc)
                if (desc != null && desc != row["text"]) row["desc"] = desc
            }
            viewId(node.viewId)?.let { row["id"] = it }
            val box = node.box
            if (box != null && !box.empty) {
                row["box"] = listOf(box.left, box.top, box.right, box.bottom)
                row["at"] = at(box)
            }
            if (node.clickable) row["click"] = true
            if (node.editable) row["edit"] = true
            if (node.scrollable) row["scroll"] = true
            if (node.checkable) row["check"] = node.checked
            if (node.selected) row["sel"] = true
            if (node.focused) row["focus"] = true
            if (!node.enabled) row["disabled"] = true
            if (node.password) row["pwd"] = true
            return row
        }

        /** The centre of the bounds as 0..1 of the window, rounded to 1e-3. */
        private fun at(box: Box): List<Double> {
            val w = if (size.w > 0) size.w.toDouble() else 1.0
            val h = if (size.h > 0) size.h.toDouble() else 1.0
            val x = ((box.left + box.right) / 2.0 / w).coerceIn(0.0, 1.0)
            val y = ((box.top + box.bottom) / 2.0 / h).coerceIn(0.0, 1.0)
            return listOf(round(x), round(y))
        }

        private fun round(value: Double): Double = Math.round(value * 1_000.0) / 1_000.0
    }
}

/** The shell side of `ui.tree`; null in a session that cannot read a tree. */
fun interface UiTreeSource {
    /** Reads [displayId]'s tree. Blocking: the session calls it off the reader thread. */
    fun dump(displayId: Int, size: IntSize): UiTree.Answer
}
