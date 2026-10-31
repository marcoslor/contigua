package dev.pocketdeck.ui

import dev.pocketdeck.app.Prefs
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class UiStateTest {

    private val readyInput = StatusInput(
        enabled = true,
        shizukuRunning = true,
        shizukuGranted = true,
        port = 4711,
        connectedMac = null,
    )

    @Test
    fun `running server with nothing connected is ready`() {
        assertEquals(DeckStatus(StatusState.READY, AttentionKind.NONE), mapStatus(readyInput))
    }

    @Test
    fun `a connected Mac wins over ready`() {
        val status = mapStatus(readyInput.copy(connectedMac = "Studio Mac"))
        assertEquals(DeckStatus(StatusState.CONNECTED, AttentionKind.NONE), status)
    }

    @Test
    fun `a refused Mac version shows the update sentence until a session succeeds`() {
        val status = mapStatus(readyInput.copy(versionSentence = "Update PocketDeck on this Mac."))
        assertEquals(DeckStatus(StatusState.NEEDS_ATTENTION, AttentionKind.VERSION), status)
        val connected = mapStatus(
            readyInput.copy(connectedMac = "Studio Mac", versionSentence = null),
        )
        assertEquals(DeckStatus(StatusState.CONNECTED, AttentionKind.NONE), connected)
    }

    @Test
    fun `connections off needs attention with the turn-on action`() {
        val status = mapStatus(readyInput.copy(allowConnections = false))
        assertEquals(DeckStatus(StatusState.NEEDS_ATTENTION, AttentionKind.CONNECTIONS_OFF), status)
    }

    /// PAIR-6/M8: a prompt waiting while POST_NOTIFICATIONS is denied cannot
    /// show its notification; the home names the permission as the fix.
    @Test
    fun `a pairing prompt with notifications denied needs attention with allow`() {
        val status = mapStatus(readyInput.copy(pairNotifyMissing = true))
        assertEquals(DeckStatus(StatusState.NEEDS_ATTENTION, AttentionKind.PAIR_NOTIFY), status)
    }

    @Test
    fun `a granted notification permission leaves the pairing prompt alone`() {
        assertEquals(DeckStatus(StatusState.READY, AttentionKind.NONE), mapStatus(readyInput))
    }

    @Test
    fun `background off is ready and informational, not a warning`() {
        // Off only means "stops when the task is swiped away"; it is not a
        // connection problem, so the card must not warn or offer a fix.
        val status = mapStatus(readyInput.copy(enabled = false))
        assertEquals(StatusState.READY, status.state)
        assertEquals(AttentionKind.NONE, status.attention)
    }

    @Test
    fun `connections off outranks the background switch`() {
        val status = mapStatus(readyInput.copy(enabled = false, allowConnections = false))
        assertEquals(AttentionKind.CONNECTIONS_OFF, status.attention)
    }

    @Test
    fun `shizuku not running needs attention`() {
        val status = mapStatus(readyInput.copy(shizukuRunning = false))
        assertEquals(DeckStatus(StatusState.NEEDS_ATTENTION, AttentionKind.SHIZUKU_NOT_RUNNING), status)
    }

    @Test
    fun `shizuku permission missing needs attention`() {
        val status = mapStatus(readyInput.copy(shizukuGranted = false))
        assertEquals(DeckStatus(StatusState.NEEDS_ATTENTION, AttentionKind.SHIZUKU_PERMISSION), status)
    }

    @Test
    fun `enabled with everything healthy but no port is an error with retry`() {
        assertEquals(
            DeckStatus(StatusState.ERROR, AttentionKind.RETRY),
            mapStatus(readyInput.copy(port = -1)),
        )
    }

    @Test
    fun `a missing notification grant while the Mac asked needs attention`() {
        // The phone's own switch is gone: the Mac's opt-in plus the listener
        // grant is the whole gate (docs/design/notify.md).
        val status = mapStatus(readyInput.copy(connectedMac = "Studio Mac", notifyNoAccess = true))
        assertEquals(DeckStatus(StatusState.NEEDS_ATTENTION, AttentionKind.NOTIFY_ACCESS), status)
    }

    @Test
    fun `no attention for notification access once the Mac is not asking`() {
        assertEquals(AttentionKind.NONE, mapStatus(readyInput.copy(notifyNoAccess = false)).attention)
    }

    @Test
    fun `a broken shizuku outranks a notification grant`() {
        val status = mapStatus(readyInput.copy(shizukuGranted = false, notifyNoAccess = true))
        assertEquals(AttentionKind.SHIZUKU_PERMISSION, status.attention)
    }

    @Test
    fun `connections off outranks a broken shizuku`() {
        val status = mapStatus(StatusInput(false, false, false, -1, null, allowConnections = false))
        assertEquals(AttentionKind.CONNECTIONS_OFF, status.attention)
    }

    @Test
    fun `shizuku row follows installed, running, granted order`() {
        assertEquals(ShizukuUiState.NOT_INSTALLED, shizukuUiState(installed = false, running = false, granted = false))
        assertEquals(ShizukuUiState.NOT_RUNNING, shizukuUiState(installed = true, running = false, granted = false))
        assertEquals(ShizukuUiState.PERMISSION_NEEDED, shizukuUiState(installed = true, running = true, granted = false))
        assertEquals(ShizukuUiState.READY, shizukuUiState(installed = true, running = true, granted = true))
    }

    @Test
    fun `welcome never auto-advances`() {
        val input = OnboardingInput(true, true, true, true, 3)
        assertFalse(isOnboardingComplete(OnboardingStep.WELCOME, input))
    }

    @Test
    fun `shizuku step needs running and granted`() {
        assertFalse(isOnboardingComplete(OnboardingStep.SHIZUKU, OnboardingInput(true, false, false, false, 0)))
        assertTrue(isOnboardingComplete(OnboardingStep.SHIZUKU, OnboardingInput(true, true, false, false, 0)))
    }

    @Test
    fun `notifications step waits for the grant and a real exemption`() {
        assertFalse(isOnboardingComplete(OnboardingStep.NOTIFICATIONS, OnboardingInput(false, false, true, false, 0)))
        assertFalse(isOnboardingComplete(OnboardingStep.NOTIFICATIONS, OnboardingInput(false, false, false, true, 0)))
        // Asked but still restricted: the step must not claim "keeps running".
        assertFalse(
            isOnboardingComplete(
                OnboardingStep.NOTIFICATIONS,
                OnboardingInput(false, false, true, true, 0, batteryExempt = false),
            ),
        )
        assertTrue(
            isOnboardingComplete(
                OnboardingStep.NOTIFICATIONS,
                OnboardingInput(false, false, true, true, 0, batteryExempt = true),
            ),
        )
    }

    @Test
    fun `pair step completes on the first pairing`() {
        assertFalse(isOnboardingComplete(OnboardingStep.PAIR, OnboardingInput(false, false, false, false, 0)))
        assertTrue(isOnboardingComplete(OnboardingStep.PAIR, OnboardingInput(false, false, false, false, 1)))
    }

    @Test
    fun `only the live client's paired row is connected`() {
        val rows = listOf(
            PairedMacUi("a", "Alpha", 10),
            PairedMacUi("b", "Beta", 20),
        )
        val live = pairedRows(rows, "b")
        assertEquals(listOf("b", "a"), live.map { it.clientId })
        assertEquals(listOf(true, false), live.map { it.connected })
        assertEquals(rows.map { false }, pairedRows(rows, null).map { it.connected })
    }

    @Test
    fun `keep running is off until the pref is on`() {
        assertEquals(KeepRunningState.OFF, keepRunningState(enabled = false, exempt = false))
        assertEquals(KeepRunningState.OFF, keepRunningState(enabled = false, exempt = true))
    }

    @Test
    fun `keep running on without the exemption says the restriction is still there`() {
        assertEquals(KeepRunningState.ON_RESTRICTED, keepRunningState(enabled = true, exempt = false))
    }

    @Test
    fun `keep running on with the exemption is the settled state`() {
        assertEquals(KeepRunningState.ON_EXEMPT, keepRunningState(enabled = true, exempt = true))
    }

    @Test
    fun `a session start or end stamps only that Mac`() {
        val macs = listOf(
            Prefs.PairedMac("a", "Alpha", "f".repeat(64), 10),
            Prefs.PairedMac("b", "Beta", "e".repeat(64), 20),
        )
        val after = Prefs.stamped(macs, "a", 99)
        assertEquals(99L, after.first { it.clientId == "a" }.lastConnected)
        assertEquals(20L, after.first { it.clientId == "b" }.lastConnected)
    }

    @Test
    fun `the relative-time ticker wakes on the next whole minute`() {
        val now = 1_700_000_030_000L
        assertEquals(10_000L, nextRelativeTick(now) - now)
        assertEquals(0L, nextRelativeTick(now) % RELATIVE_TICK_MS)
        assertEquals(60_000L, nextRelativeTick(0L))
    }
}
