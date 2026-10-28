package dev.pocketdeck.server

import android.content.pm.ActivityInfo
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * WIN-24: `apps` says per app whether a second instance can run. Three facts
 * must agree: the launcher activity's `launchMode`, its `documentLaunchMode`,
 * and the app's own `PROPERTY_SUPPORTS_MULTI_INSTANCE_SYSTEM_UI` (or the
 * allow-list for an app found to work without the property).
 */
class MultiInstancePolicyTest {

    /** Every launchMode, with whether a second task can be created from it. */
    private val launchModes = listOf(
        ActivityInfo.LAUNCH_MULTIPLE to true,
        ActivityInfo.LAUNCH_SINGLE_TOP to true,
        ActivityInfo.LAUNCH_SINGLE_TASK to false,
        ActivityInfo.LAUNCH_SINGLE_INSTANCE to false,
        ActivityInfo.LAUNCH_SINGLE_INSTANCE_PER_TASK to true,
    )

    /** Every documentLaunchMode, with whether it lets a second task exist. */
    private val documentLaunchModes = listOf(
        ActivityInfo.DOCUMENT_LAUNCH_NONE to true,
        ActivityInfo.DOCUMENT_LAUNCH_INTO_EXISTING to true,
        ActivityInfo.DOCUMENT_LAUNCH_ALWAYS to true,
        ActivityInfo.DOCUMENT_LAUNCH_NEVER to false,
    )

    @Test
    fun `every launchMode and documentLaunchMode follows the declared modes`() {
        for ((launchMode, modeAllows) in launchModes) {
            for ((documentLaunchMode, documentAllows) in documentLaunchModes) {
                val facts = LaunchFacts(launchMode, documentLaunchMode, multiInstanceProperty = true)
                val expected = modeAllows && documentAllows
                assertTrue(
                    "launchMode=$launchMode documentLaunchMode=$documentLaunchMode with the property",
                    MultiInstancePolicy.multi("com.example.app", facts, allowList = emptySet()) == expected,
                )
            }
        }
    }

    @Test
    fun `singleInstancePerTask and singleTop are allowed, singleTask and singleInstance are not`() {
        for ((launchMode, allowed) in launchModes) {
            val facts = LaunchFacts(launchMode, ActivityInfo.DOCUMENT_LAUNCH_NONE, multiInstanceProperty = true)
            assertTrue("launchMode=$launchMode", MultiInstancePolicy.multi("com.example.app", facts, emptySet()) == allowed)
        }
    }

    @Test
    fun `documentLaunchMode never refuses a second task whatever the launch mode`() {
        for ((launchMode, _) in launchModes) {
            val facts = LaunchFacts(launchMode, ActivityInfo.DOCUMENT_LAUNCH_NEVER, multiInstanceProperty = true)
            assertFalse("launchMode=$launchMode", MultiInstancePolicy.multi("com.example.app", facts, emptySet()))
        }
    }

    @Test
    fun `without the property an app is not multi unless it is on the allow-list`() {
        val chrome = LaunchFacts(ActivityInfo.LAUNCH_SINGLE_INSTANCE_PER_TASK, ActivityInfo.DOCUMENT_LAUNCH_INTO_EXISTING, multiInstanceProperty = false)
        assertFalse("the allow-list is empty today", MultiInstancePolicy.multi("com.example.app", chrome, emptySet()))
        assertTrue("listed", MultiInstancePolicy.multi("com.example.app", chrome, setOf("com.example.app")))
        assertFalse("listed but its modes refuse", MultiInstancePolicy.multi(
            "com.example.other",
            chrome.copy(launchMode = ActivityInfo.LAUNCH_SINGLE_TASK),
            setOf("com.example.other"),
        ))
    }

    @Test
    fun `the allow-list is the phone's own list and is empty today`() {
        assertTrue("nothing is allow-listed yet", MultiInstancePolicy.ALLOW_LIST.isEmpty())
        // A blank entry would enable an app that declares nothing.
        val facts = LaunchFacts(ActivityInfo.LAUNCH_MULTIPLE, ActivityInfo.DOCUMENT_LAUNCH_NONE, multiInstanceProperty = false)
        assertFalse(MultiInstancePolicy.multi("", facts, setOf("")))
    }
}
