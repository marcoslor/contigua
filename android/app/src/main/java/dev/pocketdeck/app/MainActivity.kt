package dev.pocketdeck.app

import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import dev.pocketdeck.ui.DeckApp
import dev.pocketdeck.ui.DeckViewModel
import dev.pocketdeck.ui.theme.PocketDeckTheme

/** Compose host for onboarding and home; also the `pocketdeck://pair` entry. */
class MainActivity : ComponentActivity() {

    private lateinit var deck: DeckViewModel

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        deck = DeckViewModel(application)
        setContent {
            PocketDeckTheme {
                DeckApp(deck)
            }
        }
        handlePairingIntent(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handlePairingIntent(intent)
    }

    /**
     * A view intent for the Mac's QR link pairs exactly like a scan (docs/UX.md:
     * scanning is the consent). Only `pocketdeck://pair` reaches this activity.
     */
    private fun handlePairingIntent(intent: Intent?) {
        val uri = intent?.data ?: return
        deck.onQrScanned(uri.toString())
    }
}
