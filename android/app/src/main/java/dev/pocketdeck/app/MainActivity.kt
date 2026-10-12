package dev.pocketdeck.app

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import dev.pocketdeck.ui.DeckApp
import dev.pocketdeck.ui.DeckViewModel
import dev.pocketdeck.ui.theme.PocketDeckTheme

/** Compose host for onboarding and home. */
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
    }
}
