package app.contigua.server

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * WIN-79/ISS-160: the accessibility tree the Mac's `ui_tree` tool reads. The
 * phone trims it for a reader — layout folded away, shortened names, defaults
 * omitted, tap points computed, password text never sent — and says when a
 * tree is empty or cut. The phone sends no `ref` and no `snapshot`: the Mac
 * issues both (S1), so a ref never crosses the wire.
 */
class UiTreeTest {

    private fun reply(
        layers: List<UiTree.Layer>,
        size: IntSize = IntSize(1_000, 2_000),
    ): LinkedHashMap<String, Any?> = UiTree.reply(7, size, layers)

    private fun nodes(body: Map<String, Any?>): List<Map<String, Any?>> =
        (body["nodes"] as? List<*>)?.filterIsInstance<Map<String, Any?>>().orEmpty()

    private fun layers(body: Map<String, Any?>): List<Map<String, Any?>> =
        (body["layers"] as? List<*>)?.filterIsInstance<Map<String, Any?>>().orEmpty()

    private fun layer(vararg nodes: UiTree.Node, title: String? = "Calculator") =
        UiTree.Layer(title = title, type = "app", focused = true, active = true, nodes = nodes.toList())

    private fun node(
        role: String = "android.widget.TextView",
        text: String? = null,
        desc: String? = null,
        viewId: String? = null,
        box: UiTree.Box = UiTree.Box(0, 0, 100, 100),
        children: List<UiTree.Node> = emptyList(),
        clickable: Boolean = false,
        editable: Boolean = false,
        scrollable: Boolean = false,
        checkable: Boolean = false,
        checked: Boolean = false,
        selected: Boolean = false,
        focused: Boolean = false,
        enabled: Boolean = true,
        password: Boolean = false,
        visibleToUser: Boolean = true,
    ): UiTree.Node = UiTree.Node(
        role = role,
        text = text,
        desc = desc,
        viewId = viewId,
        box = box,
        clickable = clickable,
        editable = editable,
        scrollable = scrollable,
        checkable = checkable,
        checked = checked,
        selected = selected,
        focused = focused,
        enabled = enabled,
        password = password,
        visibleToUser = visibleToUser,
        children = children,
    )

    @Test
    fun aLayoutContainerIsFoldedAndItsChildrenKeepItsParent() {
        val tree = node(
            role = "android.widget.FrameLayout",
            children = listOf(node(text = "Continue", clickable = true)),
        )
        val rows = nodes(reply(listOf(layer(tree))))
        assertEquals(1, rows.size)
        assertEquals("Continue", rows[0]["text"])
        // The container was dropped, so the button has no parent row.
        assertNull(rows[0]["p"])
    }

    @Test
    fun aKeptContainerIsTheChildsParent() {
        val tree = node(
            role = "android.widget.LinearLayout",
            text = "Settings",
            children = listOf(node(text = "Wi-Fi", clickable = true)),
        )
        val rows = nodes(reply(listOf(layer(tree))))
        assertEquals(2, rows.size)
        assertEquals(0, rows[1]["p"])
    }

    @Test
    fun theCentreOfTheBoundsIsTheTapPoint() {
        // 100..500 across a 1000 px display: 0.3; 100..900 down a 2000 px one: 0.25.
        val tree = node(box = UiTree.Box(100, 100, 500, 900), clickable = true)
        val row = nodes(reply(listOf(layer(tree))))[0]
        assertEquals(listOf(100, 100, 500, 900), row["box"])
        assertEquals(listOf(0.3, 0.25), row["at"])
    }

    @Test
    fun WIN79_nodeStraddlingTheEdgeTapsItsVisiblePart() {
        // The box runs past the right and bottom edges: `box` is clipped to the
        // display and `at` is the centre of the visible part, not a clamped
        // outside point (F9).
        val tree = node(box = UiTree.Box(900, 1_800, 1_200, 2_200), clickable = true)
        val row = nodes(reply(listOf(layer(tree))))[0]
        assertEquals(listOf(900, 1_800, 1_000, 2_000), row["box"])
        assertEquals(listOf(0.95, 0.95), row["at"])
    }

