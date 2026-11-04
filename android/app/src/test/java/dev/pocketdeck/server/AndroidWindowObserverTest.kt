package dev.pocketdeck.server

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.ActivityInfo
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.annotation.Config

/**
 * WIN-28: a window's app and title are the task's own. An activity another
 * package puts on top of the task (a browser's voice search) may not rename it.
 * The choice is tested through the same `packageOf` the task poll runs, with a
 * fake `RecentTaskInfo` shaped like the hidden one.
 */
@RunWith(AndroidJUnit4::class)
@Config(sdk = [34])
class AndroidWindowObserverTest {

    private val observer = AndroidWindowObserver(ApplicationProvider.getApplicationContext<Context>(), {})

    /** Shaped like the hidden `ActivityManager.RunningTaskInfo` fields we read. */
    internal class FakeTask(
        @JvmField val baseActivity: ComponentName? = null,
        @JvmField val baseIntent: Intent? = null,
        @JvmField val topActivity: ComponentName? = null,
        @JvmField val topActivityInfo: ActivityInfo? = null,
        @JvmField val taskDescription: FakeDescription? = null,
        @JvmField val taskId: Int = 0,
    )

    internal class FakeDescription(private val label: String?) {
        fun getLabel(): CharSequence? = label
    }

    private val names = mapOf("com.a" to "Alpha", "com.b" to "Beta")

    private fun labelOf(pkg: String): String = names[pkg] ?: pkg

    private fun topTask(task: FakeTask): TopTask? = observer.topTaskOf(task, ::labelOf) { null }

    private fun component(pkg: String) = ComponentName(pkg, "$pkg.MainActivity")

    private fun intent(pkg: String) = Intent().setComponent(component(pkg))

    private fun info(pkg: String) = ActivityInfo().apply { packageName = pkg }

    @Test
    fun `a task keeps its root app when another package is on top`() {
        val task = FakeTask(
            baseActivity = component("com.a"),
            topActivity = component("com.b"),
            taskDescription = FakeDescription("Voice search"),
            taskId = 11,
        )

        val top = topTask(task)!!

        assertEquals("com.a", top.pkg)
        assertEquals("Alpha", top.label)
        assertEquals("Voice search", top.taskLabel)
        assertEquals(11, top.taskId)
    }

    @Test
    fun `a base intent alone names the root app`() {
        val top = topTask(FakeTask(baseIntent = intent("com.a"), topActivity = component("com.b")))!!

        assertEquals("com.a", top.pkg)
        assertEquals("Alpha", top.label)
    }

    @Test
    fun `a task whose root and top agree is unchanged`() {
        val top = topTask(FakeTask(baseActivity = component("com.a"), topActivity = component("com.a")))!!

        assertEquals("com.a", top.pkg)
        assertEquals("Alpha", top.label)
    }

    @Test
    fun `no root info falls back to the top activity`() {
        val top = topTask(FakeTask(topActivity = component("com.b")))!!

        assertEquals("com.b", top.pkg)
        assertEquals("Beta", top.label)
    }

    @Test
    fun `no component at all falls back to the top activity's info`() {
        assertEquals("com.b", topTask(FakeTask(topActivityInfo = info("com.b")))!!.pkg)
    }

    @Test
    fun `a task with no package at all reports nothing`() {
        assertNull(topTask(FakeTask()))
    }

    @Test
    fun `a description that carries no label falls back to the task id lookup`() {
        val task = FakeTask(baseActivity = component("com.a"), taskId = 12)

        assertEquals("From the task id", observer.topTaskOf(task, ::labelOf) { "From the task id" }!!.taskLabel)
    }
}
