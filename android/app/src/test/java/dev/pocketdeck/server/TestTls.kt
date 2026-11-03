package dev.pocketdeck.server

import dev.pocketdeck.e2ee.DerCert
import java.io.ByteArrayInputStream
import java.net.Socket
import java.security.KeyFactory
import java.security.KeyPair
import java.security.KeyPairGenerator
import java.security.KeyStore
import java.security.SecureRandom
import java.security.cert.CertificateFactory
import java.security.spec.ECGenParameterSpec
import java.security.spec.PKCS8EncodedKeySpec
import java.util.Base64
import javax.net.ssl.KeyManagerFactory
import javax.net.ssl.SSLContext
import javax.net.ssl.SSLSocket
import javax.net.ssl.TrustManagerFactory

/**
 * JVM-side TLS identities for the loopback harnesses (docs/design/e2ee.md §2):
 * pure JCA — the same EC/P-256 pair + self-signed cert route PhoneIdentity
 * uses, without Android. Also the client side: a mutual-TLS SSLSocket with
 * client auth, so [ServerTest] runs the production TLS path, not plaintext.
 */
object TestTls {

    data class Identity(val certPem: String, val keyP8: String) {
        val cert: java.security.cert.Certificate by lazy {
            CertificateFactory.getInstance("X.509")
                .generateCertificate(ByteArrayInputStream(certPem.toByteArray(Charsets.UTF_8)))
        }
        val privateKey by lazy {
            val der = ShellTls.pemBytes(keyP8)
            KeyFactory.getInstance("EC").generatePrivate(PKCS8EncodedKeySpec(der))
        }
    }

    const val DAY_MS = 24L * 60L * 60L * 1000L

    fun generate(cn: String): Identity {
        val kpg = KeyPairGenerator.getInstance("EC")
        kpg.initialize(ECGenParameterSpec("secp256r1"))
        val pair: KeyPair = kpg.generateKeyPair()
        val now = java.util.Date()
        val serial = SecureRandom().nextInt(Int.MAX_VALUE - 1) + 1
        val der = DerCert.buildComplete(
            cn, pair, serial,
            java.util.Date(now.time - DAY_MS),
            java.util.Date(now.time + 366 * DAY_MS),
        ).der
        val certPem = pem("CERTIFICATE", der)
        val keyP8 = pem("PRIVATE KEY", pair.private.encoded ?: error("no PKCS8 encoding"))
        return Identity(certPem, keyP8)
    }

    private fun pem(label: String, der: ByteArray): String {
        val b64 = Base64.getEncoder().encodeToString(der)
        val wrapped = b64.chunked(64).joinToString("\n")
        return "-----BEGIN $label-----\n$wrapped\n-----END $label-----"
    }

    /** The MAC side of the harness: presents its identity, trusts the fake phone. */
    fun clientSocket(id: Identity, trustServerCertPem: String, host: String, port: Int): SSLSocket =
        clientOver(Socket(host, port).apply { tcpNoDelay = true }, id, trustServerCertPem)

    /**
     * TLS over a socket the test already connected (the handed-over path,
     * DIRECT-17): the server's fd never came from its own acceptor.
     */
    fun clientOver(raw: Socket, id: Identity, trustServerCertPem: String): SSLSocket {
        val context = clientContext(id, trustServerCertPem)
        val ssl = context.socketFactory.createSocket(
            raw,
            raw.inetAddress.hostAddress,
            raw.port,
            true,
        ) as SSLSocket
        ssl.enabledProtocols = arrayOf("TLSv1.3")
        ssl.tcpNoDelay = true
        ssl.soTimeout = 5_000
        return ssl
    }

    private fun clientContext(id: Identity, trustServerCertPem: String): SSLContext {
        val store = KeyStore.getInstance("PKCS12")
        store.load(null, PASSWORD.toCharArray())
        store.setKeyEntry("self", id.privateKey, PASSWORD.toCharArray(), arrayOf(id.cert))
        val kmf = KeyManagerFactory.getInstance(KeyManagerFactory.getDefaultAlgorithm())
        kmf.init(store, PASSWORD.toCharArray())

        val serverCert = CertificateFactory.getInstance("X.509")
            .generateCertificate(ByteArrayInputStream(trustServerCertPem.toByteArray(Charsets.UTF_8)))
        val trustStore = KeyStore.getInstance("PKCS12")
        trustStore.load(null, PASSWORD.toCharArray())
        trustStore.setCertificateEntry("server", serverCert)
        val tmf = TrustManagerFactory.getInstance(TrustManagerFactory.getDefaultAlgorithm())
        tmf.init(trustStore)

        val context = SSLContext.getInstance("TLS")
        context.init(kmf.keyManagers, tmf.trustManagers, SecureRandom())
        return context
    }

    private const val PASSWORD = "pocketdeck-test-memory-only"

    /** The harness pins the peer by fingerprint, not by certificate chain. */
    private val trustAll = object : javax.net.ssl.X509TrustManager {
        override fun checkClientTrusted(chain: Array<java.security.cert.X509Certificate>?, authType: String?) {}
        override fun checkServerTrusted(chain: Array<java.security.cert.X509Certificate>?, authType: String?) {}
        override fun getAcceptedIssuers(): Array<java.security.cert.X509Certificate> = emptyArray()
    }

    /**
     * The phone side of the harness. [provider] switches the server's TLS stack
     * (Conscrypt, Android's); [useEngineSocket] picks Conscrypt's engine socket
     * or the FD socket Android uses by default.
     */
    fun serverContext(
        id: Identity,
        provider: java.security.Provider?,
        useEngineSocket: Boolean,
    ): SSLContext {
        val store = KeyStore.getInstance("PKCS12")
        store.load(null, PASSWORD.toCharArray())
        store.setKeyEntry("self", id.privateKey, PASSWORD.toCharArray(), arrayOf(id.cert))
        val kmf = KeyManagerFactory.getInstance(KeyManagerFactory.getDefaultAlgorithm())
        kmf.init(store, PASSWORD.toCharArray())
        val context = if (provider == null) {
            SSLContext.getInstance("TLS")
        } else {
            SSLContext.getInstance("TLS", provider)
        }
        context.init(kmf.keyManagers, arrayOf(trustAll), SecureRandom())
        if (provider != null) {
            org.conscrypt.Conscrypt.setUseEngineSocket(context.socketFactory, useEngineSocket)
        }
        return context
    }
}
