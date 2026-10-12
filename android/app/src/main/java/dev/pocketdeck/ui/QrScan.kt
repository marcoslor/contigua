package dev.pocketdeck.ui

import android.content.Context
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.ui.platform.LocalContext
import com.google.mlkit.vision.barcode.common.Barcode
import com.google.mlkit.vision.codescanner.GmsBarcodeScannerOptions
import com.google.mlkit.vision.codescanner.GmsBarcodeScanning

/**
 * Opens the Google code-scanner UI and hands back the raw QR text (or null when
 * the user cancels / scanning fails).
 */
@Composable
fun rememberQrScanLauncher(onResult: (String?) -> Unit): () -> Unit {
    val context = LocalContext.current
    val latestOnResult by rememberUpdatedState(onResult)
    val scanner = remember(context) { codeScanner(context) }
    return remember(scanner) {
        {
            scanner.startScan()
                .addOnSuccessListener { barcode -> latestOnResult(barcode.rawValue) }
                .addOnCanceledListener { latestOnResult(null) }
                .addOnFailureListener { latestOnResult(null) }
        }
    }
}

private fun codeScanner(context: Context) = GmsBarcodeScanning.getClient(
    context,
    GmsBarcodeScannerOptions.Builder()
        .setBarcodeFormats(Barcode.FORMAT_QR_CODE)
        .build(),
)
