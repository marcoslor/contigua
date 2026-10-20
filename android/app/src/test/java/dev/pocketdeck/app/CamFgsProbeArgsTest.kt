package dev.pocketdeck.app

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The C0b probe's host-testable half: the request the service accepts and the
 * single result line the rig greps. A wrong label, duration or a stray
 * whitespace would otherwise cost an emulator boot to find.
 */
class CamFgsProbeArgsTest {

    // ---- CamFgsRequest.parse ---------------------------------------------

    @Test
    fun `stage alone takes the defaults`() {
        val request = CamFgsRequest.parse("bg-unlocked-a", CamFgsRequest.DEFAULT_SECONDS, false)
        assertEquals("bg-unlocked-a", request?.stage)
        assertEquals(5, request?.seconds)
        assertEquals(false, request?.saveFrame)
    }

    @Test
    fun `seconds and the frame flag are carried`() {
        val request = CamFgsRequest.parse("locked-b2", 25, true)
        assertEquals("locked-b2", request?.stage)
        assertEquals(25, request?.seconds)
        assertEquals(true, request?.saveFrame)
    }

    @Test
    fun `every documented stage label parses`() {
        for (name in listOf("bg-unlocked-a", "bg-unlocked-b", "bg-unlocked-b2", "locked-a", "locked-b", "locked-b2")) {
            assertEquals(name, CamFgsRequest.parse(name, 5, false)?.stage)
        }
    }

    @Test
    fun `a bad label or duration is refused`() {
        assertNull(CamFgsRequest.parse(null, 5, false))
        assertNull(CamFgsRequest.parse("", 5, false))
        assertNull(CamFgsRequest.parse("UPPER", 5, false))
        assertNull(CamFgsRequest.parse("../etc", 5, false))
        assertNull(CamFgsRequest.parse("has space", 5, false))
        assertNull(CamFgsRequest.parse("a".repeat(33), 5, false))
        assertNull(CamFgsRequest.parse("feed", 0, false))
        assertNull(CamFgsRequest.parse("feed", 61, false))
    }

    // ---- CamFgsResult.line -----------------------------------------------

    @Test
    fun `result line carries the six fixed fields in order`() {
        val line = CamFgsResult(
            stage = "bg-unlocked-a",
            ok = true,
            startedFg = true,
            opened = true,
            frames = 148,
            error = "none",
        ).line()
        assertEquals(
            "stage=bg-unlocked-a ok=true started_fg=true opened=true frames=148 error=none",
            line,
        )
    }

    @Test
    fun `a refusal keeps the exception class and message on one line`() {
        val line = CamFgsResult(
            stage = "bg-unlocked-b",
            ok = false,
            startedFg = false,
            opened = false,
            frames = 0,
            error = "SecurityException: Starting FGS with type camera\n\trequires permissions",
        ).line()
        assertEquals(
            "stage=bg-unlocked-b ok=false started_fg=false opened=false frames=0 " +
                "error=SecurityException:_Starting_FGS_with_type_camera_requires_permissions",
            line,
        )
        assertTrue(line.lines().size == 1)
    }

    @Test
    fun `an empty value is a dash`() {
        assertEquals("-", CamFgsResult.value("   "))
    }

    @Test
    fun `describe is class simple name plus message`() {
        assertEquals("IllegalStateException:no binder", CamFgsResult.describe(IllegalStateException("no binder")))
        assertEquals("IllegalStateException:-", CamFgsResult.describe(IllegalStateException()))
    }
}
