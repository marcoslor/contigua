package app.contigua.app

import android.app.Application
import android.content.Intent
import android.provider.Settings
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.annotation.Config

/**
 * The exemption request has a fallback chain (docs/specs/phone-app.md
 * PHONE-19): when the dialog cannot be shown, the app's battery page and then
 * the system's exemption list still open, and a total failure is reported.
 */
@RunWith(AndroidJUnit4::class)
@Config(sdk = [34])
class BatteryExemptionTest {

    private val ctx: Application = ApplicationProvider.getApplicationContext()

    @Test
    fun `the dialog is tried before the app page and the system list`() {
        assertEquals(
            listOf(
                Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
                Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS,
            ),
            BatteryExemption.intents(ctx.packageName).map { it.action },
        )
    }

    @Test
    fun `the app package rides on the first two screens`() {
        val intents = BatteryExemption.intents(ctx.packageName)

        assertEquals("package:${ctx.packageName}", intents[0].dataString)
        assertEquals("package:${ctx.packageName}", intents[1].dataString)
    }

    @Test
    fun `a phone that cannot show the dialog opens the app's battery page`() {
        val tried = mutableListOf<String>()

        val opened = BatteryExemption.open(ctx) { intent ->
            tried += intent.action.orEmpty()
            if (intent.action == Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS) {
                throw android.content.ActivityNotFoundException("no handler")
            }
        }

        assertEquals(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, opened)
        assertEquals(2, tried.size)
    }

    @Test
    fun `a phone with no settings screen at all reports the failure`() {
        val tried = mutableListOf<String>()

        val opened = BatteryExemption.open(ctx) { intent ->
            tried += intent.action.orEmpty()
            throw android.content.ActivityNotFoundException("no handler")
        }

        assertNull(opened)
        assertEquals(3, tried.size)
    }

    @Test
    fun `the first screen that opens wins`() {
        val opened = BatteryExemption.open(ctx) { Intent(it.action) }

        assertEquals(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS, opened)
    }
}
