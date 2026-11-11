package app.contigua.app

import android.app.Application
import android.app.PendingIntent
import android.os.ParcelFileDescriptor
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import app.contigua.IDeckCallback
import app.contigua.IDeckService
import app.contigua.e2ee.IdentityPin
import app.contigua.e2ee.PhoneIdentity
import app.contigua.proto.Json
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.annotation.Config

/**
 * ISS-15: the service-ready path starts the server only with the app's
 * identity. A fresh app generates it before `startServer`; an existing one is
 * served untouched (the same fingerprint).
 */
@RunWith(AndroidJUnit4::class)
@Config(sdk = [34])
class ServiceStartIdentityTest {

    private val ctx: Application = ApplicationProvider.getApplicationContext()

    @Before
    fun clean() {
        ctx.filesDir.deleteRecursively()
        ctx.filesDir.mkdirs()
        ctx.getSharedPreferences("contigua", android.content.Context.MODE_PRIVATE)
            .edit().clear().commit()
        Prefs.setAllowConnections(ctx, false) // no NSD registration in the JVM
    }

    @After
    fun tearDown() {
        Prefs.setAllowConnections(ctx, true)
    }

    /** Calls the service's ready path the way Shizuku's binder does. */
    private fun ready(service: DeckForegroundService, svc: IDeckService) = service.onServiceReady(svc)

    @Test
    fun `a service-ready with no identity generates it before the server starts`() {
        assertTrue("the test did not start from a fresh app", PhoneIdentity.load(ctx) == null)
        val seenAtStart = java.util.concurrent.atomic.AtomicReference<Boolean>()
        val fake = FakeDeckService()
        fake.onStart = { seenAtStart.set(PhoneIdentity.load(ctx) != null) }
        val controller = Robolectric.buildService(DeckForegroundService::class.java).create()

        ready(controller.get(), fake)

        assertEquals("startServer was not called", 1, fake.startCalls.get())
        assertTrue("the server started with no identity", seenAtStart.get() == true)
        val identity = PhoneIdentity.load(ctx)
        assertNotNull("no identity after the service-ready path", identity)
        assertEquals("the push did not carry the identity", identity!!.certPem,
            Json.str(Json.asObject(Json.parseObject(fake.pushed!!)["self"])!!["certPem"]))
        assertTrue("the push came after the server start",
            fake.calls.indexOf("setPairedClients") < fake.calls.indexOf("startServer"))
        controller.destroy()
    }

    @Test
    fun `a service-ready keeps the identity it already has`() {
        val before = PhoneIdentity.ensure(ctx)
        val beforeFp = IdentityPin.of(before.certPem)
        val fake = FakeDeckService()
        val controller = Robolectric.buildService(DeckForegroundService::class.java).create()

        ready(controller.get(), fake)

        val after = PhoneIdentity.load(ctx)
        assertNotNull("the identity file went missing", after)
        assertEquals("the identity rotated on start", beforeFp, IdentityPin.of(after!!.certPem))
        assertEquals(before.certPem, after.certPem)
        val pushed = Json.asObject(Json.parseObject(fake.pushed!!)["self"])!!
        assertEquals(before.certPem, Json.str(pushed["certPem"]))
        controller.destroy()
    }

    /** Records what the app pushes and what the server sees when it starts. */
    private class FakeDeckService : IDeckService.Stub() {
        val startCalls = java.util.concurrent.atomic.AtomicInteger(0)
        val calls = java.util.concurrent.CopyOnWriteArrayList<String>()
        var onStart: (() -> Unit)? = null
        @Volatile var pushed: String? = null

        override fun destroy() {}
        override fun startServer(): Int {
            startCalls.incrementAndGet()
            calls.add("startServer")
            onStart?.invoke()
            return 14794
        }

        override fun stopServer() {}
        override fun setCallback(cb: IDeckCallback?) {}
        override fun setPairedClients(json: String) {
            pushed = json
            calls.add("setPairedClients")
        }

        override fun respondPairing(requestId: String?, allow: Boolean) {}
        override fun status(): String = "fake"
        override fun setBatteryState(percent: Int, charging: Boolean) {}
        override fun setLockedState(locked: Boolean) {}
        override fun shareText(text: String?): Int = 0
        override fun shareFile(name: String?, mime: String?, data: ParcelFileDescriptor?): Int {
            runCatching { data?.close() }
            return 0
        }

        override fun listenerAccess(granted: Boolean) {}
        override fun pushDeviceEvent(json: String?) {}
        override fun setGates(allowConnections: Boolean, allowPairings: Boolean) {}
        override fun openNotification(id: String?, displayId: Int, intent: PendingIntent?) {}
        override fun openStaged(name: String?): ParcelFileDescriptor? = null
        override fun clipImageDone(id: String?, ok: Boolean) {}
    }
}
