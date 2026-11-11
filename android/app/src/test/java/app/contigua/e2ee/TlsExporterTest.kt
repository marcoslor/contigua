package app.contigua.e2ee

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.security.MessageDigest

class TlsExporterTest {
    @Test
    fun exporterVectorsMatchMac() {
        val zero = ByteArray(32)
        assertEquals("380c2602efd61000023783cb8280d36f3fb3a8c1b22a7d0e5247e6e227f3340c",
            TlsExporter.toHex(TlsExporter.derive(zero)))
        val labeledInput = "contigua-exporter-test-1".toByteArray(Charsets.UTF_8)
        val labeled = MessageDigest.getInstance("SHA-256").digest(labeledInput)
        assertEquals("68544181667677211b2823d71b530f48800be1ab6e762a4612d2d4fe85312d80",
            TlsExporter.toHex(TlsExporter.derive(labeled)))
    }

    @Test
    fun thePlatformExporterNeedsApi31() {
        assertFalse(TlsExporter.exportSupported(30))
        assertFalse(TlsExporter.exportSupported(29))
        assertTrue(TlsExporter.exportSupported(31))
        assertTrue(TlsExporter.exportSupported(36))
    }

    @Test
    fun hkdfExpandLabelSmallKnown() {
        // Sanity: empty secret expands to a deterministic 32 bytes.
        val empty = ByteArray(32)
        assertEquals(32, TlsExporter.derive(empty).size)
    }
}
