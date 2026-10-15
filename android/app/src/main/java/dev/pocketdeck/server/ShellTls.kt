package dev.pocketdeck.server

import java.io.ByteArrayInputStream
import java.security.KeyFactory
import java.security.KeyStore
import java.security.SecureRandom
import java.security.cert.CertificateFactory
import java.security.spec.PKCS8EncodedKeySpec
import javax.crypto.EncryptedPrivateKeyInfo
import javax.net.ssl.KeyManagerFactory
import javax.net.ssl.SSLContext
import javax.net.ssl.SSLSocket
import javax.net.ssl.TrustManagerFactory
import dev.pocketdeck.proto.Json

/**
 * Shell-UID TLS terminator (docs/design/e2ee.md §2): platform SSLSocket
 * (not SSLEngine) over an accepted connection, TLS 1.3 only, client auth
 * required, trust pinned to the peer's cert. The private key is materialised
 * only in memory from the AIDL-pushed PEM; it is never written or logged.
 *
 * The shell process receives its own identity via `setPairedClients(... "self")`;
 * this object turns that PEM material into a JCA `SSLContext`. Call sites are
 * intentionally not wired yet (steps 7+); it exists here for the foundation
 * and is exercised on the JVM through standard JSSE.
 */
object ShellTls {
    private const val PASSWORD = "pocketdeck-memory-only"

    /** Parses a PEM block (any supported label) into raw DER bytes. */
    fun pemBytes(pem: String): ByteArray {
        val body = pem.lines()
            .filterNot { it.startsWith("-----") }
            .joinToString("")
            .replace("\\s".toRegex(), "")
        return java.util.Base64.getDecoder().decode(body)
    }

    /** Builds an in-memory SSLContext from the app-pushed PEMs. */
    fun serverContext(selfCertPem: String, selfKeyP8: String, trustedPeerCertPem: String?): SSLContext? {
        return try {
            val certFactory = CertificateFactory.getInstance("X.509")
            val selfCert = certFactory.generateCertificate(ByteArrayInputStream(selfCertPem.toByteArray(Charsets.UTF_8)))
            val keyDer = pemBytes(selfKeyP8)
            val pk = KeyFactory.getInstance("EC").generatePrivate(PKCS8EncodedKeySpec(keyDer))

            val keyStore = KeyStore.getInstance("PKCS12")
            keyStore.load(null, PASSWORD.toCharArray())
            keyStore.setKeyEntry("self", pk, PASSWORD.toCharArray(), arrayOf(selfCert))

            val kmf = KeyManagerFactory.getInstance(KeyManagerFactory.getDefaultAlgorithm())
            kmf.init(keyStore, PASSWORD.toCharArray())

            val trustStore = KeyStore.getInstance("PKCS12")
            trustStore.load(null, PASSWORD.toCharArray())
            if (trustedPeerCertPem != null && trustedPeerCertPem.isNotBlank()) {
                val peerCert = certFactory.generateCertificate(ByteArrayInputStream(trustedPeerCertPem.toByteArray(Charsets.UTF_8)))
                trustStore.setCertificateEntry("peer", peerCert)
            }
            val tmf = TrustManagerFactory.getInstance(TrustManagerFactory.getDefaultAlgorithm())
            tmf.init(trustStore)

            SSLContext.getInstance("TLS").apply {
                init(kmf.keyManagers, tmf.trustManagers, SecureRandom())
            }
        } catch (e: Throwable) {
            null
        }
    }

    /** Wraps an already-accepted plain socket into a TLS 1.3 SSLSocket (server side). */
    fun wrapAccepted(socket: java.net.Socket, context: SSLContext): SSLSocket {
        val ssl = context.socketFactory.createSocket(
            socket,
            socket.inetAddress.hostAddress,
            socket.port,
            false,
        ) as SSLSocket
        ssl.useClientMode = false
        ssl.needClientAuth = true
        ssl.enabledProtocols = arrayOf("TLSv1.3")
        // Resumption / 0-RTT: the socket factory produces fresh sessions; the
        // surrounding code never caches SSLSession or offers early data, so no
        // PSK ticket can be replayed (R3).
        return ssl
    }
}
