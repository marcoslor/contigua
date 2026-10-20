package dev.pocketdeck.server

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The camera probe's host-testable half: its command line, its single result
 * line, and the reflection rewrite that gives the framework base context the
 * shell package. None of this touches Android, so a wrong index or a stray
 * newline is caught here instead of on an emulator boot.
 */
class CameraProbeArgsTest {

    // ---- ProbeStage.parse ------------------------------------------------

    @Test
    fun `stage alone takes the defaults`() {
        val stage = ProbeStage.parse(arrayOf("feed"))
        assertEquals("feed", stage?.name)
        assertEquals(ProbeStage.DEFAULT_SECONDS, stage?.seconds)
        assertNull(stage?.camera)
        assertNull(stage?.ready)
    }

    @Test
    fun `flags set seconds camera and ready path`() {
        val stage = ProbeStage.parse(
            arrayOf("evict", "--seconds", "20", "--camera", "10", "--ready", "/data/local/tmp/pd-cam-ready"),
        )
        assertEquals("evict", stage?.name)
        assertEquals(20, stage?.seconds)
        assertEquals("10", stage?.camera)
        assertEquals("/data/local/tmp/pd-cam-ready", stage?.ready)
    }

    @Test
    fun `every documented stage parses`() {
        for (name in listOf("list", "open", "locked", "feed", "evict")) {
            assertEquals(name, ProbeStage.parse(arrayOf(name))?.name)
        }
    }

    @Test
    fun `unknown stage flag or value is refused`() {
        assertNull(ProbeStage.parse(emptyArray()))
        assertNull(ProbeStage.parse(arrayOf("shoot")))
        assertNull(ProbeStage.parse(arrayOf("feed", "--bogus", "1")))
        assertNull(ProbeStage.parse(arrayOf("feed", "--seconds")))
        assertNull(ProbeStage.parse(arrayOf("feed", "--seconds", "soon")))
        assertNull(ProbeStage.parse(arrayOf("feed", "--seconds", "0")))
        assertNull(ProbeStage.parse(arrayOf("feed", "--camera", " ")))
    }

    // ---- ProbeResult.line ------------------------------------------------

    @Test
    fun `result line is one greppable line with the stage and ok first`() {
        val line = ProbeResult(
            "feed",
            true,
            listOf("camera" to "1", "encFps" to "29.9", "error" to "none"),
        ).line()
        assertEquals("cam: result stage=feed ok=true camera=1 encFps=29.9 error=none", line)
    }

    @Test
    fun `values never carry whitespace or newlines`() {
        val line = ProbeResult(
            "open",
            false,
            listOf("error" to "SecurityException: Given\tpackage\nandroid refused", "empty" to "  "),
        ).line()
        assertEquals(
            "cam: result stage=open ok=false " +
                "error=SecurityException:_Given_package_android_refused empty=-",
            line,
        )
        assertTrue(line.lines().size == 1)
    }

    // ---- ReflectionFields.write -----------------------------------------

    /**
     * Stands in for a ContextImpl: the same three field names, no Android class
     * in sight, so the rewrite is exercised on the JVM.
     */
    private class FakeBase {
        @Suppress("unused")
        var mPackageName: String = "android"

        @Suppress("unused")
        var mOpPackageName: String = "android"

        @Suppress("unused")
        var mAttributionSource: Any? = null
    }

    @Test
    fun `the shell package lands on the base context's three fields`() {
        val base = FakeBase()
        val attribution = Any()
        val failed = ReflectionFields.write(
            base,
            mapOf(
                "mPackageName" to "com.android.shell",
                "mOpPackageName" to "com.android.shell",
                "mAttributionSource" to attribution,
            ),
        )
        assertEquals(emptyList<String>(), failed)
        assertEquals("com.android.shell", base.mPackageName)
        assertEquals("com.android.shell", base.mOpPackageName)
        assertTrue(base.mAttributionSource === attribution)
    }

    @Test
    fun `a missing field is reported and the others still land`() {
        val base = FakeBase()
        val failed = ReflectionFields.write(
            base,
            mapOf(
                "mPackageName" to "com.android.shell",
                "mNoSuchField" to "x",
            ),
        )
        assertEquals(listOf("mNoSuchField"), failed)
        assertEquals("com.android.shell", base.mPackageName)
    }
}