    @Test
    fun WIN79_nodeBelowTheDisplayIsOff() {
        // Entirely below the display: kept with `off`, no tap point (F9).
        val tree = node(text = "Checkout", box = UiTree.Box(0, 2_500, 100, 2_600), clickable = true)
        val row = nodes(reply(listOf(layer(tree))))[0]
        assertEquals(true, row["off"])
        assertFalse(row.containsKey("at"))
        assertFalse(row.containsKey("box"))
    }

    @Test
    fun WIN79_invisibleNodeIsOff() {
        // Not visible to the user: kept with `off`, no tap point (F9).
        val tree = node(text = "Behind", box = UiTree.Box(100, 100, 500, 900), clickable = true, visibleToUser = false)
        val row = nodes(reply(listOf(layer(tree))))[0]
        assertEquals(true, row["off"])
        assertFalse(row.containsKey("at"))
    }

    @Test
    fun WIN79_sliverIsOff() {
        // A 2 px sliver at the viewport edge is not a target (F9).
        val tree = node(text = "Sliver", box = UiTree.Box(0, 747, 1_104, 749), clickable = true)
        val body = reply(listOf(layer(tree)), size = IntSize(1_104, 2_560))
        val row = nodes(body)[0]
        assertEquals(true, row["off"])
        assertFalse(row.containsKey("at"))
        assertEquals(listOf(0, 747, 1_104, 749), row["box"])
    }

    @Test
    fun aZeroSizedDisplayDoesNotDivideByZero() {
        // A display with no size maps nothing: the node is off, never a bogus
        // point from a division by zero.
        val tree = node(box = UiTree.Box(10, 10, 20, 20), clickable = true)
        val row = nodes(reply(listOf(layer(tree)), size = IntSize(0, 0)))[0]
        assertEquals(true, row["off"])
        assertFalse(row.containsKey("at"))
    }

    @Test
    fun aPasswordFieldKeepsNoTextAtAll() {
        val tree = node(
            role = "android.widget.EditText",
            text = "hunter2",
            desc = "Password",
            password = true,
            editable = true,
        )
        val row = nodes(reply(listOf(layer(tree))))[0]
        assertNull(row["text"])
        assertNull(row["desc"])
        assertEquals(true, row["pwd"])
        assertEquals(true, row["edit"])
    }

    @Test
    fun defaultsAreOmittedAndOnlyRealStatesAreKept() {
        val plain = node(text = "Just a label")
        val checked = node(text = "Wi-Fi", checkable = true, checked = true)
        val disabled = node(text = "Unavailable", enabled = false)
        val rows = nodes(reply(listOf(layer(plain, checked, disabled))))
        assertFalse(rows[0].containsKey("click"))
        assertFalse(rows[0].containsKey("disabled"))
        assertEquals(true, rows[1]["check"])
        assertEquals(true, rows[2]["disabled"])
    }

    @Test
    fun anUncheckedBoxSaysFalseNotNothing() {
        val row = nodes(reply(listOf(layer(node(text = "Bluetooth", checkable = true)))))[0]
        assertEquals(false, row["check"])
    }

    @Test
    fun labelsAreCollapsedAndCut() {
        val long = "word ".repeat(100).trim()
        val rows = nodes(reply(listOf(layer(
            node(text = "  two\n\nlines  "),
            node(text = long),
        ))))
        assertEquals("two lines", rows[0]["text"])
        assertEquals(UiTree.MAX_TEXT, (rows[1]["text"] as String).length)
    }

    @Test
    fun aDescriptionEqualToTheTextIsDropped() {
        val row = nodes(reply(listOf(layer(node(text = "Send", desc = "Send")))))[0]
        assertEquals("Send", row["text"])
        assertNull(row["desc"])
    }

    @Test
    fun classesAndViewIdsAreShortened() {
        val row = nodes(reply(listOf(layer(
            node(role = "android.widget.Button", text = "Save", viewId = "com.example:id/save"),
        ))))[0]
        assertEquals("Button", row["role"])
        assertEquals("save", row["id"])
    }

