package dev.pocketdeck.ui

import android.text.format.DateUtils
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ElevatedCard
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ExtendedFloatingActionButton
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LargeTopAppBar
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SnackbarDuration
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.SnackbarResult
import androidx.compose.material3.SwipeToDismissBox
import androidx.compose.material3.SwipeToDismissBoxValue
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.material3.rememberSwipeToDismissBoxState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.nestedscroll.nestedScroll
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import dev.pocketdeck.R
import dev.pocketdeck.ui.theme.EmphasizedDecelerate
import dev.pocketdeck.ui.theme.ExitDurationMs
import dev.pocketdeck.ui.theme.SmallChangeDurationMs
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/** Home (docs/UX.md "Home", docs/DESIGN.md §2 Home). */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun HomeScreen(
    state: DeckUiState,
    onToggleEnabled: (Boolean) -> Unit,
    onToggleAllowConnections: (Boolean) -> Unit,
    onToggleAllowPairings: (Boolean) -> Unit,
    onStatusAction: (AttentionKind) -> Unit,
    onForget: (PairedMacUi) -> String,
    onUndoForget: (PairedMacUi) -> Unit,
    onPairNew: () -> Unit,
    relativeTime: (Long) -> String = { DateUtils.getRelativeTimeSpanString(it).toString() },
    snackbarHostState: SnackbarHostState = remember { SnackbarHostState() },
) {
    val scrollBehavior = TopAppBarDefaults.exitUntilCollapsedScrollBehavior()
    val scope = rememberCoroutineScope()
    val scrolled = scrollBehavior.state.collapsedFraction > 0f
    val horizontal = if (LocalConfiguration.current.screenWidthDp >= 600) 24.dp else 16.dp

    Scaffold(
        modifier = Modifier.nestedScroll(scrollBehavior.nestedScrollConnection),
        topBar = {
            LargeTopAppBar(
                title = { Text(stringResource(R.string.app_name)) },
                scrollBehavior = scrollBehavior,
            )
        },
        snackbarHost = { SnackbarHost(snackbarHostState) },
        floatingActionButton = {
            // A pairing the phone would refuse anyway is not offered.
            if (state.allowConnections && state.allowPairings) {
                ExtendedFloatingActionButton(
                    text = { Text(stringResource(R.string.home_pair_new)) },
                    icon = { Icon(painterResource(R.drawable.ic_qr_code_scanner), contentDescription = null) },
                    expanded = !scrolled,
                    onClick = onPairNew,
                )
            }
        },
    ) { padding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding)
                .verticalScroll(rememberScrollState())
                .padding(top = horizontal)
                .padding(bottom = 88.dp),
        ) {
            StatusCard(
                state = state,
                onAction = onStatusAction,
                modifier = Modifier.padding(horizontal = horizontal),
            )
            Spacer(Modifier.height(16.dp))
            SwitchRow(
                headline = stringResource(R.string.home_keep_running),
                checked = state.enabled,
                onToggle = onToggleEnabled,
            )
            HorizontalDivider(Modifier.padding(horizontal = horizontal, vertical = 8.dp))
            SwitchRow(
                headline = stringResource(R.string.home_allow_connections),
                checked = state.allowConnections,
                onToggle = onToggleAllowConnections,
            )
            SwitchRow(
                headline = stringResource(R.string.home_allow_pairings),
                checked = state.allowPairings,
                enabled = state.allowConnections,
                onToggle = onToggleAllowPairings,
                supporting = if (!state.allowConnections) {
                    stringResource(R.string.home_allow_pairings_hint)
                } else {
                    null
                },
            )
            Spacer(Modifier.height(24.dp))
            Text(
                text = stringResource(R.string.home_paired_title),
                style = MaterialTheme.typography.titleMedium,
                color = MaterialTheme.colorScheme.primary,
                modifier = Modifier.padding(horizontal = horizontal),
            )
            Spacer(Modifier.height(8.dp))
            if (state.paired.isEmpty()) {
                Text(
                    text = stringResource(R.string.home_no_paired),
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(horizontal = horizontal, vertical = 8.dp),
                )
            } else {
                // Relative times go stale while the screen stays visible: the
                // rows re-render on the next whole minute instead of on a timer
                // that keeps the UI busy between ticks.
                val now = rememberMinuteTick()
                state.paired.forEach { mac ->
                    key(mac.clientId) {
                        PairedMacRow(
                            mac = mac,
                            now = now,
                            relativeTime = relativeTime,
                            onForget = onForget,
                            onUndoForget = onUndoForget,
                            snackbarHostState = snackbarHostState,
                            scope = scope,
                        )
                    }
                }
            }
            if (dev.pocketdeck.server.DebugFlags.autoApprovePairing()) {
                Spacer(Modifier.height(8.dp))
                Text(
                    text = "Debug build: auto-approve pairing is on; any Mac on this network can connect",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(horizontal = horizontal, vertical = 8.dp),
                )
            }
            Spacer(Modifier.height(24.dp))
        }
    }
}

