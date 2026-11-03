package dev.pocketdeck.direct

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * The phone's half of DIRECT-9: AES-256-GCM with a non-exportable Android
 * Keystore key (docs/design/direct-link.md §5). The ciphertext is
 * `base64(iv ‖ ct)` in the app's private prefs; the key bytes never leave
 * [open]'s caller.
 */
class KeystoreCipher(private val alias: String = ALIAS) {

    fun seal(plain: ByteArray): String {
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.ENCRYPT_MODE, key())
        val iv = cipher.iv
        val encrypted = cipher.doFinal(plain)
        val packed = ByteArray(iv.size + encrypted.size)
        System.arraycopy(iv, 0, packed, 0, iv.size)
        System.arraycopy(encrypted, 0, packed, iv.size, encrypted.size)
        return Base64.encodeToString(packed, Base64.NO_WRAP)
    }

    fun open(sealed: String): ByteArray? = runCatching {
        val packed = Base64.decode(sealed, Base64.NO_WRAP)
        if (packed.size <= IV_BYTES) return null
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(
            Cipher.DECRYPT_MODE,
            key(),
            GCMParameterSpec(128, packed.copyOfRange(0, IV_BYTES)),
        )
        cipher.doFinal(packed.copyOfRange(IV_BYTES, packed.size))
    }.getOrNull()

    private fun key(): SecretKey {
        val store = KeyStore.getInstance(STORE).apply { load(null) }
        (store.getEntry(alias, null) as? KeyStore.SecretKeyEntry)?.secretKey?.let { return it }
        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, STORE)
        generator.init(
            KeyGenParameterSpec.Builder(
                alias,
                KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
            )
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256)
                .setUserAuthenticationRequired(false)
                .build(),
        )
        return generator.generateKey()
    }

    private companion object {
        const val STORE = "AndroidKeyStore"
        const val ALIAS = "pocketdeck-direct-psk"
        const val TRANSFORMATION = "AES/GCM/NoPadding"
        const val IV_BYTES = 12
    }
}

/** The key store over the app's private prefs, sealed by [KeystoreCipher]. */
class PrefsDirectKeyStore(
    context: Context,
    private val cipher: KeystoreCipher = KeystoreCipher(),
) : DirectKeyStore {
    private val app = context.applicationContext

    override fun get(clientId: String): ByteArray? =
        dev.pocketdeck.app.Prefs.directKeyCiphertext(app, clientId)?.let { cipher.open(it) }

    override fun put(clientId: String, key: ByteArray) {
        dev.pocketdeck.app.Prefs.setDirectKeyCiphertext(app, clientId, cipher.seal(key))
    }

    override fun remove(clientId: String) {
        dev.pocketdeck.app.Prefs.removeDirectKey(app, clientId)
    }
}