    @Test
    fun aNodeAlwaysCarriesItsRole() {
        val row = nodes(reply(listOf(layer(node(role = "", clickable = true)))))[0]
        assertEquals("?", row["role"])
    }

    @Test
    fun aNodeWithNothingToActOnAndNoLabelIsNotSent() {
        val tree = node(role = "android.view.View")
        val body = reply(listOf(layer(tree)))
        assertTrue(nodes(body).isEmpty())
        assertTrue(body.containsKey("note"))
    }

    @Test
    fun anEmptyTreeSaysWhatHappened() {
        val body = reply(emptyList())
        assertTrue(nodes(body).isEmpty())
        assertTrue((body["note"] as String).isNotEmpty())
        assertEquals(true, body["ok"])
        assertEquals(7, body["displayId"])
        // S2: the answer names the pixel space `box` is in.
        assertEquals(listOf(1_000, 2_000), body["size"])
    }

    @Test
    fun anIconGlyphIsNotAWord() {
        // A Material icon draws U+EF9E; the label beside it is the text.
        val row = nodes(reply(listOf(layer(node(text = "\uEF9E Save")))))[0]
        assertEquals("Save", row["text"])
    }

    @Test
    fun aLabelOfOnlyGlyphsFoldsTheNodeAway() {
        // Nothing a person can read is left, so the node is layout.
        val body = reply(listOf(layer(node(text = "\uEF9E\uEEE8"))))
        assertTrue(nodes(body).isEmpty())
    }

    @Test
    fun aSupplementaryPrivateUseGlyphIsDroppedToo() {
        // U+100123, a supplementary private use code point, as its UTF-16 pair.
        val row = nodes(reply(listOf(layer(
            node(text = "\uDBC0\uDD23 Continue", clickable = true),
        ))))[0]
        assertEquals("Continue", row["text"])
    }

    @Test
    fun aLongTreeIsCutAtTheCapAndSaysSo() {
        val many = (0 until UiTree.MAX_NODES + 50).map { node(text = "Row $it") }
        val body = reply(listOf(layer(*many.toTypedArray())))
        assertEquals(UiTree.MAX_NODES, nodes(body).size)
        assertEquals(true, body["truncated"])
    }

    @Test
    fun aTreeUnderTheCapIsNotMarkedTruncated() {
        val body = reply(listOf(layer(node(text = "one"), node(text = "two"))))
        assertEquals(false, body["truncated"])
    }

    @Test
    fun everyLayerIsNumberedAndNamed() {
        val body = reply(listOf(
            layer(node(text = "app"), title = "Calculator"),
            UiTree.Layer("Keyboard", "ime", focused = false, active = false, nodes = listOf(node(text = "q"))),
        ))
        val rows = layers(body)
        assertEquals(2, rows.size)
        assertEquals("Calculator", rows[0]["title"])
        assertEquals("ime", rows[1]["type"])
        // S3: the per-row index is `l` (layer), never `w` (window).
        assertEquals(1, nodes(body)[1]["l"])
        assertFalse(nodes(body)[1].containsKey("w"))
    }

    @Test
    fun anInvisibleNodeIsNotOffered() {
        // No drawable bounds: a collapsed row or a view behind another. A tap
        // there would land on whatever is really at that point.
        val gone = node(text = "Gone", box = UiTree.Box(0, 0, 0, 0))
        val body = reply(listOf(layer(gone)))
        assertTrue(nodes(body).isEmpty())
    }

    @Test
    fun anInvisibleContainerStillFoldsItsChildrenUp() {
        val row = node(
            role = "android.widget.FrameLayout",
            box = UiTree.Box(0, 0, 0, 0),
            children = listOf(node(text = "Visible", clickable = true)),
        )
        val rows = nodes(reply(listOf(layer(row))))
        assertEquals(1, rows.size)
        assertEquals("Visible", rows[0]["text"])
    }

    @Test
    fun aFailureCarriesAClosedCodeAndASentence() {
        val body = UiTree.failure("no_a11y", "This phone cannot read an accessibility tree right now.")
        assertEquals(false, body["ok"])
        assertEquals("no_a11y", body["code"])
        assertTrue((body["message"] as String).isNotEmpty())
    }
}
