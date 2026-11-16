package app.contigua.server

/**
 * The accessibility tree of one stream's display, as the Mac's `ui_tree` tool
 * reads it (docs/PROTOCOL.md "UI tree", WIN-79, ISS-160).
 *
 * Pure: the shell side hands in what it read from UiAutomation and this decides
 * what a model sees. The tree is trimmed for a reader, not mirrored: a node
 * with no label and nothing to act on is folded into its children, classes and
 * view ids are shortened, defaults are omitted, and every on-screen node
 * carries the centre of its visible bounds as 0..1 of the display's input space
 * (the same coordinates TOUCH and `tap` take). A node whose box does not
 * intersect the display, that is not visible to the user, or whose visible part
 * is under 8×8 px is kept with `off: true` and no tap point, so a reader still
 * sees its text and knows to scroll. A password field never carries its text.
 *
 * The shape follows what accessibility-driven automation clients settled on:
 * a compact, actionable list beats a faithful XML tree (a layout node says
 * nothing a model can act on), the tap point spares the model the arithmetic
 * that goes wrong when a screenshot is scaled, and an empty tree says so
 * instead of reading as a blank screen. The phone sends no `ref` and no
 * `snapshot`: the Mac issues both, so a ref never crosses the wire.
 *
 * Each row carries `k`, its node's key in the display's [UiTreeKeys] table
 * (MCP-71), `heading` when the node is one (MCP-72), and `covered` when a node
 * drawn after it, or a window above it, holds its tap point (MCP-73).
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
        val visibleToUser: Boolean = true,
        /** Whether the node reports a range (`getRangeInfo()` non-null); false = indeterminate. */
        val hasRange: Boolean = true,
        val children: List<Node> = emptyList(),
        /**
         * The node's own child count, which [children] can fall short of when
         * the walk stops at [MAX_DEPTH]: the loading signal judges an empty
         * WebView by this, as the settle's check does (MCP-103).
         */
        val childCount: Int = children.size,
        /** `AccessibilityNodeInfo.isHeading` (MCP-72). */
        val heading: Boolean = false,
        /** `getDrawingOrder`: the order the node draws among its siblings (MCP-73). */
        val drawingOrder: Int = 0,
        /**
         * What [UiTreeKeys] keys the node by: its window id and source node id
         * on the phone. Null is a node with no identity, keyed fresh each read.
         */
        val identity: Any? = null,
    )

    /** A node's bounds in display pixels, origin at the display's top left. */
    data class Box(val left: Int, val top: Int, val right: Int, val bottom: Int) {
        val width: Int get() = right - left
        val height: Int get() = bottom - top
        val empty: Boolean get() = width <= 0 || height <= 0
    }

    /** One layer on the display: the app, or the keyboard or a system window over it. */
    data class Layer(
        val title: String?,
        val type: String,
        val focused: Boolean,
        val active: Boolean,
        val nodes: List<Node>,
        /** `AccessibilityWindowInfo.getLayer`: a higher one draws above (MCP-73). */
        val windowLayer: Int = 0,
        /** The window's bounds in display pixels, when known (MCP-73's `"window"`). */
        val bounds: Box? = null,
    )

    /** What a read produced: a tree, or the reason there is none. */
    sealed class Answer {
        /** [keys] is the display's key table (MCP-71); a fresh one when the reader keeps none. */
        data class Tree(val layers: List<Layer>, val keys: UiTreeKeys = UiTreeKeys()) : Answer()

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

    /** Less than this much visible area is a sliver, not a target (WIN-79 F9). */
    const val MIN_VISIBLE = 8

    /**
     * Builds the `ok: true` reply body for a read. `size` is the display's
     * input space — the pixel space `box` is in and TOUCH maps over — not the
     * stream's video size (F2). [keys] is the display's key table: a row's `k`
     * comes from it, so the same node keeps its `k` across reads (MCP-71).
     */
    fun reply(
        display: Int,
        size: IntSize,
        layers: List<Layer>,
        keys: UiTreeKeys = UiTreeKeys(),
    ): LinkedHashMap<String, Any?> {
        val out = LinkedHashMap<String, Any?>()
        val nodes = ArrayList<LinkedHashMap<String, Any?>>()
        val builder = Builder(size, nodes)
        layers.forEachIndexed { index, layer ->
            builder.layer(index, layer)
        }
        builder.key(keys)
        builder.cover(layers)
        out["ok"] = true
        // The display's own id, not a counter: virtual displays are numbered in
        // the sixties on current Android builds, which reads like a sequence
        // number when the field is called `display`.
        out["displayId"] = display
        // The space `box` is in, so a reader knows what the pixels mean (S2).
        out["size"] = listOf(size.w, size.h)
        out["truncated"] = builder.truncated
        out["layers"] = layers.mapIndexed { index, layer ->
            linkedMapOf<String, Any?>(
                "i" to index,
                "title" to layer.title,
                "type" to layer.type,
                "focused" to layer.focused,
                "active" to layer.active,
            )
        }
        out["nodes"] = nodes
        // MCP-103: the reply says the tree is still loading while any row has it.
        if (nodes.any { it["loading"] == true }) out["loading"] = true
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
     *
     * A node whose box is off the display, or that is not visible to the user,
     * is still kept when it has something to read: [Builder.row] marks it
     * `off: true` with no tap point rather than dropping the text (F9).
     */
    private fun kept(node: Node): Boolean {
        val box = node.box ?: return false
        if (box.empty) return false
        return node.password || node.clickable || node.editable || node.scrollable ||
            node.checkable || node.selected || node.focused ||
            label(node.text) != null || label(node.desc) != null ||
            loading(node)
    }

    /** A loading signal (MCP-103): kept and marked even with no label. */
    private fun loading(node: Node): Boolean =
        LoadingSignal.loading(node.role, node.visibleToUser, node.hasRange, node.childCount)

    /**
     * One step from a layer's root to a node: its drawing order among its
     * siblings and its index among them, folded nodes included.
     */
    private data class Step(val order: Int, val index: Int)

    /** What [Builder.cover] needs of a row: where it is, and whether it can cover. */
    private class Placed(
        val layer: Int,
        val path: List<Step>,
        val identity: Any?,
        /** The visible box, or null for an `off` row. */
        val box: Box?,
        /** Clickable or labelled (MCP-73): what can cover another row. */
        val readable: Boolean,
    )

    private class Builder(val size: IntSize, val nodes: ArrayList<LinkedHashMap<String, Any?>>) {
        var truncated = false
        private val placed = ArrayList<Placed>()

        fun layer(index: Int, layer: Layer) {
            add(index, layer.nodes, -1, 0, emptyList())
        }

        /** Gives every row its `k` from the display's table, in row order (MCP-71). */
        fun key(keys: UiTreeKeys) {
            val found = keys.read(placed.map { it.identity ?: Any() })
            nodes.forEachIndexed { index, row -> row["k"] = found[index] }
        }

        /**
         * Marks `covered` on each row whose tap point lies inside a readable
         * node drawn after it, naming the topmost (MCP-73). A window above with
         * no readable node at the point covers it as `"window"`.
         */
        fun cover(layers: List<Layer>) {
            for ((index, row) in placed.withIndex()) {
                val box = row.box ?: continue
                val x = (box.left + box.right) / 2.0
                val y = (box.top + box.bottom) / 2.0
                val over = coverOf(index, row, x, y, layers) ?: continue
                nodes[index]["covered"] = over
            }
        }

        private fun coverOf(target: Int, row: Placed, x: Double, y: Double, layers: List<Layer>): Any? {
            val below = layers[row.layer].windowLayer
            // A window above wins over anything in the row's own window: the
            // highest one that reaches the point names its topmost readable
            // node there, or itself.
            var topLayer: Int? = null
            for ((index, layer) in layers.withIndex()) {
                if (layer.windowLayer <= below) continue
                val reaches = layer.bounds?.let { inside(it, x, y) } == true ||
                    placed.any { it.layer == index && it.readable && it.box != null && inside(it.box, x, y) }
                if (reaches && (topLayer == null || layer.windowLayer > layers[topLayer].windowLayer)) {
                    topLayer = index
                }
            }
            if (topLayer != null) {
                val top = topmost(placed.indices.filter { other ->
                    val it = placed[other]
                    it.layer == topLayer && it.readable && it.box != null && inside(it.box, x, y)
                })
                return top?.let { nodes[it]["k"] } ?: "window"
            }
            val top = topmost(placed.indices.filter { other ->
                val it = placed[other]
                other != target && it.layer == row.layer && it.readable && it.box != null &&
                    inside(it.box, x, y) && drawnAfter(it.path, row.path)
            })
            return top?.let { nodes[it]["k"] }
        }

        /** The row that draws last of [rows], all in one window: a later branch, or a descendant. */
        private fun topmost(rows: List<Int>): Int? = rows.maxWithOrNull { a, b -> paint(placed[a].path, placed[b].path) }

        private fun paint(a: List<Step>, b: List<Step>): Int {
            for (i in 0 until minOf(a.size, b.size)) {
                if (a[i] != b[i]) {
                    return compareValuesBy(a[i], b[i], { it.order }, { it.index })
                }
            }
            return a.size.compareTo(b.size)
        }

        /**
         * Whether [over] draws after [under] in another branch: a later drawing
         * order where their paths part. An ancestor or a descendant never
         * covers: a button's own label is part of it.
         */
        private fun drawnAfter(over: List<Step>, under: List<Step>): Boolean {
            for (i in 0 until minOf(over.size, under.size)) {
                if (over[i] != under[i]) return over[i].order > under[i].order
            }
            return false
        }

        private fun inside(box: Box, x: Double, y: Double): Boolean =
            x >= box.left && x < box.right && y >= box.top && y < box.bottom

        private fun add(layer: Int, list: List<Node>, parent: Int, depth: Int, path: List<Step>) {
            if (depth > MAX_DEPTH) {
                truncated = true
                return
            }
            for ((position, node) in list.withIndex()) {
                if (nodes.size >= MAX_NODES) {
                    truncated = true
                    return
                }
                val here = path + Step(node.drawingOrder, position)
                if (!kept(node)) {
                    // Fold it: its children keep its parent.
                    add(layer, node.children, parent, depth + 1, here)
                    continue
                }
                val index = nodes.size
                val row = row(layer, index, parent, node)
                nodes.add(row)
                val visible = (row["box"] as? List<*>)?.takeIf { row["at"] != null }
                    ?.let { Box(it[0] as Int, it[1] as Int, it[2] as Int, it[3] as Int) }
                placed.add(Placed(
                    layer = layer,
                    path = here,
                    identity = node.identity,
                    box = visible,
                    readable = node.clickable || label(node.text) != null || label(node.desc) != null,
                ))
                add(layer, node.children, index, depth + 1, here)
            }
        }

        private fun row(layer: Int, index: Int, parent: Int, node: Node): LinkedHashMap<String, Any?> {
            val row = LinkedHashMap<String, Any?>()
            row["i"] = index
            // The display's key for the node, filled in by [key] (MCP-71).
            row["k"] = null
            // No `ref` here: the Mac issues refs from its own per-window read
            // counter, so a ref never crosses the wire (S1).
            if (parent >= 0) row["p"] = parent
            row["l"] = layer
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
                val clipped = clip(box)
                if (clipped == null) {
                    // No part of it is on the display (or the display has no
                    // size): keep the text, refuse a tap (F9).
                    row["off"] = true
                } else {
                    row["box"] = listOf(clipped.left, clipped.top, clipped.right, clipped.bottom)
                    if (!node.visibleToUser || clipped.width < MIN_VISIBLE || clipped.height < MIN_VISIBLE) {
                        row["off"] = true
                    } else {
                        row["at"] = at(clipped)
                    }
                }
            }
            if (node.clickable) row["click"] = true
            if (node.editable) row["edit"] = true
            if (node.scrollable) row["scroll"] = true
            if (node.checkable) row["check"] = node.checked
            if (node.selected) row["sel"] = true
            if (node.focused) row["focus"] = true
            if (!node.enabled) row["disabled"] = true
            if (node.password) row["pwd"] = true
            if (loading(node)) row["loading"] = true
            if (node.heading) row["heading"] = true
            return row
        }

        /** The part of [box] on the display, or null when none (F9). */
        private fun clip(box: Box): Box? {
            if (size.w <= 0 || size.h <= 0) return null
            val left = box.left.coerceIn(0, size.w)
            val top = box.top.coerceIn(0, size.h)
            val right = box.right.coerceIn(0, size.w)
            val bottom = box.bottom.coerceIn(0, size.h)
            val clipped = Box(left, top, right, bottom)
            return if (clipped.empty) null else clipped
        }

        /** The centre of the visible bounds as 0..1 of the input space, rounded to 1e-3. */
        private fun at(box: Box): List<Double> {
            val w = size.w.toDouble()
            val h = size.h.toDouble()
            val x = (box.left + box.right) / 2.0 / w
            val y = (box.top + box.bottom) / 2.0 / h
            return listOf(round(x), round(y))
        }

        private fun round(value: Double): Double = Math.round(value * 1_000.0) / 1_000.0
    }
}

