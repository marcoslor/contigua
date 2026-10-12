package dev.pocketdeck.ui

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.height
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import dev.pocketdeck.R
import dev.pocketdeck.app.formatPairingCode
import dev.pocketdeck.ui.theme.pairingCodeStyle

/**
 * In-app pairing prompt (docs/UX.md 3, docs/DESIGN.md §2 Pairing prompt). Shown
 * whenever a prompt is pending while the app is in the foreground; the
 * notification carries the same code with Allow/Deny actions.
 */
@Composable
fun PairingDialog(pending: PendingPairingUi, onAnswer: (Boolean) -> Unit) {
    AlertDialog(
        // The code stays up until Allow/Deny; dismissing would lose the prompt
        // that the notification is still offering to answer.
        onDismissRequest = {},
        icon = { Icon(painterResource(R.drawable.ic_link), contentDescription = null) },
        title = { Text(stringResource(R.string.pairing_title, pending.macName)) },
        text = {
            Column {
                Text(
                    text = formatPairingCode(pending.code),
                    style = pairingCodeStyle(),
                    color = MaterialTheme.colorScheme.primary,
                )
                Spacer(Modifier.height(8.dp))
                Text(
                    text = stringResource(R.string.pairing_hint),
                    style = MaterialTheme.typography.bodyMedium,
                )
            }
        },
        confirmButton = {
            TextButton(onClick = { onAnswer(true) }) {
                Text(stringResource(R.string.allow))
            }
        },
        dismissButton = {
            TextButton(onClick = { onAnswer(false) }) {
                Text(stringResource(R.string.deny))
            }
        },
    )
}
