package app.contigua.server

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * WIN-3: every stream's `window.title` says which app its display shows
 * (`label`, `pkg`) the moment that app changes — the Mac's link and handoff
 * windows take their Dock identity and their re-open from `pkg`. App and link
 * streams add the task's `title` (WIN-28); a change to the title alone is the
 * throttled case.
 */
class WindowTitleFieldsTest : SessionFixture() {

    @Volatile private var task: TopTask? = null

    @Test
    fun `a link stream's top app change carries label and pkg at once`() {
        task = TopTask("com.a", "Alpha", taskId = 11, taskLabel = "Page one")
        connect(titleObserver = { task })
        send(
            mapOf(
                "t" to "link.open", "stream" to 5, "w" to 640, "h" to 480, "dpi" to 160,
                "url" to "https://example.com/x",
            ),
        )
        readUntil("window.opened")
        val first = readUntil("window.title")
        assertEquals(5L, first["stream"])
        assertEquals("Alpha", first["label"])
        assertEquals("com.a", first["pkg"])
        assertEquals("Page one", first["title"])

        // Inside the throttle's second the display's top app changes: the Mac's
        // link window needs the package then, so this message is not held.
        task = TopTask("com.b", "Beta", taskId = 12, taskLabel = "Page two")
        val second = readUntil("window.title")
        assertEquals("Beta", second["label"])
        assertEquals("com.b", second["pkg"])
        assertEquals("Page two", second["title"])
    }

    @Test
    fun `an app stream's title-only change waits for the throttle`() {
        task = TopTask("com.a", "Alpha", taskId = 11, taskLabel = "First")
        connect(titleObserver = { task })
        open(1, "com.a")
        readUntil("window.opened")
        val first = readUntil("window.title")
        assertEquals("First", first["title"])
        assertEquals("Alpha", first["label"])
        assertEquals("com.a", first["pkg"])

        // Same app and label, a new task title: the app did not change, so this
        // is the one that waits out the second.
        task = TopTask("com.a", "Alpha", taskId = 11, taskLabel = "Second")
        assertTrue("a title-only change is not sent at once", expectNoJsonWithin(400))
        assertEquals("Second", readUntil("window.title")["title"])
    }
}
