package app.contigua.server

import android.os.ParcelFileDescriptor
import org.junit.After
import org.junit.Rule
import org.junit.rules.TemporaryFolder
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import java.util.Collections
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/**
 * The shell side of the app-owned clipboard image (boot 5: uid 2000's clip
 * owner check failed, so the app must set it). The bytes go over a pipe, the
 * app's `clipImageDone` is the only success, and no callback or no answer
 * within 3 s is a refusal.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class ClipImageBridgeTest {

    @get:Rule
    val tmp = TemporaryFolder()

    private val bridges = mutableListOf<ClipImageBridge>()

    private fun bridge(
        callback: () -> ClipImageBridge.ClipImageCallback?,
        timeoutMs: Long = 5_000,
    ): ClipImageBridge = ClipImageBridge(callback, scratch = { tmp.root }, timeoutMs = timeoutMs)
        .also { bridges += it }

    @After
    fun closeBridges() {
        bridges.forEach { it.close() }
    }

    @Test
    fun theAppReadsTheBytesAndItsAnswerCompletes() {
        val read = CountDownLatch(1)
        var received: ByteArray? = null
        val bridge = bridge({
            ClipImageBridge.ClipImageCallback { _, _, data ->
                try {
                    received = ParcelFileDescriptor.AutoCloseInputStream(data).use { it.readBytes() }
                } finally {
                    read.countDown()
                }
            }
        })
        val answers = Collections.synchronizedList(mutableListOf<Boolean>())

        bridge.offer("7", "image/png", byteArrayOf(1, 2, 3)) { answers += it }

        assertTrue("the app reads the pipe", read.await(10, TimeUnit.SECONDS))
        assertTrue(received!!.contentEquals(byteArrayOf(1, 2, 3)))
        bridge.answer("7", true)
        assertEquals(listOf(true), answers)
    }

    @Test
    fun noCallbackIsARefusal() {
        val answers = Collections.synchronizedList(mutableListOf<Boolean>())
        val done = CountDownLatch(1)
        val bridge = bridge({ null })

        bridge.offer("7", "image/png", byteArrayOf(1)) {
            answers += it
            done.countDown()
        }

        assertTrue(done.await(1, TimeUnit.SECONDS))
        assertEquals(listOf(false), answers)
    }

    @Test
    fun noAnswerWithinTheTimeoutIsARefusal() {
        val answers = Collections.synchronizedList(mutableListOf<Boolean>())
        val done = CountDownLatch(1)
        val bridge = bridge({
            ClipImageBridge.ClipImageCallback { _, _, data -> data.close() }
        }, timeoutMs = 100)

        bridge.offer("7", "image/png", byteArrayOf(1)) {
            answers += it
            done.countDown()
        }

        assertTrue("the timeout answers", done.await(2, TimeUnit.SECONDS))
        assertEquals(listOf(false), answers)
    }

    @Test
    fun aLateAnswerIsIgnored() {
        val answers = Collections.synchronizedList(mutableListOf<Boolean>())
        val done = CountDownLatch(1)
        val bridge = bridge({
            ClipImageBridge.ClipImageCallback { _, _, data -> data.close() }
        }, timeoutMs = 100)

        bridge.offer("7", "image/png", byteArrayOf(1)) {
            answers += it
            done.countDown()
        }
        assertTrue(done.await(2, TimeUnit.SECONDS))
        bridge.answer("7", true)
        Thread.sleep(50)  // real-time: let a second completion land if the bug exists
        assertEquals(listOf(false), answers)
    }
}
