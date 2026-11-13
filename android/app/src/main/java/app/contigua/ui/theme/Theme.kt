package app.contigua.ui.theme

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Shapes
import androidx.compose.material3.Typography
import androidx.compose.material3.dynamicDarkColorScheme
import androidx.compose.material3.dynamicLightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.sp

/**
 * Contigua's Material 3 theme (docs/DESIGN.md §2). Dynamic color on API 31+,
 * the seeded Tonal Spot scheme below it, dark from the system.
 */
@Composable
fun ContiguaTheme(
    darkTheme: Boolean = isSystemInDarkTheme(),
    dynamicColor: Boolean = true,
    content: @Composable () -> Unit,
) {
    val context = LocalContext.current
    val colorScheme = when {
        dynamicColor ->
            if (darkTheme) dynamicDarkColorScheme(context) else dynamicLightColorScheme(context)
        darkTheme -> DarkScheme
        else -> LightScheme
    }
    MaterialTheme(
        colorScheme = colorScheme,
        typography = Typography(),
        shapes = Shapes(),
        content = content,
    )
}

/**
 * The pairing code style from docs/DESIGN.md §2: `displayLarge` in monospace with
 * 6 sp letter spacing and tabular figures.
 */
@Composable
fun pairingCodeStyle(): TextStyle = MaterialTheme.typography.displayLarge.copy(
    fontFamily = FontFamily.Monospace,
    letterSpacing = 6.sp,
    fontFeatureSettings = "tnum",
)