@Composable
private fun SwitchRow(
    headline: String,
    checked: Boolean,
    onToggle: (Boolean) -> Unit,
    enabled: Boolean = true,
    supporting: String? = null,
) {
    ListItem(
        headlineContent = { Text(headline) },
        supportingContent = supporting?.let { text -> { Text(text) } },
        trailingContent = {
            Switch(checked = checked, onCheckedChange = null, enabled = enabled)
        },
        modifier = Modifier.toggleable(
            value = checked,
            enabled = enabled,
            onValueChange = onToggle,
            role = androidx.compose.ui.semantics.Role.Switch,
        ),
    )
}

@Composable
private fun StatusCard(
    state: DeckUiState,
    onAction: (AttentionKind) -> Unit,
    modifier: Modifier = Modifier,
) {
    val status = state.status
    val (container, content, iconRes) = statusAppearance(status)
    val title = statusTitle(state)
    val subtitle = statusSubtitle(state)
    val actionLabel = statusActionLabel(status.attention)

    ElevatedCard(
        modifier = modifier
            .fillMaxWidth()
            .testTag("statusCard"),
        shape = MaterialTheme.shapes.extraLarge,
        colors = CardDefaults.elevatedCardColors(containerColor = container, contentColor = content),
    ) {
        Column(modifier = Modifier.padding(20.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(
                    painter = painterResource(iconRes),
                    contentDescription = null,
                    modifier = Modifier.size(40.dp),
                )
                Spacer(Modifier.width(16.dp))
                AnimatedContent(
                    targetState = title to subtitle,
                    transitionSpec = {
                        (fadeIn(tween(SmallChangeDurationMs)) +
                            slideInVertically(
                                animationSpec = tween(SmallChangeDurationMs, easing = EmphasizedDecelerate),
                            ) { it / 4 }) togetherWith
                            fadeOut(tween(ExitDurationMs))
                    },
                    label = "statusCard",
                    modifier = Modifier.weight(1f),
                ) { (headline, supporting) ->
                    Column {
                        Text(text = headline, style = MaterialTheme.typography.titleLarge)
                        Text(text = supporting, style = MaterialTheme.typography.bodyMedium)
                    }
                }
            }
            if (actionLabel != 0) {
                Spacer(Modifier.height(16.dp))
                FilledTonalButton(onClick = { onAction(status.attention) }) {
                    Text(stringResource(actionLabel))
                }
            }
        }
    }
}

@Composable
private fun statusTitle(state: DeckUiState): String = when (state.status.state) {
    StatusState.READY -> stringResource(R.string.status_ready)
    StatusState.CONNECTED -> stringResource(R.string.status_connected, state.connectedMac.orEmpty())
    StatusState.NEEDS_ATTENTION -> when (state.status.attention) {
        AttentionKind.CONNECTIONS_OFF -> stringResource(R.string.status_connections_off)
        AttentionKind.SHIZUKU_NOT_RUNNING -> stringResource(R.string.status_shizuku_not_running)
        AttentionKind.SHIZUKU_PERMISSION -> stringResource(R.string.status_permission)
        AttentionKind.NOTIFY_ACCESS -> stringResource(R.string.status_notify_access)
        else -> stringResource(R.string.status_ready)
    }

    StatusState.ERROR -> stringResource(R.string.status_error)
}

@Composable
private fun statusSubtitle(state: DeckUiState): String = when (state.status.state) {
    StatusState.READY -> if (state.status.untilTaskClosed) {
        stringResource(R.string.status_ready_until_closed_body)
    } else {
        stringResource(
            R.string.status_visible_on,
            state.wifiName ?: stringResource(R.string.wifi_default),
        )
    }

    StatusState.CONNECTED -> if (state.windows == 1) {
        stringResource(R.string.status_windows_one)
    } else {
        stringResource(R.string.status_windows, state.windows)
    }

    StatusState.NEEDS_ATTENTION -> when (state.status.attention) {
        AttentionKind.CONNECTIONS_OFF -> stringResource(R.string.status_connections_off_body)
        AttentionKind.SHIZUKU_NOT_RUNNING -> stringResource(R.string.status_shizuku_not_running_body)
        AttentionKind.SHIZUKU_PERMISSION -> stringResource(R.string.status_permission_body)
        AttentionKind.NOTIFY_ACCESS -> stringResource(R.string.status_notify_access_body)
        else -> ""
    }

    StatusState.ERROR -> stringResource(R.string.status_error_body)
}

