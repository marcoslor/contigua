package app.contigua.server

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * `ui.press` (docs/PROTOCOL.md "UI tree" item 8, plan B3): the pure decision
 * from the node as `refresh()` reads it now to a press or a refusal code.
 * A refusal is never a [UiPress.Decision.Press], so nothing is injected.
 */
class UiPressTest {

    private val size = IntSize(1_080, 2_400)

    /** A node from the latest read: [refreshes] is what `refresh()` returns, [now] what it reads then. */
    private class Fake(private val refreshes: Boolean, private val now: UiTree.Node) : UiPress.Target {
        var refreshed = 0
        override fun refresh(): Boolean { refreshed++; return refreshes }
        override fun read(): UiTree.Node = now
    }

    private fun button(text: String?, box: UiTree.Box, visible: Boolean = true, password: Boolean = false,
                       desc: String? = null, children: List<UiTree.Node> = emptyList()) =
        UiTree.Node(role = "android.widget.Button", text = text, desc = desc, box = box, clickable = true,
            visibleToUser = visible, password = password, children = children)

    private fun nobody(@Suppress("UNUSED_PARAMETER") node: UiTree.Node): Any? = null

    private fun refused(decision: UiPress.Decision): UiPress.Decision.Refuse {
        assertFalse("pressed, but should not have: $decision", decision is UiPress.Decision.Press)
        return decision as UiPress.Decision.Refuse
    }

    @Test
    fun testAPresentVisibleNodeIsPressedAtItsCentreNow() { // [MCP-86]
        // The latest read had k 5 at [0,0,100,100]; refresh() gives [0,500,100,600].
        val target = Fake(true, button("Add to cart", UiTree.Box(0, 500, 100, 600)))
        val decision = UiPress.decide(target, size, "Add to cart", ::nobody)
        assertEquals(1, target.refreshed)
        val press = decision as UiPress.Decision.Press
        assertEquals(50, press.x)
        assertEquals(550, press.y)
        assertEquals(listOf(0, 500, 100, 600), press.reply["box"])
        assertEquals(true, press.reply["ok"])
        assertEquals(listOf(0.046, 0.229), press.reply["at"])
    }

    @Test
    fun testThePressAnswersTheLabelItPressed() { // [MCP-108]
        val press = UiPress.decide(Fake(true, button("Add to cart", UiTree.Box(0, 500, 100, 600))),
            size, "Add to cart", ::nobody) as UiPress.Decision.Press
        assertEquals("Add to cart", press.reply["text"])
        assertEquals("Button", press.reply["role"])
        assertFalse(press.reply.containsKey("desc"))
        // A password node: the press says what it is, never what it holds.
        val secret = UiPress.decide(Fake(true, button("hunter2", UiTree.Box(0, 500, 100, 600), password = true)),
            size, null, ::nobody) as UiPress.Decision.Press
        assertFalse(secret.reply.containsKey("text"))
        assertEquals("Button", secret.reply["role"])
    }

    @Test
    fun testANodeThatNowReadsDifferentlyIsNotPressed() { // [MCP-86]
        // #188: a list reused the row's node, or the button relabelled itself.
        val decision = UiPress.decide(Fake(true, button("Buy now", UiTree.Box(0, 500, 100, 600))),
            size, "Add to cart", ::nobody)
        val refusal = refused(decision)
        assertEquals("changed", refusal.code)
        assertEquals("changed", refusal.reply["code"])
        assertEquals("Buy now", refusal.reply["now"])
        // A row with no label of its own compares the first labelled node under it.
        val row = UiTree.Node(role = "android.widget.LinearLayout", box = UiTree.Box(0, 500, 1_080, 700),
            clickable = true, children = listOf(
                UiTree.Node(role = "android.widget.ImageView", box = UiTree.Box(0, 500, 100, 600)),
                UiTree.Node(role = "android.widget.TextView", text = "Item 17", box = UiTree.Box(100, 500, 1_080, 600)),
                UiTree.Node(role = "android.widget.TextView", text = "In stock", box = UiTree.Box(100, 600, 1_080, 700)),
            ))
        assertEquals("Item 17", UiPress.label(row, size))
        val reused = refused(UiPress.decide(Fake(true, row), size, "Item 3", ::nobody))
        assertEquals("changed", reused.code)
        assertEquals("Item 17", reused.reply["now"])
        assertTrue(UiPress.decide(Fake(true, row), size, "Item 17", ::nobody) is UiPress.Decision.Press)
    }

    @Test
    fun testAnOffScreenNodeIsNotPressed() { // [MCP-86]
        val below = button("Add to cart", UiTree.Box(0, 2_500, 100, 2_600))
        assertEquals("off_screen", refused(UiPress.decide(Fake(true, below), size, "Add to cart", ::nobody)).code)
    }

