package app.contigua.server

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * MCP-103: the loading signal. A node visible to the user that is an
 * indeterminate progress bar, or an empty WebView, is "still loading".
 */
class LoadingSignalTest {

    @Test
    fun testAnIndeterminateProgressBarIsLoading() {
        assertTrue(LoadingSignal.loading("android.widget.ProgressBar", visibleToUser = true, hasRange = false, childCount = 0))
    }

    @Test
    fun testADeterminateProgressBarIsNot() {
        assertFalse(LoadingSignal.loading("android.widget.ProgressBar", visibleToUser = true, hasRange = true, childCount = 0))
    }

    @Test
    fun testAnInvisibleSpinnerIsNot() {
        assertFalse(LoadingSignal.loading("android.widget.ProgressBar", visibleToUser = false, hasRange = false, childCount = 0))
    }

    @Test
    fun testAnEmptyWebViewIsLoading() {
        assertTrue(LoadingSignal.loading("android.webkit.WebView", visibleToUser = true, hasRange = false, childCount = 0))
    }

    @Test
    fun testAWebViewWithContentIsNot() {
        assertFalse(LoadingSignal.loading("android.webkit.WebView", visibleToUser = true, hasRange = false, childCount = 3))
    }

    @Test
    fun testAProgressBarSubclassWithoutARangeIsLoading() {
        assertTrue(LoadingSignal.loading("com.example.FancyProgressBar", visibleToUser = true, hasRange = false, childCount = 0))
    }

    @Test
    fun testAnOrdinaryViewIsNotLoading() {
        assertFalse(LoadingSignal.loading("android.widget.TextView", visibleToUser = true, hasRange = false, childCount = 0))
    }
}
