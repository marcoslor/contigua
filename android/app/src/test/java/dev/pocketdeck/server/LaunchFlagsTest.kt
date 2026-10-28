package dev.pocketdeck.server

import android.content.Intent
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * WIN-32, the launch half: `window.open`'s `newInstance` reaches the platform
 * as `NEW_DOCUMENT | MULTIPLE_TASK` (on the binder path and the `am` fallback
 * alike, so [LaunchFlags] is the one source), and `window.opened` names the
 * task the launch made.
 */
class LaunchFlagsTest : SessionFixture() {

    @Test
    fun `a plain launch is the new task it always was`() {
        val flags = LaunchFlags.of(newInstance = false)
        assertEquals(Intent.FLAG_ACTIVITY_NEW_TASK, flags)
        assertEquals(0, flags and Intent.FLAG_ACTIVITY_NEW_DOCUMENT)
        assertEquals(0, flags and Intent.FLAG_ACTIVITY_MULTIPLE_TASK)
    }

    @Test
    fun `newInstance adds the two flags that ask for another task`() {
        val flags = LaunchFlags.of(newInstance = true)
        assertNotEquals(0, flags and Intent.FLAG_ACTIVITY_NEW_TASK)
        assertNotEquals(0, flags and Intent.FLAG_ACTIVITY_NEW_DOCUMENT)
        assertNotEquals(0, flags and Intent.FLAG_ACTIVITY_MULTIPLE_TASK)
    }

    @Test
    fun `the flags are the platform's own numbers`() {
        // The `am` path formats this int into `-f`; a wrong number would launch
        // the app into the wrong task shape without an error.
        assertEquals(0x10000000, Intent.FLAG_ACTIVITY_NEW_TASK)
        assertEquals(0x00080000, Intent.FLAG_ACTIVITY_NEW_DOCUMENT)
        assertEquals(0x08000000, Intent.FLAG_ACTIVITY_MULTIPLE_TASK)
        assertEquals(0x18080000, LaunchFlags.of(newInstance = true))
    }

    @Test
    fun `window open passes newInstance to the launch`() {
        connect()
        open(1, "com.a")
        readUntil("window.opened")
        open(2, "com.a", newInstance = true)
        readUntil("window.opened")
        assertEquals(2, platform.launches.size)
        assertEquals("the first window is a click's, not a new instance", false, platform.launches[0].newInstance)
        assertEquals(true, platform.launches[1].newInstance)
        assertEquals(2, platform.opens.size)
        assertTrue("each window has its own display", platform.opens[0].displayId != platform.opens[1].displayId)
    }

    @Test
    fun `window opened names the task the launch made`() {
        connect(taskPresence = object : TaskPresence {
            override fun hasTask(displayId: Int) = true
            override fun taskId(displayId: Int) = 4242
        })
        open(1, "com.a")
        assertEquals(4242L, readUntil("window.opened")["taskId"])
    }

    @Test
    fun `a phone that cannot read its tasks still opens with taskId 0`() {
        connect()
        open(1, "com.a")
        assertEquals(0L, readUntil("window.opened")["taskId"])
    }

    @Test
    fun `the task is read after the launch, not before it`() {
        // window.opened names the display's top task, so the launch has to have
        // happened: a phone that answered before the launch would name the old one.
        connect(taskPresence = object : TaskPresence {
            override fun hasTask(displayId: Int) = true
            override fun taskId(displayId: Int): Int? = if (platform.launches.isEmpty()) null else 77
        })
        open(1, "com.a")
        assertEquals(77L, readUntil("window.opened")["taskId"])
        assertEquals("the phone launched before the reply", 1, platform.launches.size)
    }
}
