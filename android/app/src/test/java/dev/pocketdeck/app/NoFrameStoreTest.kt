package dev.pocketdeck.app

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

/**
 * K1 for the phone-side ring (WIN-66, ISS-10): the newest 20 episodes survive
 * a log rotation, and an episode that ends updates its own entry.
 */
class NoFrameStoreTest {

    @get:Rule
    val folder = TemporaryFolder()

    private fun episode(id: Int, ended: Boolean = false): String {
        val rest = if (ended) ",\"outcome\":\"late\",\"waitedMs\":2600" else ""
        return "{\"ep\":$id,\"ms\":1500,\"phase\":\"draining\"$rest}"
    }

    @Test
    fun theRingKeepsTheNewestTwenty() {
        val file = folder.newFile("no-frame-episodes.jsonl")
        for (id in 1..25) NoFrameStore.record(file, id, episode(id))
        val kept = NoFrameStore.read(file)
        assertEquals(20, kept.size)
        assertEquals(6, NoFrameStore.episodeOf(kept.first()))
        assertEquals(25, NoFrameStore.episodeOf(kept.last()))
    }

    @Test
    fun anEndedEpisodeUpdatesItsOwnEntry() {
        val file = folder.newFile("no-frame-episodes.jsonl")
        NoFrameStore.record(file, 3, episode(3))
        NoFrameStore.record(file, 4, episode(4))
        NoFrameStore.record(file, 3, episode(3, ended = true))
        val kept = NoFrameStore.read(file)
        assertEquals(2, kept.size)
        assertEquals(listOf(3, 4), kept.map { NoFrameStore.episodeOf(it) })
        assertTrue(kept.first().contains("\"outcome\":\"late\""))
    }

    @Test
    fun aMissingFileReadsEmpty() {
        assertEquals(emptyList<String>(), NoFrameStore.read(folder.newFile("empty.jsonl")))
    }
}