    @Test
    fun testAGoneNodeIsNotPressed() { // [MCP-86]
        val stale = Fake(false, button("Add to cart", UiTree.Box(0, 500, 100, 600)))
        assertEquals("gone", refused(UiPress.decide(stale, size, "Add to cart", ::nobody)).code)
        // Unknown key 999: the latest read has no node for it.
        assertEquals("gone", refused(UiPress.decide(null, size, "Add to cart", ::nobody)).code)
    }

    @Test
    fun testAnInvisibleNodeIsNotPressed() {
        val hidden = button("Add to cart", UiTree.Box(0, 500, 100, 600), visible = false)
        assertEquals("not_visible", refused(UiPress.decide(Fake(true, hidden), size, "Add to cart", ::nobody)).code)
    }

    @Test
    fun testACoveredNodeIsNotPressed() { // [MCP-89]
        val node = button("Add to cart", UiTree.Box(0, 500, 100, 600))
        val byNode = refused(UiPress.decide(Fake(true, node), size, "Add to cart") { 7 })
        assertEquals("covered", byNode.code)
        assertEquals(7, byNode.reply["coveredBy"])
        val byWindow = refused(UiPress.decide(Fake(true, node), size, "Add to cart") { "window" })
        assertEquals("window", byWindow.reply["coveredBy"])
    }

    @Test
    fun testAFieldWhoseTextChangedIsStillPressed() { // [MCP-86]
        // #188's label is identity: a field's text is its value, so an edited
        // field is the same field. Its label is its desc, else its view id.
        val field = UiTree.Node(role = "android.widget.EditText", text = "milk", desc = "Search",
            box = UiTree.Box(0, 500, 1_080, 600), editable = true)
        assertEquals("Search", UiPress.label(field, size))
        assertTrue(UiPress.decide(Fake(true, field), size, "Search", ::nobody) is UiPress.Decision.Press)
        val byId = UiTree.Node(role = "android.widget.EditText", text = "milk",
            viewId = "com.example:id/search_box", box = UiTree.Box(0, 500, 1_080, 600), editable = true)
        assertEquals("search_box", UiPress.label(byId, size))
        // Inside a container a field contributes nothing.
        val row = UiTree.Node(role = "android.widget.LinearLayout", box = UiTree.Box(0, 500, 1_080, 700),
            clickable = true, children = listOf(field,
                UiTree.Node(role = "android.widget.TextView", text = "Shopping", box = UiTree.Box(0, 600, 1_080, 700))))
        assertEquals("Shopping", UiPress.label(row, size))
    }

    @Test
    fun testAPasswordFieldIsLabelledByItsId() { // [MCP-86]
        // Its row carries neither text nor desc (item 2), so the Mac labels it
        // by its id: the phone must too.
        val pw = UiTree.Node(role = "android.widget.EditText", text = "hunter2", desc = "Password",
            viewId = "com.x:id/pw", box = UiTree.Box(0, 500, 1_080, 600), editable = true, password = true)
        assertEquals("pw", UiPress.label(pw, size))
        assertTrue(UiPress.decide(Fake(true, pw), size, "pw", ::nobody) is UiPress.Decision.Press)
    }

    /**
     * The Mac's label of row [at] (`UITree.labels()`): an `edit` row's desc,
     * else its id; else its text, else its desc, else the first labelled
     * on-screen row under it in reading order, where an `edit` row and its
     * rows give none and an `off` row gives none of its own (MCP-86).
     */
    private fun macLabel(rows: List<Map<String, Any?>>, at: Int): String {
        fun own(row: Map<String, Any?>): String? = (row["text"] ?: row["desc"]) as String?
        val row = rows[at]
        if (row["edit"] == true) return (row["desc"] ?: row["id"] ?: "") as String
        own(row)?.let { return it }
        val byIndex = rows.associateBy { it["i"] }
        fun under(other: Map<String, Any?>, ancestor: Any?): Boolean {
            var p = other["p"]
            while (p != null) {
                if (p == ancestor) return true
                p = byIndex[p]?.get("p")
            }
            return false
        }
        fun inField(other: Map<String, Any?>): Boolean {
            var p = other["p"]
            while (p != null && p != row["i"]) {
                if (byIndex[p]?.get("edit") == true) return true
                p = byIndex[p]?.get("p")
            }
            return false
        }
        for (other in rows.drop(at + 1)) {
            if (!under(other, row["i"])) continue
            if (other["edit"] == true || inField(other) || other["off"] == true) continue
            own(other)?.let { return it }
        }
        return ""
    }

