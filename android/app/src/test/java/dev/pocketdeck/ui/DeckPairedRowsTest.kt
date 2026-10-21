package dev.pocketdeck.ui

import android.app.Application
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import dev.pocketdeck.app.DeckState
import dev.pocketdeck.app.Prefs
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.annotation.Config

/**
 * The home screen's paired list through the ViewModel, on the shared rig's
 * shape: several paired Macs in pairing order, only one of them live.
 */
@RunWith(AndroidJUnit4::class)
@Config(sdk = [34])
class DeckPairedRowsTest {

    private val ctx: Application = ApplicationProvider.getApplicationContext()
    private val fp = "ab".repeat(32)

    @After
    fun tearDown() {
        DeckState.paired = emptyList()
        DeckState.connectedClientId = null
        DeckState.connectedMac = null
        DeckState.port = -1
        DeckState.enabled = false
    }

    @Test
    fun `the live Mac is the first paired row`() {
        // Stored order is pairing order, so a Mac paired before the others but
        // connected now sits below the fold on a device with many pairings.
        Prefs.addPaired(ctx, Prefs.PairedMac("old", "Alpha", fp, 1_000))
        Prefs.addPaired(ctx, Prefs.PairedMac("live", "Beta", fp, 500))
        Prefs.addPaired(ctx, Prefs.PairedMac("new", "Gamma", fp, 2_000))
        DeckState.connectedClientId = "live"
        DeckState.connectedMac = "Beta"

        val rows = DeckViewModel(ctx).state.value.paired

        assertEquals("live", rows.first().clientId)
        assertTrue(rows.first().connected)
        // The rest stay most-recent first.
        assertEquals(listOf("new", "old"), rows.drop(1).map { it.clientId })
    }

    @Test
    fun `never connected Macs come last, newest connection first`() {
        Prefs.addPaired(ctx, Prefs.PairedMac("never", "Delta", fp, 0))
        Prefs.addPaired(ctx, Prefs.PairedMac("older", "Alpha", fp, 1_000))
        Prefs.addPaired(ctx, Prefs.PairedMac("newer", "Gamma", fp, 3_000))

        val rows = DeckViewModel(ctx).state.value.paired

        assertEquals(listOf("newer", "older", "never"), rows.map { it.clientId })
    }
}
