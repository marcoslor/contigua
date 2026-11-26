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
        offscreen: Boolean = false,
    ): LinkedHashMap<String, Any?> = UiTree.reply(7, size, layers, offscreen = offscreen)

    private fun nodes(body: Map<String, Any?>): List<Map<String, Any?>> =
        (body["nodes"] as? List<*>)?.filterIsInstance<Map<String, Any?>>().orEmpty()

    private fun layers(body: Map<String, Any?>): List<Map<String, Any?>> =
        (body["layers"] as? List<*>)?.filterIsInstance<Map<String, Any?>>().orEmpty()

    private fun layer(vararg nodes: UiTree.Node, title: String? = "Calculator") =
        UiTree.Layer(title = title, type = "app", focused = true, nodes = nodes.toList())

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
        hasRange: Boolean = true,
        sized: Boolean = !box.empty,
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
        hasRange = hasRange,
        children = children,
        sized = sized,
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
        // Entirely below the display: with `offscreen: true`, kept with `off`, no tap point (F9).
        val tree = node(text = "Checkout", box = UiTree.Box(0, 2_500, 100, 2_600), clickable = true)
        val row = nodes(reply(listOf(layer(tree)), offscreen = true))[0]
        assertEquals(true, row["off"])
        assertFalse(row.containsKey("at"))
        assertFalse(row.containsKey("box"))
    }

    @Test
    fun WIN79_invisibleNodeIsOff() {
        // Not visible to the user: with `offscreen: true`, kept with `off`, no tap point (F9).
        val tree = node(text = "Behind", box = UiTree.Box(100, 100, 500, 900), clickable = true, visibleToUser = false)
        val row = nodes(reply(listOf(layer(tree)), offscreen = true))[0]
        assertEquals(true, row["off"])
        assertFalse(row.containsKey("at"))
    }

    @Test
    fun WIN79_sliverIsOff() {
        // A 2 px sliver at the viewport edge is not a target (F9).
        val tree = node(text = "Sliver", box = UiTree.Box(0, 747, 1_104, 749), clickable = true)
        val body = reply(listOf(layer(tree)), size = IntSize(1_104, 2_560), offscreen = true)
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
        val row = nodes(reply(listOf(layer(tree)), size = IntSize(0, 0), offscreen = true))[0]
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
            UiTree.Layer("Keyboard", "ime", focused = false, nodes = listOf(node(text = "q"))),
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

    @Test
    fun testALoadingNodeIsKeptAndMarked() { // [MCP-103]
        // An unlabelled indeterminate ProgressBar is layout by the ordinary rule,
        // but a loading signal is kept and marked, and the reply says so.
        val spinner = node(
            role = "android.widget.ProgressBar",
            box = UiTree.Box(0, 0, 108, 108),
            hasRange = false,
        )
        val body = reply(listOf(layer(spinner)))
        val rows = nodes(body)
        assertEquals(1, rows.size)
        assertEquals(true, rows[0]["loading"])
        assertNull(rows[0]["text"])
        assertEquals(true, body["loading"])
    }

    @Test
    fun testATreeWithNoLoadingSignalCarriesNoLoadingKey() { // [MCP-103]
        val body = reply(listOf(layer(node(text = "Hello", clickable = true))))
        assertFalse(body.containsKey("loading"))
    }

    @Test
    fun testAWebViewCutByTheDepthCapIsNotLoading() { // [MCP-103]
        // A WebView at the depth cap keeps its child count but none of its
        // children: the tree judges "empty" by the count, as the check does.
        val web = UiTree.Node(
            role = "android.webkit.WebView", box = UiTree.Box(0, 0, 100, 100),
            children = emptyList(), childCount = 3,
        )
        val body = reply(listOf(layer(web)))
        assertFalse(body.containsKey("loading"))
        assertTrue(nodes(body).none { it["loading"] == true })
        // An uncut empty WebView is still loading.
        val empty = UiTree.Node(role = "android.webkit.WebView", box = UiTree.Box(0, 0, 100, 100))
        assertEquals(true, reply(listOf(layer(empty)))["loading"])
    }

    // MARK: B2: keys, heading, covered (docs/PROTOCOL.md "UI tree" item 9)

    @Test
    fun testEveryRowCarriesItsKeyAcrossReads() { // [MCP-71]
        val keys = UiTreeKeys()
        fun read(vararg ids: String) = nodes(UiTree.reply(7, IntSize(1_000, 2_000), listOf(layer(
            *ids.map { UiTree.Node(role = "Button", text = it, box = UiTree.Box(0, 0, 100, 100), clickable = true, identity = it) }
                .toTypedArray(),
        )), keys))
        assertEquals(listOf(1, 2), read("A", "B").map { it["k"] })
        val second = read("B", "C")
        assertEquals(listOf(2, 3), second.map { it["k"] })
        assertEquals(listOf("B", "C"), second.map { it["text"] })
    }

    @Test
    fun testAHeadingIsMarked() { // [MCP-72]
        val heading = UiTree.Node(role = "TextView", text = "Alarms", box = UiTree.Box(0, 0, 100, 100), heading = true)
        val plain = UiTree.Node(role = "TextView", text = "7:00", box = UiTree.Box(0, 100, 100, 200))
        val rows = nodes(reply(listOf(layer(heading, plain))))
        assertEquals(true, rows[0]["heading"])
        assertFalse(rows[1].containsKey("heading"))
    }

    private fun banner(closeBox: UiTree.Box): List<Map<String, Any?>> {
        val link = UiTree.Node(
            role = "TextView", text = "Terms", clickable = true, drawingOrder = 1,
            box = UiTree.Box(0, 2_200, 1_080, 2_300),
        )
        val close = UiTree.Node(
            role = "ImageButton", desc = "Close", clickable = true, drawingOrder = 2, box = closeBox,
        )
        val root = UiTree.Node(
            role = "FrameLayout", box = UiTree.Box(0, 0, 1_080, 2_400),
            children = listOf(
                UiTree.Node(role = "LinearLayout", box = UiTree.Box(0, 0, 1_080, 2_400), drawingOrder = 1, children = listOf(link)),
                UiTree.Node(role = "FrameLayout", box = UiTree.Box(0, 2_100, 1_080, 2_400), drawingOrder = 2, children = listOf(close)),
            ),
        )
        return nodes(reply(listOf(layer(root)), IntSize(1_080, 2_400)))
    }

    @Test
    fun testAPointUnderALaterSiblingIsCovered() { // [MCP-73]
        // The close button sits at the right end: the link's centre is clear.
        val clear = banner(UiTree.Box(900, 2_180, 1_080, 2_320))
        val link = clear.first { it["text"] == "Terms" }
        assertEquals(listOf(0.5, 0.938), link["at"]) // 2250 / 2400 = 0.9375
        assertFalse(link.containsKey("covered"))
        // The banner spans the width: the link is covered by it, and not the reverse.
        val covered = banner(UiTree.Box(0, 2_180, 1_080, 2_320))
        val under = covered.first { it["text"] == "Terms" }
        val over = covered.first { it["desc"] == "Close" }
        assertEquals(over["k"], under["covered"])
        assertFalse(over.containsKey("covered"))
    }

    @Test
    fun testAWindowAboveCoversTheNode() { // [MCP-73]
        val button = UiTree.Node(role = "Button", text = "Pay", clickable = true, box = UiTree.Box(100, 900, 900, 1_100))
        val app = UiTree.Layer("Shop", "app", false, listOf(button), windowLayer = 1)
        val blank = UiTree.Node(role = "FrameLayout", box = UiTree.Box(0, 0, 1_000, 2_000))
        val overlay = UiTree.Layer(null, "overlay", true, listOf(blank), windowLayer = 5,
            bounds = UiTree.Box(0, 0, 1_000, 2_000))
        val rows = nodes(reply(listOf(overlay, app)))
        assertEquals("window", rows.single { it["text"] == "Pay" }["covered"])
        // A readable node of the window above is named by its key instead.
        val ok = UiTree.Node(role = "Button", text = "OK", clickable = true, box = UiTree.Box(0, 800, 1_000, 1_200))
        val dialog = UiTree.Layer(null, "system", true, listOf(ok), windowLayer = 5,
            bounds = UiTree.Box(0, 0, 1_000, 2_000))
        val both = nodes(reply(listOf(dialog, app)))
        assertEquals(both.single { it["text"] == "OK" }["k"], both.single { it["text"] == "Pay" }["covered"])
        assertFalse(both.single { it["text"] == "OK" }.containsKey("covered"))
        // A window above that does not reach the point covers nothing.
        val strip = UiTree.Layer(null, "system", false, emptyList(), windowLayer = 5,
            bounds = UiTree.Box(0, 0, 1_000, 100))
        assertFalse(nodes(reply(listOf(strip, app))).single().containsKey("covered"))
    }

    @Test
    fun testANonClickableSiblingLabelDoesNotCoverAnEditText() { // [MCP-73]
        // A search field with a rotating placeholder drawn over its centre in
        // the same FrameLayout: the TextView takes no touch, so Android lets
        // the press through and the field is not covered (a food app's search box).
        val field = UiTree.Node(
            role = "android.widget.EditText", text = "Search", editable = true, drawingOrder = 1,
            box = UiTree.Box(0, 100, 1_000, 200),
        )
        val placeholder = UiTree.Node(
            role = "android.widget.TextView", text = "Search products", drawingOrder = 2,
            box = UiTree.Box(0, 100, 1_000, 200),
        )
        val root = UiTree.Node(
            role = "android.widget.FrameLayout", box = UiTree.Box(0, 0, 1_000, 2_000),
            children = listOf(field, placeholder),
        )
        val rows = nodes(reply(listOf(layer(root))))
        val edit = rows.single { it["edit"] == true }
        assertFalse("a non-clickable label covered the field", edit.containsKey("covered"))
        // A later clickable sibling at the same point still covers it: a
        // scrim or a button intercepts the touch.
        val scrim = UiTree.Node(
            role = "android.widget.FrameLayout", clickable = true, drawingOrder = 2,
            box = UiTree.Box(0, 100, 1_000, 200),
        )
        val over = nodes(reply(listOf(layer(root.copy(children = listOf(field, scrim))))))
        assertEquals(over.single { it["click"] == true }["k"], over.single { it["edit"] == true }["covered"])
    }

    @Test
    fun testAChildIsNotCoveredByItsOwnParent() { // [MCP-73]
        val label = UiTree.Node(role = "TextView", text = "Send", drawingOrder = 3, box = UiTree.Box(100, 100, 300, 200))
        val button = UiTree.Node(
            role = "Button", desc = "Send message", clickable = true, drawingOrder = 1,
            box = UiTree.Box(100, 100, 300, 200), children = listOf(label),
        )
        val rows = nodes(reply(listOf(layer(button))))
        assertEquals(2, rows.size)
        assertTrue(rows.none { it.containsKey("covered") })
    }

    @Test
    fun testAFieldKeepsItsDescWhenItEqualsItsText() { // [MCP-86]
        // A field's desc is what it is, its text only what it holds now: the
        // row keeps the desc even when the two read the same.
        val body = reply(listOf(layer(
            node(role = "android.widget.EditText", text = "Search", desc = "Search", editable = true),
            node(role = "android.widget.Button", text = "Go", desc = "Go", clickable = true),
        )))
        val rows = nodes(body)
        assertEquals("Search", rows[0]["text"])
        assertEquals("Search", rows[0]["desc"])
        assertEquals("Go", rows[1]["text"])
        assertEquals(null, rows[1]["desc"])
    }

    // MARK: B6, the tree says what it does not show (MCP-104…106)

    @Test
    fun testAShownHintIsNotText() { // [MCP-104]
        val empty = UiTree.Node(role = "android.widget.EditText", text = "Search products",
            hintText = "Search products", showingHint = true, box = UiTree.Box(0, 0, 1_000, 100), editable = true)
        val row = nodes(reply(listOf(layer(empty)))).single()
        assertEquals(true, row["hint"])
        assertEquals("Search products", row["hintText"])
        assertFalse(row.containsKey("text"))
        val filled = UiTree.Node(role = "android.widget.EditText", text = "milk",
            hintText = "Search products", showingHint = false, box = UiTree.Box(0, 0, 1_000, 100), editable = true)
        val milk = nodes(reply(listOf(layer(filled)))).single()
        assertEquals("milk", milk["text"])
        assertFalse(milk.containsKey("hint"))
        assertFalse(milk.containsKey("hintText"))
    }

    @Test
    fun testOnlyTheActiveLayersFocusIsSent() { // [MCP-105]
        fun field(text: String) = node(role = "android.widget.EditText", text = text, editable = true, focused = true)
        val app = UiTree.Layer(title = "Shop", type = "app", focused = false, nodes = listOf(field("milk")))
        val dialog = UiTree.Layer(title = "Rename", type = "app", focused = true, nodes = listOf(field("list")))
        val body = reply(listOf(app, dialog))
        val rows = nodes(body)
        assertEquals(listOf(null, true), rows.map { it["focus"] })
        assertEquals("list", rows.single { it["focus"] == true }["text"])
        val sent = layers(body)
        assertEquals(listOf(0, 1), sent.map { it["i"] })
        assertFalse(sent[0].containsKey("active"))
        assertEquals(true, sent[1]["active"])
        assertTrue(sent.none { it.containsKey("focused") })
        // No layer has input focus: no `active`, no `focus`.
        val none = reply(listOf(app, dialog.copy(focused = false)))
        assertTrue(layers(none).none { it.containsKey("active") || it.containsKey("focused") })
        assertTrue(nodes(none).none { it.containsKey("focus") })
    }

    /** A list on a 1000×2000 display: [above] rows over it, [on] on it, [below] under it, 400 px each. */
    private fun list(above: Int, on: Int, below: Int): UiTree.Node {
        val rows = ArrayList<UiTree.Node>()
        var n = 1
        for (i in above downTo 1) rows += node(text = "Item ${n++}", clickable = true,
            box = UiTree.Box(0, -400 * i, 1_000, -400 * i + 400))
        for (i in 0 until on) rows += node(text = "Item ${n++}", clickable = true,
            box = UiTree.Box(0, 400 * i, 1_000, 400 * i + 400))
        for (i in 0 until below) rows += node(text = "Item ${n++}", clickable = true,
            box = UiTree.Box(0, 2_000 + 400 * i, 1_000, 2_400 + 400 * i))
        return node(role = "androidx.recyclerview.widget.RecyclerView", scrollable = true,
            box = UiTree.Box(0, 0, 1_000, 2_000), children = rows)
    }

    @Test
    fun testOffScreenNodesAreCountedNotSent() { // [MCP-106]
        val body = reply(listOf(layer(list(3, 4, 112))))
        val rows = nodes(body)
        val listRow = rows.single { it["scroll"] == true }
        val items = rows.filter { it["p"] == listRow["i"] }
        assertEquals(listOf("Item 4", "Item 5", "Item 6", "Item 7"), items.map { it["text"] })
        assertEquals(5, rows.size)
        assertTrue(rows.none { it["off"] == true })
        assertEquals(listOf(3, 112), listRow["hidden"])
        assertEquals(115, body["omitted"])
        // Nothing off screen: no `hidden`, and `omitted` is 0.
        val whole = reply(listOf(layer(list(0, 4, 0))))
        assertTrue(nodes(whole).none { it.containsKey("hidden") })
        assertEquals(0, whole["omitted"])
    }

    /**
     * [list] as the platform sends it: a View's screen bounds are clipped to
     * its parent (`getBoundsOnScreen(…, clipToParent = true)`), so a row
     * scrolled out arrives with an empty box — zero height at the edge, or
     * inverted further out — and not visible to the user, while its bounds in
     * its parent keep its size.
     */
    private fun clippedList(above: Int, on: Int, below: Int): UiTree.Node {
        val rows = ArrayList<UiTree.Node>()
        var n = 1
        for (i in above downTo 1) rows += node(text = "Item ${n++}", clickable = true, visibleToUser = false,
            sized = true, box = UiTree.Box(0, 0, 1_000, -400 * (i - 1)))
        for (i in 0 until on) rows += node(text = "Item ${n++}", clickable = true,
            box = UiTree.Box(0, 400 * i, 1_000, 400 * i + 400))
        for (i in 0 until below) rows += node(text = "Item ${n++}", clickable = true, visibleToUser = false,
            sized = true, box = UiTree.Box(0, 2_000 + 400 * i, 1_000, 2_000))
        return node(role = "android.widget.ScrollView", scrollable = true,
            box = UiTree.Box(0, 0, 1_000, 2_000), children = rows)
    }

    @Test
    fun testRowsThePlatformClippedAreCountedNotFolded() { // [MCP-106]
        val body = reply(listOf(layer(clippedList(3, 4, 112))))
        val rows = nodes(body)
        val listRow = rows.single { it["scroll"] == true }
        assertEquals(listOf("Item 4", "Item 5", "Item 6", "Item 7"),
            rows.filter { it["p"] == listRow["i"] }.map { it["text"] })
        assertEquals(listOf(3, 112), listRow["hidden"])
        assertEquals(115, body["omitted"])
        // `offscreen` sends them `off`, with no tap point and nothing on the display to box.
        val all = nodes(reply(listOf(layer(clippedList(3, 4, 112))), offscreen = true))
        val off = all.filter { it["off"] == true }
        assertEquals(115, off.size)
        assertTrue(off.none { it.containsKey("at") || it.containsKey("box") })
        // A node with no size of its own has no drawable bounds: folded, not counted (WIN-79).
        val zero = node(role = "android.widget.ScrollView", scrollable = true, box = UiTree.Box(0, 0, 1_000, 2_000),
            children = listOf(node(text = "Item 1", clickable = true, box = UiTree.Box(0, 0, 1_000, 400)),
                node(text = "Spacer", visibleToUser = false, box = UiTree.Box(0, 900, 1_000, 900))))
        val folded = reply(listOf(layer(zero)), offscreen = true)
        assertEquals(listOf("Item 1"), nodes(folded).mapNotNull { it["text"] })
        assertEquals(0, reply(listOf(layer(zero)))["omitted"])
    }

    @Test
    fun testOffscreenTrueSendsThemMarked() { // [MCP-106]
        val body = UiTree.reply(7, IntSize(1_000, 2_000), listOf(layer(list(3, 4, 112))), offscreen = true)
        val rows = nodes(body)
        val items = rows.filter { it["scroll"] != true }
        assertEquals(119, items.size)
        val off = items.filter { it["off"] == true }
        assertEquals(115, off.size)
        assertTrue(off.none { it.containsKey("at") })
        assertEquals(0, body["omitted"])
    }

    // MARK: where an off-screen row is (MCP-75)

    @Test
    fun testOffscreenRowsSayWhereTheyAre() { // [MCP-106]
        // A list whose rows lie above and below the display: each `off` row
        // says which way a swipe must go, so `find` need not guess.
        val body = UiTree.reply(7, IntSize(1_000, 2_000), listOf(layer(list(3, 4, 112))), offscreen = true)
        val off = nodes(body).filter { it["off"] == true }
        assertEquals("above", off.single { it["text"] == "Item 1" }["where"])
        assertEquals("above", off.single { it["text"] == "Item 3" }["where"])
        assertEquals("below", off.single { it["text"] == "Item 8" }["where"])
        assertEquals("below", off.single { it["text"] == "Item 119" }["where"])
        // Nothing off screen on a plain read, so no `where` anywhere.
        val clear = nodes(reply(listOf(layer(list(0, 4, 0)))))
        assertTrue(clear.none { it.containsKey("where") })
    }

    @Test
    fun testAnOffscreenRowOnTheSideSaysWhich() { // [MCP-106]
        // A carousel's next card is to the right, a drawer's edge to the left.
        val card = node(text = "Next", clickable = true, box = UiTree.Box(1_000, 200, 1_400, 600))
        val edge = node(text = "Menu", clickable = true, box = UiTree.Box(-300, 200, -100, 600))
        val rows = nodes(reply(listOf(layer(card, edge)), offscreen = true))
        assertEquals("right", rows.single { it["text"] == "Next" }["where"])
        assertEquals("left", rows.single { it["text"] == "Menu" }["where"])
    }

    @Test
    fun testAHiddenOnScreenRowSaysHidden() { // [MCP-106]
        // A tab or a DOM node that is on the display but not visible to the
        // user: swiping reaches nothing, so the direction is `hidden`.
        val tab = node(text = "Archived", clickable = true, visibleToUser = false,
            box = UiTree.Box(0, 100, 1_000, 300))
        val rows = nodes(reply(listOf(layer(tab)), offscreen = true))
        assertEquals("hidden", rows.single()["where"])
    }

    @Test
    fun testAPlatformClippedRowSaysBeforeOrAfterInItsList() { // [MCP-106]
        // The platform clips a scrolled-out row's screen box to nothing: the
        // only evidence of where it is, is the list the walk is inside and
        // whether an on-screen row of that list came first.
        val body = UiTree.reply(7, IntSize(1_000, 2_000), listOf(layer(clippedList(3, 4, 112))), offscreen = true)
        val off = nodes(body).filter { it["off"] == true }
        assertEquals("before", off.single { it["text"] == "Item 1" }["where"])
        assertEquals("before", off.single { it["text"] == "Item 3" }["where"])
        assertEquals("after", off.single { it["text"] == "Item 8" }["where"])
        assertEquals("after", off.single { it["text"] == "Item 119" }["where"])
        // A clipped row that no scrollable holds has nowhere to swipe to.
        val loose = node(text = "Spacer", visibleToUser = false, sized = true, box = UiTree.Box(0, 0, 1_000, 0))
        assertEquals("hidden", nodes(reply(listOf(layer(loose)), offscreen = true)).single()["where"])
    }
}
