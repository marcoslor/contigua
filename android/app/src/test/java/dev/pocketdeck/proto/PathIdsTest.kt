package dev.pocketdeck.proto

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** PATH-3/19 (ids) and PATH-1/2 (the version pin). */
class PathIdsTest {
    @Test
    fun sessionIdsAre128RandomBitsAs32LowercaseHex() {
        val seen = HashSet<String>()
        repeat(512) {
            val id = PathIds.sessionId()
            assertEquals(32, id.length)
            assertTrue(id.all { it in '0'..'9' || it in 'a'..'f' })
            assertTrue("a session id was reused", seen.add(id))
        }
    }

    @Test
    fun pathIdsAreEightHexAndUniqueInTheLiveSet() {
        val live = HashSet<String>()
        repeat(1000) {
            val id = PathIds.pathId(live)
            assertEquals(8, id.length)
            assertTrue(id.all { it in '0'..'9' || it in 'a'..'f' })
            assertTrue(live.add(id))
        }
    }

    @Test
    fun sessionIdsAreNotDerivedFromAPeerId() {
        assertNotEquals(PathIds.sessionId(), PathIds.sessionId())
    }
}

class VersionTest {
    @Test
    fun protocolVersionIsFour() {
        assertEquals(4, PathVersion.CURRENT)
    }

    @Test
    fun everyOtherVersionIsRefused() {
        assertFalse(PathVersion.refused(4))
        assertTrue(PathVersion.refused(3))
        assertTrue(PathVersion.refused(5))
        assertTrue(PathVersion.refused(null))
    }

    @Test
    fun thePhoneNamesWhichAppToUpdateFromTheHellosV() {
        assertEquals("Update PocketDeck on this Mac.", PathVersion.phoneSentence(3))
        assertEquals("Update PocketDeck on this Mac.", PathVersion.phoneSentence(null))
        assertEquals("Update PocketDeck on your phone.", PathVersion.phoneSentence(5))
    }

    @Test
    fun theMacNamesWhichAppToUpdate() {
        assertEquals("Update PocketDeck on your phone.", PathVersion.macSentence(3))
        assertEquals("Update PocketDeck on your phone.", PathVersion.macSentence(null))
        assertEquals("Update PocketDeck on this Mac.", PathVersion.macSentence(5))
    }

    @Test
    fun theRefusalCarriesTheRefusingSidesOwnVersion() {
        val bytes = PathVersion.refusal(4)
        val frame = Frame(
            bytes[4].toInt() and 0xFF,
            PathCodec.readInt(bytes, 5),
            bytes.copyOfRange(9, bytes.size),
        )
        val obj = Json.parseObject(String(frame.payload))
        assertEquals("error", obj["t"])
        assertEquals("version", obj["code"])
        assertEquals(4L, (obj["v"] as Number).toLong())
    }
}
