package dev.pocketdeck.server

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.ByteArrayOutputStream
import java.security.MessageDigest
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit

class ApkInstallerTest {

    private class FakeShell(var commitOutput: String = "Success\n") : PackageShell {
        val written = LinkedHashMap<String, ByteArrayOutputStream>()
        val abandoned = ArrayList<Int>()
        var committed = false
        override fun create(totalBytes: Long) = "Success: created install session [42]\n"
        override fun write(session: Int, name: String, size: Long): PartWriter {
            val out = ByteArrayOutputStream().also { written[name] = it }
            return object : PartWriter {
                override fun write(bytes: ByteArray, offset: Int, length: Int) = out.write(bytes, offset, length)
                override fun finish() = "Success: streamed $size bytes\n"
                override fun abort() = Unit
            }
        }
        override fun commit(session: Int): String { committed = true; return commitOutput }
        override fun abandon(session: Int) { abandoned += session }
        override fun newestSince(sinceMs: Long) = InstalledApp("com.example.tiny", "Tiny", "1.2")
    }

    private val sent = LinkedBlockingQueue<Map<String, Any?>>()

    private fun sha(b: ByteArray) = MessageDigest.getInstance("SHA-256").digest(b).joinToString("") { "%02x".format(it) }

    private fun result(): Map<String, Any?> {
        while (true) {
            val m = sent.poll(5, TimeUnit.SECONDS) ?: error("no apk.result")
            if (m["t"] == "apk.result") return m
        }
    }

    private fun begin(installer: ApkInstaller, id: Long, vararg parts: Pair<String, ByteArray>) =
        installer.begin(mapOf("t" to "apk.install", "id" to id,
            "files" to parts.map { mapOf("name" to it.first, "size" to it.second.size.toLong(), "sha256" to sha(it.second)) }))

    @Test
    fun splitsSpanningChunksArriveIntact() {
        val shell = FakeShell()
        val installer = ApkInstaller(shell, { sent += it })
        val base = ByteArray(3000) { it.toByte() }
        val split = ByteArray(1500) { (it * 7).toByte() }
        begin(installer, 7, "base.apk" to base, "split_config.arm64_v8a.apk" to split)
        val all = base + split
        var off = 0
        while (off < all.size) { val n = minOf(1024, all.size - off); installer.data(7, all.copyOfRange(off, off + n)); off += n }
        val r = result()
        assertEquals(true, r["ok"])
        assertEquals("com.example.tiny", r["pkg"])
        assertEquals("1.2", r["version"])
        assertTrue(base.contentEquals(shell.written["base.apk"]!!.toByteArray()))
        assertTrue(split.contentEquals(shell.written["split_config.arm64_v8a.apk"]!!.toByteArray()))
    }

    @Test
    fun commitFailureCarriesPmCode() {
        val shell = FakeShell("Failure [INSTALL_FAILED_VERSION_DOWNGRADE: Downgrade detected]\n")
        val installer = ApkInstaller(shell, { sent += it })
        val apk = ByteArray(10) { 1 }
        begin(installer, 1, "base.apk" to apk)
        installer.data(1, apk)
        val r = result()
        assertEquals(false, r["ok"])
        assertEquals("INSTALL_FAILED_VERSION_DOWNGRADE", r["code"])
    }

    @Test
    fun damagedBytesAreNotCommitted() {
        val shell = FakeShell()
        val installer = ApkInstaller(shell, { sent += it })
        begin(installer, 2, "base.apk" to ByteArray(4) { 1 })
        installer.data(2, ByteArray(4) { 2 })
        assertEquals("checksum", result()["code"])
        assertFalse(shell.committed)
        assertEquals(listOf(42), shell.abandoned)
    }

    @Test
    fun cancelAbandonsTheSession() {
        val shell = FakeShell()
        val installer = ApkInstaller(shell, { sent += it })
        begin(installer, 3, "base.apk" to ByteArray(100))
        installer.data(3, ByteArray(10))
        installer.cancel(3)
        assertEquals("cancelled", result()["code"])
        assertFalse(shell.committed)
        assertEquals(listOf(42), shell.abandoned)
    }

    @Test
    fun oneInstallAtATimeAndBadRequestsRefused() {
        val installer = ApkInstaller(FakeShell(), { sent += it })
        begin(installer, 4, "base.apk" to ByteArray(10))
        begin(installer, 5, "base.apk" to ByteArray(10))
        assertEquals("busy", result()["code"])
        installer.begin(mapOf("id" to 6L, "files" to listOf(mapOf("name" to "../x.apk", "size" to 1L, "sha256" to "0".repeat(64)))))
        assertEquals("bad_request", result()["code"])
        installer.begin(mapOf("id" to 6L, "files" to listOf(mapOf("name" to "big.apk", "size" to ApkPolicy.MAX_TOTAL_BYTES + 1, "sha256" to "0".repeat(64)))))
        assertEquals("too_large", result()["code"])
        installer.close()
    }

    @Test
    fun pmOutputParsing() {
        assertEquals(1234, ApkPolicy.sessionId("Success: created install session [1234]"))
        assertNull(ApkPolicy.sessionId("Error: java.lang.SecurityException"))
        assertEquals("INSTALL_FAILED_UPDATE_INCOMPATIBLE" to "Package x signatures do not match",
            ApkPolicy.failure("Failure [INSTALL_FAILED_UPDATE_INCOMPATIBLE: Package x signatures do not match]"))
        assertEquals("INSTALL_FAILED_INSUFFICIENT_STORAGE" to "", ApkPolicy.failure("Failure [INSTALL_FAILED_INSUFFICIENT_STORAGE]"))
        assertEquals("failed", ApkPolicy.failure("Exception occurred").first)
        assertFalse(ApkPolicy.validName("a/b.apk"))
        assertFalse(ApkPolicy.validName("base.zip"))
        assertFalse(ApkPolicy.validName("-r.apk"))
        assertTrue(ApkPolicy.validName("split_config.xxhdpi.apk"))
    }
}
