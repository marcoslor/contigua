package dev.pocketdeck.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBars
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import dev.pocketdeck.R
import dev.pocketdeck.app.formatPairingCode
import dev.pocketdeck.ui.theme.pairingCodeStyle

/**
 * In-app pairing prompt (docs/UX.md 3, docs/DESIGN.md §2 Pairing prompt). Shown
 * whenever a prompt is pending while the app is in the foreground; the
 * notification carries the same code with Allow/Deny actions.
 *
 * A floating card with 16 dp side margins and 16 dp above the navigation-bar
 * inset, rounded on all corners. It floats over the scrim; Deny/Allow keep the
 * AlertDialog's end-aligned button row.
 */
@Composable
fun PairingDialog(
    pending: PendingPairingUi,
    onAnswer: (Boolean) -> Unit,
    // Test seam: the real insets come from the window; tests pass a fake one.
    navigationBars: WindowInsets = WindowInsets.navigationBars,
) {
    Dialog(
        // The code stays up until Allow/Deny; dismissing would lose the prompt
        // that the notification is still offering to answer.
        onDismissRequest = {},
        // We place the card ourselves: the platform's dialog window inherits the
        // activity theme here and on API 36 edge-to-edge it lands under the
        // gesture bar. A full-screen window plus our own bottom alignment keeps
        // the same card on every OEM and nav mode.
        properties = DialogProperties(
            usePlatformDefaultWidth = false,
            decorFitsSystemWindows = false,
        ),
    ) {
        Box(Modifier.fillMaxSize()) {
            Surface(
                modifier = Modifier
                    .align(Alignment.BottomCenter)
                    .windowInsetsPadding(navigationBars)
                    .padding(horizontal = 16.dp)
                    .padding(bottom = 16.dp)
                    .fillMaxWidth()
                    .testTag("pairingCard"),
                shape = MaterialTheme.shapes.extraLarge,
                color = MaterialTheme.colorScheme.surfaceContainerHigh,
                tonalElevation = 6.dp,
                shadowElevation = 6.dp,
            ) {
                Column(Modifier.padding(24.dp)) {
                    Icon(
                        painter = painterResource(R.drawable.ic_link),
                        contentDescription = null,
                        tint = MaterialTheme.colorScheme.secondary,
                    )
                    Spacer(Modifier.height(16.dp))
                    Text(
                        text = stringResource(R.string.pairing_title, pending.macName),
                        style = MaterialTheme.typography.headlineSmall,
                    )
                    Spacer(Modifier.height(16.dp))
                    Text(
                        text = formatPairingCode(pending.code),
                        style = pairingCodeStyle(),
                        color = MaterialTheme.colorScheme.primary,
                    )
                    Spacer(Modifier.height(8.dp))
                    Text(
                        text = stringResource(R.string.pairing_hint),
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                    Spacer(Modifier.height(24.dp))
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.End,
                    ) {
                        TextButton(onClick = { onAnswer(false) }) {
                            Text(stringResource(R.string.deny))
                        }
                        Spacer(Modifier.width(8.dp))
                        TextButton(onClick = { onAnswer(true) }) {
                            Text(stringResource(R.string.allow))
                        }
                    }
                }
            }
        }
    }
}
