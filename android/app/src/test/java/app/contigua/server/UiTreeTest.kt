package app.contigua.server

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * WIN-79/ISS-160: the accessibility tree the Mac's `ui_tree` tool reads. The
 * phone trims it for a reader — layout folded away, shortened names, defaults
 * omitted, tap points and refs computed, password text never sent — and says
 * when a tree is empty or cut.
 */
class UiTreeTest {

    private fun reply(
        windows: List<UiTree.Window>,
        size: IntSize = IntSize(1_000, 2_000),
    ): LinkedHashMap<String, Any?> = UiTree.reply(7, size, 3, windows)

    private fun nodes(body: Map<String, Any?>): List<Map<String, Any?>> =
        (body["nodes"] as? List<*>)?.filterIsInstance<Map<String, Any?>>().orEmpty()

    private fun windows(body: Map<String, Any?>): List<Map<String, Any?>> =
        (body["windows"] as? List<*>)?.filterIsInstance<Map<String, Any?>>().orEmpty()

    private fun window(vararg nodes: UiTree.Node, title: String? = "Calculator") =
        UiTree.Window(title = title, type = "app", focused = true, active = true, nodes = nodes.toList())

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
        children = children,
    )

    @Test
    fun aLayoutContainerIsFoldedAndItsChildrenKeepItsParent() {
        val tree = node(
            role = "android.widget.FrameLayout",
            children = listOf(node(text = "Continue", clickable = true)),
        )
        val rows = nodes(reply(listOf(window(tree))))
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
        val rows = nodes(reply(listOf(window(tree))))
        assertEquals(2, rows.size)
        assertEquals(0, rows[1]["p"])
    }

    @Test
    fun theCentreOfTheBoundsIsTheTapPoint() {
        // 100..500 across a 1000 px window: 0.3; 100..900 down a 2000 px one: 0.25.
        val tree = node(box = UiTree.Box(100, 100, 500, 900), clickable = true)
        val row = nodes(reply(listOf(window(tree))))[0]
        assertEquals(listOf(100, 100, 500, 900), row["box"])
        assertEquals(listOf(0.3, 0.25), row["at"])
    }

    @Test
    fun aPointOutsideTheWindowIsClamped() {
        val tree = node(box = UiTree.Box(900, 1_800, 1_200, 2_200), clickable = true)
        val row = nodes(reply(listOf(window(tree))))[0]
        assertEquals(listOf(1.0, 1.0), row["at"])
    }

    @Test
    fun aZeroSizedWindowDoesNotDivideByZero() {
        val tree = node(box = UiTree.Box(10, 10, 20, 20), clickable = true)
        val row = nodes(reply(listOf(window(tree)), size = IntSize(0, 0)))[0]
        assertEquals(listOf(1.0, 1.0), row["at"])
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
        val row = nodes(reply(listOf(window(tree))))[0]
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
        val rows = nodes(reply(listOf(window(plain, checked, disabled))))
        assertFalse(rows[0].containsKey("click"))
        assertFalse(rows[0].containsKey("disabled"))
        assertEquals(true, rows[1]["check"])
        assertEquals(true, rows[2]["disabled"])
    }

    @Test
    fun anUncheckedBoxSaysFalseNotNothing() {
        val row = nodes(reply(listOf(window(node(text = "Bluetooth", checkable = true)))))[0]
        assertEquals(false, row["check"])
    }

    @Test
    fun labelsAreCollapsedAndCut() {
        val long = "word ".repeat(100).trim()
        val rows = nodes(reply(listOf(window(
            node(text = "  two\n\nlines  "),
            node(text = long),
        ))))
        assertEquals("two lines", rows[0]["text"])
        assertEquals(UiTree.MAX_TEXT, (rows[1]["text"] as String).length)
    }

    @Test
    fun aDescriptionEqualToTheTextIsDropped() {
        val row = nodes(reply(listOf(window(node(text = "Send", desc = "Send")))))[0]
        assertEquals("Send", row["text"])
        assertNull(row["desc"])
    }

    @Test
    fun classesAndViewIdsAreShortened() {
        val row = nodes(reply(listOf(window(
            node(role = "android.widget.Button", text = "Save", viewId = "com.example:id/save"),
        ))))[0]
        assertEquals("Button", row["role"])
        assertEquals("save", row["id"])
    }

    @Test
    fun aNodeAlwaysCarriesItsRole() {
        val row = nodes(reply(listOf(window(node(role = "", clickable = true)))))[0]
        assertEquals("?", row["role"])
    }

    @Test
    fun aNodeWithNothingToActOnAndNoLabelIsNotSent() {
        val tree = node(role = "android.view.View")
        val body = reply(listOf(window(tree)))
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
        assertEquals(3, body["snapshot"])
    }

    @Test
    fun anIconGlyphIsNotAWord() {
        // A Material icon draws U+EF9E; the label beside it is the text.
        val row = nodes(reply(listOf(window(node(text = "\uEF9E Save")))))[0]
        assertEquals("Save", row["text"])
    }

    @Test
    fun aLabelOfOnlyGlyphsFoldsTheNodeAway() {
        // Nothing a person can read is left, so the node is layout.
        val body = reply(listOf(window(node(text = "\uEF9E\uEEE8"))))
        assertTrue(nodes(body).isEmpty())
    }

    @Test
    fun aSupplementaryPrivateUseGlyphIsDroppedToo() {
        // U+100123, a supplementary private use code point, as its UTF-16 pair.
        val row = nodes(reply(listOf(window(
            node(text = "\uDBC0\uDD23 Continue", clickable = true),
        ))))[0]
        assertEquals("Continue", row["text"])
    }

    @Test
    fun aLongTreeIsCutAtTheCapAndSaysSo() {
        val many = (0 until UiTree.MAX_NODES + 50).map { node(text = "Row $it") }
        val body = reply(listOf(window(*many.toTypedArray())))
        assertEquals(UiTree.MAX_NODES, nodes(body).size)
        assertEquals(true, body["truncated"])
    }

    @Test
    fun aTreeUnderTheCapIsNotMarkedTruncated() {
        val body = reply(listOf(window(node(text = "one"), node(text = "two"))))
        assertEquals(false, body["truncated"])
    }

    @Test
    fun everyWindowIsNumberedAndNamed() {
        val body = reply(listOf(
            window(node(text = "app"), title = "Calculator"),
            UiTree.Window("Keyboard", "ime", focused = false, active = false, nodes = listOf(node(text = "q"))),
        ))
        val rows = windows(body)
        assertEquals(2, rows.size)
        assertEquals("Calculator", rows[0]["title"])
        assertEquals("ime", rows[1]["type"])
        assertEquals(1, nodes(body)[1]["w"])
    }

    @Test
    fun everyNodeCarriesARefIntoThisTree() {
        val rows = nodes(reply(listOf(window(node(text = "one"), node(text = "two")))))
        assertEquals(listOf("e0", "e1"), rows.map { it["ref"] })
    }

    @Test
    fun anInvisibleNodeIsNotOffered() {
        // No drawable bounds: a collapsed row or a view behind another. A tap
        // there would land on whatever is really at that point.
        val gone = node(text = "Gone", box = UiTree.Box(0, 0, 0, 0))
        val body = reply(listOf(window(gone)))
        assertTrue(nodes(body).isEmpty())
    }

    @Test
    fun anInvisibleContainerStillFoldsItsChildrenUp() {
        val row = node(
            role = "android.widget.FrameLayout",
            box = UiTree.Box(0, 0, 0, 0),
            children = listOf(node(text = "Visible", clickable = true)),
        )
        val rows = nodes(reply(listOf(window(row))))
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