@Composable
private fun statusAppearance(status: DeckStatus): Triple<Color, Color, Int> =
    when (status.state) {
        StatusState.READY -> Triple(
            MaterialTheme.colorScheme.secondaryContainer,
            MaterialTheme.colorScheme.onSecondaryContainer,
            R.drawable.ic_check_circle,
        )

        StatusState.CONNECTED -> Triple(
            MaterialTheme.colorScheme.primaryContainer,
            MaterialTheme.colorScheme.onPrimaryContainer,
            R.drawable.ic_desktop_mac,
        )

        StatusState.NEEDS_ATTENTION -> Triple(
            MaterialTheme.colorScheme.tertiaryContainer,
            MaterialTheme.colorScheme.onTertiaryContainer,
            R.drawable.ic_warning,
        )

        StatusState.ERROR -> Triple(
            MaterialTheme.colorScheme.errorContainer,
            MaterialTheme.colorScheme.onErrorContainer,
            R.drawable.ic_error,
        )
    }

private fun statusActionLabel(attention: AttentionKind): Int = when (attention) {
    AttentionKind.CONNECTIONS_OFF -> R.string.action_turn_on
    AttentionKind.SHIZUKU_NOT_RUNNING -> R.string.action_open_shizuku
    AttentionKind.SHIZUKU_PERMISSION -> R.string.action_allow
    AttentionKind.NOTIFY_ACCESS -> R.string.action_allow
    AttentionKind.RETRY -> R.string.action_retry
    AttentionKind.NONE -> 0
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun PairedMacRow(
    mac: PairedMacUi,
    now: Long,
    relativeTime: (Long) -> String,
    onForget: (PairedMacUi) -> String,
    onUndoForget: (PairedMacUi) -> Unit,
    snackbarHostState: SnackbarHostState,
    scope: CoroutineScope,
) {
    val undoLabel = stringResource(R.string.undo)
    val forgetLabel = stringResource(R.string.home_forget)
    val moreOptionsLabel = stringResource(R.string.home_more_options, mac.name)

    fun runForget() {
        val message = onForget(mac)
        scope.launch {
            val result = snackbarHostState.showSnackbar(
                message = message,
                actionLabel = undoLabel,
                duration = SnackbarDuration.Short,
            )
            if (result == SnackbarResult.ActionPerformed) onUndoForget(mac)
        }
    }

    val dismissState = rememberSwipeToDismissBoxState(
        confirmValueChange = { value ->
            if (value == SwipeToDismissBoxValue.EndToStart) {
                runForget()
                true
            } else {
                false
            }
        },
    )

    SwipeToDismissBox(
        state = dismissState,
        enableDismissFromStartToEnd = false,
        backgroundContent = {
            Box(
                modifier = Modifier
                    .fillMaxSize()
                    .clip(MaterialTheme.shapes.large)
                    .background(MaterialTheme.colorScheme.errorContainer),
                contentAlignment = Alignment.CenterEnd,
            ) {
                Icon(
                    painter = painterResource(R.drawable.ic_delete),
                    contentDescription = null,
                    tint = MaterialTheme.colorScheme.onErrorContainer,
                    modifier = Modifier.padding(end = 24.dp),
                )
            }
        },
    ) {
        var menuOpen by remember { mutableStateOf(false) }
        ListItem(
            leadingContent = { Icon(painterResource(R.drawable.ic_laptop_mac), contentDescription = null) },
            headlineContent = { Text(mac.name) },
            supportingContent = {
                when {
                    mac.connected -> Text(
                        text = stringResource(R.string.home_connected_now),
                        color = MaterialTheme.colorScheme.primary,
                    )
                    // now is read so the row recomposes on the minute tick.
                    mac.lastConnected in 1..now -> Text(
                        stringResource(R.string.home_last_connected, relativeTime(mac.lastConnected)),
                    )
                }
            },
            trailingContent = {
                Box {
                    IconButton(onClick = { menuOpen = true }) {
                        Icon(painterResource(R.drawable.ic_more_vert), contentDescription = moreOptionsLabel)
                    }
                    DropdownMenu(expanded = menuOpen, onDismissRequest = { menuOpen = false }) {
                        DropdownMenuItem(
                            text = { Text(forgetLabel) },
                            onClick = {
                                menuOpen = false
                                runForget()
                            },
                        )
                    }
                }
            },
        )
    }
    HorizontalDivider(
        Modifier.padding(
            horizontal = if (LocalConfiguration.current.screenWidthDp >= 600) 24.dp else 16.dp,
        ),
    )
}

/**
 * Wakes on the next whole minute so "Last connected …" stays true while the
 * screen is open. Only the ticker's value changes; nothing polls between ticks.
 */
@Composable
private fun rememberMinuteTick(): Long {
    var now by remember { mutableLongStateOf(System.currentTimeMillis()) }
    LaunchedEffect(Unit) {
        while (true) {
            delay((nextRelativeTick(System.currentTimeMillis()) - System.currentTimeMillis()).coerceAtLeast(1))
            now = System.currentTimeMillis()
        }
    }
    return now
}
