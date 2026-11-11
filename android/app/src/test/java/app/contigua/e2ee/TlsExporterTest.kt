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
        assertEquals("5a3f4f8c184a6d082a3620b19b81a723c8d829c1ed7a2ae92235c0fbf0a363a6",
            TlsExporter.toHex(TlsExporter.derive(zero)))
        val labeledInput = "contigua-exporter-test-1".toByteArray(Charsets.UTF_8)
        val labeled = MessageDigest.getInstance("SHA-256").digest(labeledInput)
        assertEquals("3bc2dc9384542e65c9a38e26ea3b46169c9ab310f99651b0f3f88bfb217ac8e8",
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
