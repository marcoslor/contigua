package dev.pocketdeck.direct

import android.content.Context
import android.content.pm.PackageManager
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.wifi.aware.AttachCallback
import android.net.wifi.aware.Characteristics
import android.net.wifi.aware.DiscoverySessionCallback
import android.net.wifi.aware.IdentityChangedListener
import android.net.wifi.aware.PublishConfig
import android.net.wifi.aware.PublishDiscoverySession
import android.net.wifi.aware.WifiAwareDataPathSecurityConfig
import android.net.wifi.aware.WifiAwareManager
import android.net.wifi.aware.WifiAwareNetworkInfo
import android.net.wifi.aware.WifiAwareNetworkSpecifier
import android.net.wifi.aware.WifiAwareSession
import android.os.Handler
import android.os.Looper
import java.io.FileDescriptor
import java.io.IOException
import java.net.ServerSocket

/**
 * The platform adapter (docs/design/direct-link.md §8.1): one method per
 * Aware call, no policy, no state. Every call runs in the app process, which
 * owns the Aware session, the network and the listener.
 */
class PlatformAwarePort(context: Context) : AwarePort {

    private val app = context.applicationContext
    private val manager: WifiAwareManager? =
        runCatching { app.getSystemService(WifiAwareManager::class.java) }.getOrNull()
    private val connectivity: ConnectivityManager? =
        runCatching { app.getSystemService(ConnectivityManager::class.java) }.getOrNull()
    private val handler = Handler(Looper.getMainLooper())

    private var session: WifiAwareSession? = null
    private var publish: PublishDiscoverySession? = null
    private var passphrase: String? = null
    private var networkCallback: ConnectivityManager.NetworkCallback? = null

    /** Bumped on every unpublish/detach so a late platform callback is dropped. */
    private var generation = 0

    override fun available(): Boolean =
        manager?.isAvailable == true &&
            app.packageManager.hasSystemFeature(PackageManager.FEATURE_WIFI_AWARE)

    override fun attach(onAttached: () -> Unit, onFailed: (String) -> Unit) {
        val wifiAware = manager ?: return onFailed(AwareReason.NO_FEATURE)
        val start = generation
        val attach = object : AttachCallback() {
            override fun onAttached(awareSession: WifiAwareSession?) {
                if (start != generation) {
                    runCatching { awareSession?.close() }
                    return
                }
                session = awareSession
                onAttached()
            }

            override fun onAttachFailed() {
                if (start == generation) onFailed(AwareReason.AWARE_BUSY)
            }
        }
        val identity = object : IdentityChangedListener() {
            override fun onIdentityChanged(mac: ByteArray?) = Unit
        }
        runCatching { wifiAware.attach(attach, identity, handler) }
            .onFailure { onFailed(AwareReason.AWARE_BUSY) }
    }

    override fun publish(
        ssi: ByteArray,
        passphrase: String,
        onStarted: () -> Unit,
        onFailed: (String) -> Unit,
    ) {
        val aware = session ?: return onFailed(AwareReason.AWARE_BUSY)
        val start = generation
        this.passphrase = passphrase
        val config = publishConfig(ssi, passphrase)
        val callback = object : DiscoverySessionCallback() {
            override fun onPublishStarted(publishSession: PublishDiscoverySession) {
                if (start != generation) {
                    runCatching { publishSession.close() }
                    return
                }
                publish = publishSession
                onStarted()
            }

            override fun onSessionConfigFailed() {
                if (start == generation) onFailed(AwareReason.AWARE_BUSY)
            }

            override fun onSessionTerminated() {
                if (start == generation) onFailed(AwareReason.AWARE_BUSY)
            }
        }
        runCatching { aware.publish(config, callback, handler) }
            .onFailure { onFailed(AwareReason.AWARE_BUSY) }
    }

    override fun updateSsi(ssi: ByteArray): Boolean {
        val publishSession = publish ?: return false
        val phrase = passphrase ?: return false
        return runCatching {
            publishSession.updatePublish(publishConfig(ssi, phrase))
            true
        }.getOrDefault(false)
    }

    override fun requestNetwork(
        passphrase: String,
        port: Int,
        onAvailable: (AwareNetwork) -> Unit,
        onLost: () -> Unit,
    ) {
        val publishSession = publish ?: return onLost()
        val connectivityManager = connectivity ?: return onLost()
        val specifier = WifiAwareNetworkSpecifier.Builder(publishSession)
            .setPskPassphrase(passphrase)
            .setPort(port)
            .setTransportProtocol(TRANSPORT_TCP)
            .build()
        val request = NetworkRequest.Builder()
            .addTransportType(NetworkCapabilities.TRANSPORT_WIFI_AWARE)
            .setNetworkSpecifier(specifier)
            .build()
        val start = generation
        val callback = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                if (start != generation) return
                onAvailable(PlatformNetwork(network))
            }

            override fun onLost(network: Network) {
                if (start == generation) onLost()
            }

            override fun onUnavailable() {
                if (start == generation) onLost()
            }
        }
        networkCallback = callback
        runCatching { connectivityManager.requestNetwork(request, callback, handler, NDP_TIMEOUT_MS) }
            .onFailure {
                networkCallback = null
                onLost()
            }
    }

    override fun releaseNetwork() {
        val callback = networkCallback ?: return
        networkCallback = null
        runCatching { connectivity?.unregisterNetworkCallback(callback) }
    }

    override fun unpublish() {
        generation++
        passphrase = null
        runCatching { publish?.close() }
        publish = null
    }

    override fun detach() {
        generation++
        passphrase = null
        runCatching { publish?.close() }
        publish = null
        runCatching { session?.close() }
        session = null
    }

    private fun publishConfig(ssi: ByteArray, passphrase: String): PublishConfig =
        PublishConfig.Builder()
            .setServiceName(DirectConfig.SERVICE_NAME)
            .setServiceSpecificInfo(ssi)
            .setDataPathSecurityConfig(
                WifiAwareDataPathSecurityConfig.Builder(
                    Characteristics.WIFI_AWARE_CIPHER_SUITE_NCS_SK_128,
                ).setPskPassphrase(passphrase).build(),
            )
            .setTerminateNotificationEnabled(true)
            .build()

    private inner class PlatformNetwork(private val network: Network) : AwareNetwork {
        override fun bindSocket(socket: ServerSocket) {
            // Network has no ServerSocket overload; the fd variant is the
            // platform way to put a listener on the Aware interface.
            val fd = serverFd(socket) ?: throw IOException("no server socket fd")
            network.bindSocket(fd)
        }

        override fun bandwidthKbps(): Int {
            val capabilities = connectivity?.getNetworkCapabilities(network) ?: return -1
            val info = capabilities.transportInfo as? WifiAwareNetworkInfo ?: return -1
            val channel = info.channelInfoList?.firstOrNull() ?: return -1
            // A coarse figure for the log: the channel width in MHz as kbit/s.
            return channel.channelBandwidth * 1000
        }
    }

    /** The listener's descriptor, for [Network.bindSocket]'s fd overload. */
    private fun serverFd(socket: ServerSocket): FileDescriptor? = runCatching {
        val impl = ServerSocket::class.java.getDeclaredMethod("getImpl")
            .apply { isAccessible = true }
            .invoke(socket)
        impl!!.javaClass.getDeclaredMethod("getFileDescriptor\$")
            .apply { isAccessible = true }
            .invoke(impl) as? FileDescriptor
    }.getOrNull()

    private companion object {
        const val TRANSPORT_TCP = 6
        const val NDP_TIMEOUT_MS = 30_000
    }
}
