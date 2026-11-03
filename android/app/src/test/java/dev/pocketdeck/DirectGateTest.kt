package dev.pocketdeck

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * The gate's K1 half (docs/design/direct-link.md §1.3, transport DIRECT-2). A
 * public build compiles no direct provider class and its merged manifest asks
 * for no Aware permission; a direct build does both. The branch keeps
 * `src/direct/` on disk either way, so the check is what the build *uses*, not
 * whether the directory exists.
 */
class DirectGateTest {

    @Test
    fun theProviderFollowsTheBuildFlag() {
        val provider = runCatching { Class.forName("dev.pocketdeck.direct.DirectConfig") }.isSuccess
        assertEquals("the direct provider follows -Ppocketdeck.direct", BuildConfig.DIRECT, provider)
    }

    @Test
    fun theMergedManifestCarriesThePermissionOnlyInADirectBuild() {
        val manifest = mergedDebugManifest()
        assertNotNull("assembleDebug writes the merged debug manifest", manifest)
        val hasAwarePermission = manifest!!.readText().contains("NEARBY_WIFI_DEVICES")
        assertEquals(
            "NEARBY_WIFI_DEVICES follows the direct property",
            BuildConfig.DIRECT,
            hasAwarePermission,
        )
    }

    @Test
    fun aPublicBuildCompilesNoDirectClass() {
        if (BuildConfig.DIRECT) return
        assertFalse(
            "the public class output has no dev/pocketdeck/direct tree",
            File("build/tmp/kotlin-classes/debug/dev/pocketdeck/direct").exists(),
        )
        assertFalse(
            "no direct provider class is loadable in a public build",
            runCatching { Class.forName("dev.pocketdeck.direct.AwareLink") }.isSuccess,
        )
    }

    private fun mergedDebugManifest(): File? =
        File("build/intermediates").walkTopDown()
            .filter {
                it.isFile && it.name == "AndroidManifest.xml" &&
                    it.invariantSeparatorsPath.contains("/merged_manifest") &&
                    it.invariantSeparatorsPath.contains("/debug/")
            }
            .minByOrNull { it.path.length }
}
