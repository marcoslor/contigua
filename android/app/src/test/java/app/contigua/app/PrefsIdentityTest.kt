package app.contigua.app

import android.app.Application
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import app.contigua.e2ee.IdentityPin
import app.contigua.e2ee.PhoneIdentity
import app.contigua.proto.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.annotation.Config

/**
 * What the app tells the shell service on every push: the identity fingerprint
 * the service compares, and the paired Macs. Forget All Macs… rotates the
 * identity and empties the list (docs/specs/pairing.md PAIR-19/PAIR-20).
 */
@RunWith(AndroidJUnit4::class)
@Config(sdk = [34])
class PrefsIdentityTest {

    private val ctx: Application = ApplicationProvider.getApplicationContext()

    @Before
    fun clean() {
        ctx.filesDir.deleteRecursively()
        ctx.filesDir.mkdirs()
        ctx.getSharedPreferences("contigua", android.content.Context.MODE_PRIVATE)
            .edit().clear().commit()
    }

    private fun pushed(): Map<String, Any?> =
        Json.parseObject(Prefs.serviceStateJson(ctx))

    @Test
    fun `the push carries the identity fingerprint that matches its certificate`() {
        val self = Json.asObject(pushed()["self"])!!
        val fp = Json.str(pushed()["identityFp"])

        assertEquals(IdentityPin.of(Json.str(self["certPem"])!!), fp)
    }

    @Test
    fun `the push carries every paired Mac`() {
        Prefs.addPaired(ctx, Prefs.PairedMac("1a2b3c4d", "Studio Mac", "aa".repeat(32)))
        Prefs.addPaired(ctx, Prefs.PairedMac("5e6f7a8b", "Pixel 8", "bb".repeat(32)))

        val clients = Json.asList(pushed()["clients"])!!.map { Json.asObject(it)!! }

        assertEquals(listOf("1a2b3c4d", "5e6f7a8b"), clients.map { Json.str(it["clientId"]) })
    }

    @Test
    fun `forget all Macs rotates the identity and drops every pairing`() {
        val before = Json.str(pushed()["identityFp"])!!
        Prefs.addPaired(ctx, Prefs.PairedMac("1a2b3c4d", "Studio Mac", "aa".repeat(32)))
        Prefs.setPendingQr(ctx, Prefs.PendingQr("1a2b3c4d", "Studio Mac", "aa".repeat(32), "cc".repeat(16), System.currentTimeMillis()))

        Prefs.forgetAll(ctx)

        val after = Json.str(pushed()["identityFp"])!!
        assertNotEquals("the identity must be new", before, after)
        assertEquals(0, Json.asList(pushed()["clients"])!!.size)
        assertEquals(null, Prefs.pendingQr(ctx))
        assertTrue("the identity file is still there", PhoneIdentity.load(ctx) != null)
    }

    @Test
    fun `forget all Macs keeps the device id`() {
        val id = Prefs.deviceId(ctx)
        Prefs.addPaired(ctx, Prefs.PairedMac("1a2b3c4d", "Studio Mac", "aa".repeat(32)))

        Prefs.forgetAll(ctx)

        assertEquals(id, Prefs.deviceId(ctx))
    }

    @Test
    fun `forget all Macs asks the shell to remove the association until a push carried it`() {
        // PHONE-24: no removal is owed before Forget All Macs.
        assertEquals(false, Json.bool(pushed()["forgetAssociation"]))

        Prefs.forgetAll(ctx)
        assertEquals(true, Json.bool(pushed()["forgetAssociation"]))

        // A push that never reached a shell service keeps it owed.
        runCatching { Prefs.pushState(ctx) { error("shell service not bound") } }
        assertTrue(Prefs.associationRemovalOwed(ctx))

        // The push that went through carried it, and the next one does not.
        val sent = mutableListOf<String>()
        Prefs.pushState(ctx) { sent.add(it) }
        assertEquals(true, Json.bool(Json.parseObject(sent.single())["forgetAssociation"]))
        assertEquals(false, Prefs.associationRemovalOwed(ctx))
        assertEquals(false, Json.bool(pushed()["forgetAssociation"]))
    }
}
