package app.contigua.server

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** The one clipboard reader policy, every combination (ISS-27, SHARE-19). */
class ClipReaderTest {

    @Test
    fun theShellUserReadsDirectly() {
        assertEquals(ClipReader.Direct, clipReader(SHELL_UID, helperAvailable = false))
        assertEquals(ClipReader.Direct, clipReader(SHELL_UID, helperAvailable = true))
    }

    @Test
    fun rootReadsOnlyThroughAReadyHelper() {
        assertEquals(ClipReader.Helper, clipReader(0, helperAvailable = true))
    }

    @Test
    fun rootWithoutAHelperReadsNothingAndSaysWhy() {
        val reader = clipReader(0, helperAvailable = false)
        assertTrue(reader is ClipReader.Off)
        assertTrue((reader as ClipReader.Off).reason.contains("uid 0"))
        assertTrue(reader.reason.contains("no helper"))
    }

    @Test
    fun anyOtherUidNeverReadsDirectly() {
        for (uid in listOf(1000, 10123, -1)) {
            val reader = clipReader(uid, helperAvailable = true)
            assertTrue("uid $uid got $reader", reader is ClipReader.Off)
            assertTrue((reader as ClipReader.Off).reason.contains("uid $uid"))
        }
    }
}
