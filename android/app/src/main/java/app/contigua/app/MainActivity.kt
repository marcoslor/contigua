package app.contigua.app

import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import app.contigua.ui.DeckApp
import app.contigua.ui.DeckViewModel
import app.contigua.ui.theme.ContiguaTheme

/** Compose host for onboarding and home; also the `contigua://pair` entry. */
class MainActivity : ComponentActivity() {

    private lateinit var deck: DeckViewModel

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        deck = DeckViewModel(application)
        setContent {
            ContiguaTheme {
                DeckApp(deck)
            }
        }
        handlePairingIntent(intent)
    }

    override fun onResume() {
        super.onResume()
        // Returning from the battery or permissions screen changes what the
        // app can honestly say: re-read it instead of keeping a stale line.
        if (::deck.isInitialized) deck.refresh()
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handlePairingIntent(intent)
    }

    /**
     * A view intent for the Mac's QR link pairs exactly like a scan (docs/UX.md:
     * scanning is the consent). Only `contigua://pair` reaches this activity.
     */
    private fun handlePairingIntent(intent: Intent?) {
        val uri = intent?.data ?: return
        deck.onQrScanned(uri.toString())
    }
}
