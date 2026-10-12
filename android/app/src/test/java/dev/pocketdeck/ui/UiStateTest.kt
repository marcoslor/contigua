package dev.pocketdeck.ui

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
        val status = mapStatus(readyInput.copy(connectedMac = "Marcos's MacBook"))
        assertEquals(DeckStatus(StatusState.CONNECTED, AttentionKind.NONE), status)
    }

    @Test
    fun `connections off needs attention with the turn-on action`() {
        val status = mapStatus(readyInput.copy(enabled = false))
        assertEquals(DeckStatus(StatusState.NEEDS_ATTENTION, AttentionKind.CONNECTIONS_OFF), status)
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
    fun `connections off outranks a broken shizuku`() {
        val status = mapStatus(StatusInput(false, false, false, -1, null))
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
    fun `notifications step needs permission and one battery request`() {
        assertFalse(isOnboardingComplete(OnboardingStep.NOTIFICATIONS, OnboardingInput(false, false, true, false, 0)))
        assertFalse(isOnboardingComplete(OnboardingStep.NOTIFICATIONS, OnboardingInput(false, false, false, true, 0)))
        assertTrue(isOnboardingComplete(OnboardingStep.NOTIFICATIONS, OnboardingInput(false, false, true, true, 0)))
    }

    @Test
    fun `pair step completes on the first pairing`() {
        assertFalse(isOnboardingComplete(OnboardingStep.PAIR, OnboardingInput(false, false, false, false, 0)))
        assertTrue(isOnboardingComplete(OnboardingStep.PAIR, OnboardingInput(false, false, false, false, 1)))
    }
}