    /** A container whose first child "Item 3" is below the display and whose second, "Item 4", is on it. */
    private fun containerWithAnOffScreenFirstChild() = UiTree.Node(role = "android.widget.LinearLayout",
        box = UiTree.Box(0, 2_000, 1_080, 3_000), clickable = true, children = listOf(
            UiTree.Node(role = "android.widget.TextView", text = "Item 3", box = UiTree.Box(0, 2_500, 1_080, 3_000)),
            UiTree.Node(role = "android.widget.TextView", text = "Item 4", box = UiTree.Box(0, 2_000, 1_080, 2_300)),
        ))

    /** As the platform sends it: the first child, scrolled out, has its screen box clipped to nothing (MCP-106). */
    private fun containerWithAClippedFirstChild() = UiTree.Node(role = "android.widget.LinearLayout",
        box = UiTree.Box(0, 1_800, 1_080, 2_400), clickable = true, children = listOf(
            UiTree.Node(role = "android.widget.TextView", text = "Item 3", box = UiTree.Box(0, 2_400, 1_080, 2_400),
                visibleToUser = false, sized = true),
            UiTree.Node(role = "android.widget.TextView", text = "Item 4", box = UiTree.Box(0, 1_800, 1_080, 2_100)),
        ))

    @Test
    fun testAChildThePlatformClippedGivesNoLabel() { // [MCP-86] [MCP-106]
        val row = containerWithAClippedFirstChild()
        assertEquals("Item 4", UiPress.label(row, size))
        assertTrue(UiPress.decide(Fake(true, row), size, "Item 4", ::nobody) is UiPress.Decision.Press)
    }

    @Test
    fun testTheMacsLabelOfAFieldsRowIsThePhones() { // [MCP-86]
        val fields = listOf(
            UiTree.Node(role = "android.widget.EditText", text = "Search", desc = "Search",
                viewId = "com.x:id/q", box = UiTree.Box(0, 500, 1_080, 600), editable = true),
            UiTree.Node(role = "android.widget.EditText", text = "milk", desc = "Search",
                viewId = "com.x:id/q", box = UiTree.Box(0, 500, 1_080, 600), editable = true),
            UiTree.Node(role = "android.widget.EditText", text = "milk",
                viewId = "com.x:id/q", box = UiTree.Box(0, 500, 1_080, 600), editable = true),
            UiTree.Node(role = "android.widget.EditText", text = "hunter2", desc = "Password",
                viewId = "com.x:id/pw", box = UiTree.Box(0, 500, 1_080, 600), editable = true, password = true),
            containerWithAnOffScreenFirstChild(),
            containerWithAClippedFirstChild(),
        )
        for (field in fields) {
            val layer = UiTree.Layer(title = "App", type = "app", focused = true, nodes = listOf(field))
            // `offscreen`: the off row is sent marked, so the Mac's skip is what is compared.
            @Suppress("UNCHECKED_CAST")
            val rows = UiTree.reply(1, size, listOf(layer), offscreen = true)["nodes"] as List<Map<String, Any?>>
            assertEquals("$field", UiPress.label(field, size), macLabel(rows, 0))
        }
    }

    @Test
    fun testACollapsedRowGivesNoLabel() { // [MCP-86]
        // A labelled node the tree folds away: no box at all, or an empty one
        // with empty bounds in its parent (a collapsed row). `UiTree.kept`
        // drops it, so the Mac never shows it and the press must not be
        // labelled by it. Its on-screen sibling is the label.
        val noBox = UiTree.Node(role = "android.widget.TextView", text = "Item 3")
        val collapsed = UiTree.Node(role = "android.widget.TextView", text = "Item 2",
            box = UiTree.Box(0, 0, 0, 0), sized = false)
        for (folded in listOf(noBox, collapsed)) {
            val row = UiTree.Node(role = "android.widget.LinearLayout",
                box = UiTree.Box(0, 1_800, 1_080, 2_400), clickable = true,
                children = listOf(folded,
                    UiTree.Node(role = "android.widget.TextView", text = "Item 4", box = UiTree.Box(0, 1_800, 1_080, 2_100))))
            assertEquals("the folded $folded gives no label", "Item 4", UiPress.label(row, size))
            assertTrue(UiPress.decide(Fake(true, row), size, "Item 4", ::nobody) is UiPress.Decision.Press)
        }
    }

    @Test
    fun testAnOffScreenChildGivesNoLabel() { // [MCP-86]
        val row = containerWithAnOffScreenFirstChild()
        assertEquals("Item 4", UiPress.label(row, size))
        assertTrue(UiPress.decide(Fake(true, row), size, "Item 4", ::nobody) is UiPress.Decision.Press)
    }
}