/** The shell side of `ui.tree` and `ui.settle`; null in a session that cannot read a tree. */
fun interface UiTreeSource {
    /** Reads [displayId]'s tree. Blocking: the session calls it off the reader thread. */
    fun dump(displayId: Int, size: IntSize): UiTree.Answer

    /**
     * Watches [displayId] until it is quiet for [quietMs] with nothing loading,
     * or [timeoutMs] passes (docs/PROTOCOL.md "UI tree" item 7). [arrivedAt] is
     * the request's arrival on the session's clock (`SystemClock.uptimeMillis`
     * in the service): `waitedMs` and the deadline count from it. [owner] is
     * the session, so [cancel] ends only its own watch. Blocking: the session
     * calls it off the reader thread. A source that cannot listen to
     * accessibility events answers `not_available`.
     */
    fun settle(displayId: Int, quietMs: Long, timeoutMs: Long, arrivedAt: Long, owner: Any): SettleAnswer =
        SettleAnswer.Failure(UiCodes.NOT_AVAILABLE, "This phone cannot watch the display.")

    /** [owner]'s session ended: its watch stops listening and answers [SettleAnswer.Cancelled]. */
    fun cancel(owner: Any) {}
}

/** The closed failure codes of `ui.tree` and `ui.settle` (docs/PROTOCOL.md "UI tree"). */
object UiCodes {
    const val NO_WINDOW = "no_window"
    const val NO_DISPLAY = "no_display"
    const val NOT_AVAILABLE = "not_available"
    const val NO_A11Y = "no_a11y"
    const val BUSY = "busy"
    const val FAILED = "failed"

    /** Every code `ui.settle` may answer (item 7); `no_a11y` is `ui.tree`'s only. */
    val SETTLE = setOf(NO_WINDOW, NO_DISPLAY, NOT_AVAILABLE, BUSY, FAILED)
}
