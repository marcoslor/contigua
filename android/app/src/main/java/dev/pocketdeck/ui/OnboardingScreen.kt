package dev.pocketdeck.ui

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.ListItem
import androidx.compose.material3.ListItemDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedCard
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import dev.pocketdeck.R
import dev.pocketdeck.ui.theme.EmphasizedDecelerate
import kotlinx.coroutines.launch

/**
 * The four-step first-run pager (docs/UX.md "Android app", docs/DESIGN.md §2
 * Onboarding). Pages never swipe; each advances automatically once its condition
 * is met, except Welcome, which uses its button.
 */
@Composable
fun OnboardingScreen(
    state: DeckUiState,
    onGetShizuku: () -> Unit,
    onOpenShizuku: () -> Unit,
    onAllowShizuku: () -> Unit,
    onAllowNotifications: () -> Unit,
    onIgnoreBattery: () -> Unit,
    onScanQr: () -> Unit,
    onFinished: () -> Unit,
    initialPage: Int = 0,
    autoAdvance: Boolean = true,
    snackbarHostState: SnackbarHostState = remember { SnackbarHostState() },
) {
    val steps = OnboardingStep.entries
    val pagerState = rememberPagerState(initialPage = initialPage, pageCount = { steps.size })
    val scope = rememberCoroutineScope()
    val progress by animateFloatAsState(
        targetValue = (pagerState.currentPage + 1) / steps.size.toFloat(),
        animationSpec = tween(300),
        label = "onboardingProgress",
    )

    val input = state.onboarding
    LaunchedEffect(pagerState.currentPage, input, autoAdvance) {
        if (!autoAdvance) return@LaunchedEffect
        val step = steps[pagerState.currentPage]
        if (!isOnboardingComplete(step, input)) return@LaunchedEffect
        if (step == OnboardingStep.PAIR) {
            onFinished()
        } else {
            pagerState.animateScrollToPage(
                pagerState.currentPage + 1,
                animationSpec = tween(500, easing = EmphasizedDecelerate),
            )
        }
    }

    Scaffold(snackbarHost = { SnackbarHost(snackbarHostState) }) { padding ->
        Column(modifier = Modifier.fillMaxSize().padding(padding)) {
            LinearProgressIndicator(
                progress = { progress },
                modifier = Modifier.fillMaxWidth(),
            )
            HorizontalPager(
                state = pagerState,
                userScrollEnabled = false,
                modifier = Modifier.weight(1f),
            ) { page ->
                when (steps[page]) {
                    OnboardingStep.WELCOME -> WelcomePage(
                        onGetStarted = {
                            scope.launch {
                                pagerState.animateScrollToPage(1, animationSpec = tween(500, easing = EmphasizedDecelerate))
                            }
                        },
                    )

                    OnboardingStep.SHIZUKU -> ShizukuPage(
                        shizuku = state.shizuku,
                        onGetShizuku = onGetShizuku,
                        onOpenShizuku = onOpenShizuku,
                        onAllow = onAllowShizuku,
                    )

                    OnboardingStep.NOTIFICATIONS -> NotificationsPage(
                        notificationsGranted = state.notificationsGranted,
                        onAllow = onAllowNotifications,
                        onIgnoreBattery = onIgnoreBattery,
                    )

                    OnboardingStep.PAIR -> PairPage(onScanQr = onScanQr)
                }
            }
        }
    }
}

