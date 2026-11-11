package app.contigua.e2ee

import java.io.ByteArrayInputStream
import java.security.cert.CertificateFactory
import java.security.cert.X509Certificate
import java.security.interfaces.ECPublicKey

/**
 * The identity fingerprint both processes compare (docs/design/e2ee.md §2/§10):
 * SHA-256 over the certificate's 65-byte uncompressed EC point, the same pin the
 * Mac stores. The app computes it for the shell service on every push; the shell
 * recomputes it from the pushed certificate so a malformed payload fails closed.
 */
object IdentityPin {

    /** The 64-hex point fingerprint of [certPem], or null when it is not a P-256 cert. */
    fun of(certPem: String): String? = runCatching {
        if (certPem.isBlank()) return@runCatching null
        val cert = CertificateFactory.getInstance("X.509")
            .generateCertificate(ByteArrayInputStream(certPem.toByteArray(Charsets.UTF_8))) as X509Certificate
        val pub = cert.publicKey as? ECPublicKey ?: return@runCatching null
        val fp = KeyPin.fingerprint(pub)
        if (fp.size != 32) null else KeyPin.toHex(fp)
    }.getOrNull()

    /**
     * The fingerprint the shell may use: the declared one only when it is a
     * 64-hex value that matches the certificate it arrived with; otherwise ""
     * (which [app.contigua.server.AppLink] treats as "no identity").
     */
    fun verified(declaredHex: String, certPem: String): String {
        val actual = of(certPem) ?: return ""
        val declared = declaredHex.trim().lowercase()
        if (declared.length != 64 || !declared.all { it in '0'..'9' || it in 'a'..'f' }) return ""
        return if (declared == actual) actual else ""
    }
}
