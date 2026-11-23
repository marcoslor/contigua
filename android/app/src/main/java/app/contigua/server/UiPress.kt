package app.contigua.server

/**
 * `ui.press` (docs/PROTOCOL.md "UI tree" item 8, MCP-86, MCP-89, MCP-108):
 * the pure decision from a node of the latest read, refreshed now, to a press
 * at its bounds' centre or a closed refusal code.
 *
 * The checks run in a fixed order, the first that fails answers: `gone` (no
 * such key in the latest read, or `refresh()` failed), `not_visible`,
 * `off_screen` (item 2's `off` rule on the bounds now), `changed` (the label
 * read now is not the `expect` the Mac sent, #188), `covered` (MCP-89). Only a
 * [Decision.Press] injects anything; the session does that.
 */
object UiPress {

    /** A node from the latest read of the display: refreshed, then read. */
    interface Target {
        /** `AccessibilityNodeInfo.refresh()`: false when the node no longer exists. */
        fun refresh(): Boolean

        /** The node as it reads after [refresh], its subtree included (for its label). */
        fun read(): UiTree.Node
    }

    sealed class Decision {
        /** Press at ([x], [y]) display pixels; [reply] is the `ok: true` body. */
        data class Press(val x: Int, val y: Int, val reply: LinkedHashMap<String, Any?>) : Decision()

        /** Press nothing; [reply] is the `ok: false` body with [code]. */
        data class Refuse(val code: String, val reply: LinkedHashMap<String, Any?>) : Decision()
    }

    const val GONE = "gone"
    const val NOT_VISIBLE = "not_visible"
    const val OFF_SCREEN = "off_screen"
    const val COVERED = "covered"
    const val CHANGED = "changed"

    /** The longest hold item 8 allows. */
    const val MAX_HOLD_MS = 3_000L

    /**
     * Decides a press of [target] (null: the key names nothing in the latest
     * read) on a display of [size]. [expect] is the label the Mac last answered
     * for the key, absent when it never answered one. [cover] names what covers
     * the node's centre now — a key, `"window"`, or null — as `covered` does.
     */
    fun decide(target: Target?, size: IntSize, expect: String?, cover: (UiTree.Node) -> Any?): Decision {
        if (target == null || !target.refresh()) return refuse(GONE, "That element is no longer on the screen.")
        val node = target.read()
        if (!node.visibleToUser) return refuse(NOT_VISIBLE, "That element is not visible to the user.")
        val box = node.box?.let { clip(it, size) }
            ?: return refuse(OFF_SCREEN, "That element is off screen.")
        val now = label(node)
        if (expect != null && now != expect) {
            return refuse(CHANGED, "That element now reads differently.").also { it.reply["now"] = now }
        }
        cover(node)?.let { by ->
            return refuse(COVERED, "Something is drawn over that element.").also { it.reply["coveredBy"] = by }
        }
        val x = (box.left + box.right) / 2
        val y = (box.top + box.bottom) / 2
        val reply = linkedMapOf<String, Any?>(
            "ok" to true,
            "box" to listOf(box.left, box.top, box.right, box.bottom),
            "at" to listOf(round(x.toDouble() / size.w), round(y.toDouble() / size.h)),
            "role" to UiTree.role(node.role),
        )
        // As a row: a password node says what it is, never what it holds.
        if (!node.password) {
            UiTree.label(node.text)?.let { reply["text"] = it }
            UiTree.label(node.desc)?.let { reply["desc"] = it }
        }
        return Decision.Press(x, y, reply)
    }

    /**
     * The label `expect` is compared with (item 8): the node's text, else its
     * description, else the first node under it with either, depth first, each
     * trimmed as a row's label is; `""` when none has one. A password node's
     * text is never a label, as it is never a row's. An editable node's text is
     * its value, not what it is (#188): its label is its description, else its
     * view id as a row shortens it (a password field's, its view id alone, as
     * its row carries no desc), and under another node it and its subtree
     * give none.
     */
    fun label(node: UiTree.Node): String {
        // A password field's row carries neither text nor desc (item 2): its id alone.
        if (node.editable && node.password) return UiTree.viewId(node.viewId) ?: ""
        if (node.editable) return UiTree.label(node.desc) ?: UiTree.viewId(node.viewId) ?: ""
        return find(node, 0) ?: ""
    }

    private fun find(node: UiTree.Node, depth: Int): String? {
        if (depth > UiTree.MAX_DEPTH) return null
        if (depth > 0 && node.editable) return null
        if (!node.password) {
            (UiTree.label(node.text) ?: UiTree.label(node.desc))?.let { return it }
        }
        for (child in node.children) find(child, depth + 1)?.let { return it }
        return null
    }

    /** The part of [box] on the display when at least 8×8 px of it is, else null (item 2, F9). */
    private fun clip(box: UiTree.Box, size: IntSize): UiTree.Box? {
        if (size.w <= 0 || size.h <= 0 || box.empty) return null
        val clipped = UiTree.Box(
            box.left.coerceIn(0, size.w), box.top.coerceIn(0, size.h),
            box.right.coerceIn(0, size.w), box.bottom.coerceIn(0, size.h),
        )
        return clipped.takeIf { it.width >= UiTree.MIN_VISIBLE && it.height >= UiTree.MIN_VISIBLE }
    }

    private fun refuse(code: String, sentence: String) = Decision.Refuse(code, UiTree.failure(code, sentence))

    private fun round(value: Double): Double = Math.round(value * 1_000.0) / 1_000.0
}

/**
 * The shell side of `ui.press`: a [UiTreeSource] that can also press. Blocking:
 * the session calls it off the reader thread, under the one-`ui.*` rule.
 */
interface UiPressSource {
    /** Resolves [k] against [displayId]'s latest read and decides the press (item 8). */
    fun press(displayId: Int, size: IntSize, k: Int, expect: String?): UiPress.Decision
}