@Composable
private fun PageColumn(
    iconRes: Int,
    title: String,
    body: String,
    content: @Composable ColumnScope.() -> Unit = {},
) {
    Column(
        modifier = Modifier.fillMaxSize().padding(24.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Spacer(Modifier.height(48.dp))
        Icon(
            painter = painterResource(iconRes),
            contentDescription = null,
            tint = MaterialTheme.colorScheme.primary,
            modifier = Modifier.size(96.dp),
        )
        Spacer(Modifier.height(24.dp))
        Text(
            text = title,
            style = MaterialTheme.typography.headlineMedium,
            textAlign = TextAlign.Center,
        )
        Spacer(Modifier.height(8.dp))
        Text(
            text = body,
            style = MaterialTheme.typography.bodyLarge,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            textAlign = TextAlign.Center,
        )
        content()
    }
}

@Composable
private fun WelcomePage(onGetStarted: () -> Unit) {
    PageColumn(
        iconRes = R.drawable.ic_desktop_mac,
        title = stringResource(R.string.onboarding_welcome_title),
        body = stringResource(R.string.onboarding_welcome_body),
    ) {
        Spacer(Modifier.weight(1f))
        Button(onClick = onGetStarted, modifier = Modifier.fillMaxWidth()) {
            Text(stringResource(R.string.onboarding_get_started))
        }
    }
}

@Composable
private fun ShizukuPage(
    shizuku: ShizukuUiState,
    onGetShizuku: () -> Unit,
    onOpenShizuku: () -> Unit,
    onAllow: () -> Unit,
) {
    PageColumn(
        iconRes = R.drawable.ic_phone_android,
        title = stringResource(R.string.onboarding_shizuku_title),
        body = stringResource(R.string.onboarding_shizuku_body),
    ) {
        Spacer(Modifier.height(24.dp))
        OutlinedCard(modifier = Modifier.fillMaxWidth()) {
            ListItem(
                headlineContent = {
                    Text(
                        text = stringResource(shizukuStatusLabel(shizuku)),
                        style = MaterialTheme.typography.titleMedium,
                    )
                },
                leadingContent = {
                    Icon(
                        painter = painterResource(shizukuStatusIcon(shizuku)),
                        contentDescription = null,
                        tint = if (shizuku == ShizukuUiState.READY) {
                            MaterialTheme.colorScheme.primary
                        } else {
                            MaterialTheme.colorScheme.onSurfaceVariant
                        },
                    )
                },
                colors = ListItemDefaults.colors(containerColor = Color.Transparent),
            )
        }
        if (shizuku == ShizukuUiState.NOT_RUNNING) {
            Spacer(Modifier.height(24.dp))
            Text(
                text = stringResource(R.string.shizuku_how_to),
                style = MaterialTheme.typography.titleMedium,
                modifier = Modifier.align(Alignment.Start),
            )
            Spacer(Modifier.height(8.dp))
            HowToLine(1, stringResource(R.string.shizuku_how_1))
            HowToLine(2, stringResource(R.string.shizuku_how_2))
            HowToLine(3, stringResource(R.string.shizuku_how_3))
        }
        Spacer(Modifier.weight(1f))
        when (shizuku) {
            ShizukuUiState.NOT_INSTALLED -> Button(onClick = onGetShizuku, modifier = Modifier.fillMaxWidth()) {
                Text(stringResource(R.string.shizuku_get))
            }

            ShizukuUiState.NOT_RUNNING -> Button(onClick = onOpenShizuku, modifier = Modifier.fillMaxWidth()) {
                Text(stringResource(R.string.shizuku_open))
            }

            ShizukuUiState.PERMISSION_NEEDED -> Button(onClick = onAllow, modifier = Modifier.fillMaxWidth()) {
                Text(stringResource(R.string.shizuku_allow))
            }

            ShizukuUiState.READY -> Unit
        }
    }
}

@Composable
private fun HowToLine(number: Int, text: String) {
    Row(modifier = Modifier.fillMaxWidth().padding(vertical = 2.dp), verticalAlignment = Alignment.Top) {
        Text(
            text = "$number.",
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.primary,
            modifier = Modifier.width(24.dp),
        )
        Text(
            text = text,
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

@Composable
private fun NotificationsPage(
    notificationsGranted: Boolean,
    onAllow: () -> Unit,
    onIgnoreBattery: () -> Unit,
) {
    PageColumn(
        iconRes = R.drawable.ic_notifications,
        title = stringResource(R.string.onboarding_notifications_title),
        body = stringResource(R.string.onboarding_notifications_body),
    ) {
        Spacer(Modifier.weight(1f))
        Text(
            text = stringResource(R.string.onboarding_notifications_battery_body),
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            textAlign = TextAlign.Center,
        )
        Spacer(Modifier.height(8.dp))
        OutlinedButton(onClick = onIgnoreBattery, modifier = Modifier.fillMaxWidth()) {
            Text(stringResource(R.string.onboarding_notifications_battery))
        }
        Spacer(Modifier.height(8.dp))
        Button(
            onClick = onAllow,
            enabled = !notificationsGranted,
            modifier = Modifier.fillMaxWidth(),
        ) {
            Text(stringResource(R.string.allow))
        }
    }
}

@Composable
private fun PairPage(onScanQr: () -> Unit) {
    PageColumn(
        iconRes = R.drawable.ic_link,
        title = stringResource(R.string.onboarding_pair_title),
        body = stringResource(R.string.onboarding_pair_body),
    ) {
        Spacer(Modifier.weight(1f))
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            CircularProgressIndicator(modifier = Modifier.size(24.dp), strokeWidth = 2.dp)
            Text(
                text = stringResource(R.string.onboarding_pair_waiting),
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
        Spacer(Modifier.height(16.dp))
        OutlinedButton(onClick = onScanQr, modifier = Modifier.fillMaxWidth()) {
            Icon(painter = painterResource(R.drawable.ic_qr_code_scanner), contentDescription = null)
            Spacer(Modifier.width(8.dp))
            Text(stringResource(R.string.onboarding_pair_scan))
        }
    }
}

private fun shizukuStatusLabel(state: ShizukuUiState): Int = when (state) {
    ShizukuUiState.NOT_INSTALLED -> R.string.shizuku_status_not_installed
    ShizukuUiState.NOT_RUNNING -> R.string.shizuku_status_not_running
    ShizukuUiState.PERMISSION_NEEDED -> R.string.shizuku_status_permission
    ShizukuUiState.READY -> R.string.shizuku_status_ready
}

private fun shizukuStatusIcon(state: ShizukuUiState): Int = when (state) {
    ShizukuUiState.READY -> R.drawable.ic_check_circle
    else -> R.drawable.ic_warning
}
