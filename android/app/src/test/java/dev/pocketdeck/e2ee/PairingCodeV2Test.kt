package dev.pocketdeck.e2ee

import org.junit.Assert.assertEquals
import org.junit.Test
import java.security.MessageDigest

class PairingCodeV2Test {
    private fun sha256(b: ByteArray): ByteArray = MessageDigest.getInstance("SHA-256").digest(b)
    private fun zeros(n: Int) = ByteArray(n)
    private fun first16(digest: ByteArray) = digest.copyOfRange(0, 16)

    @Test
    fun vectorA() {
        val np = zeros(16); val phone = zeros(32); val mac = zeros(32)
        val commit = PairingCodeV2.commit(np, phone, mac)
        assertEquals("4db996acf8699876c00680a004258f80b6027b3e486fef58cbd47b3c4c2d55b0", PairingCodeV2.hex(commit))
        val exporter = zeros(32)
        val nm = zeros(16)
        val code = PairingCodeV2.code(exporter, mac, phone, nm, np)
        assertEquals("063680", PairingCodeV2.codeHex(code))
        val h = PairingCodeV2.sha256(PairingCodeV2.concat(
            "pd-code-v2".toByteArray(Charsets.UTF_8), exporter, mac, phone, nm, np))
        assertEquals("f28c00a27dc8c40011fa37bc093e4681ca8bde98fc8f84454a3aa21cc4f9d578", PairingCodeV2.hex(h))
    }

    @Test
    fun vectorB() {
        val exporter = sha256("pd-v2-vector exporter".toByteArray(Charsets.UTF_8))
        val mac = sha256("pd-v2-vector mac".toByteArray(Charsets.UTF_8))
        val phone = sha256("pd-v2-vector phone".toByteArray(Charsets.UTF_8))
        val nm = first16(sha256("pd-v2-vector Nm".toByteArray(Charsets.UTF_8)))
        val np = first16(sha256("pd-v2-vector Np".toByteArray(Charsets.UTF_8)))
        val commit = PairingCodeV2.commit(np, phone, mac)
        assertEquals("1416bfb0ad52d1e41616118ef7a672aca9bd2bd1c8bf72dde845536749ca53f0", PairingCodeV2.hex(commit))
        val code = PairingCodeV2.code(exporter, mac, phone, nm, np)
        assertEquals("694339", PairingCodeV2.codeHex(code))
        val h = PairingCodeV2.sha256(PairingCodeV2.concat(
            "pd-code-v2".toByteArray(Charsets.UTF_8), exporter, mac, phone, nm, np))
        assertEquals("826dde3dd5847d43a449eb3158908849c2205bc56cbcab124f3dac041018a8ae", PairingCodeV2.hex(h))
    }

    @Test
    fun qrHmacProduces32Bytes() {
        val s = ByteArray(16) { 0x42 }
        val exporter = ByteArray(32) { 0x11 }
        val phone = ByteArray(32) { 0x22 }
        val hmac = PairingCodeV2.qrHmac(s, exporter, phone)
        assertEquals(32, hmac.size)
    }
}
