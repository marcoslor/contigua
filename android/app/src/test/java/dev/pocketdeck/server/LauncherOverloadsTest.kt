package dev.pocketdeck.server

import org.junit.Assert.assertEquals
import org.junit.Test

class LauncherOverloadsTest {

    private val android16 = listOf(
        "android.app.IApplicationThread",
        "java.lang.String",
        "android.content.Intent",
        "java.lang.String",
        "android.os.IBinder",
        "java.lang.String",
        "int",
        "int",
        "android.app.ProfilerInfo",
        "android.os.Bundle",
    )

    /** A different, plausible `startActivity` overload (as a decoy). */
    private val decoy = listOf(
        "android.content.Intent",
        "java.lang.String",
        "android.os.IBinder",
        "java.lang.String",
        "int",
        "int",
        "android.os.Bundle",
    )

    @Test
    fun prefersTheAndroid16SignatureOverTheDecoy() {
        assertEquals(listOf(1, 0), LauncherOverloads.rank(listOf(decoy, android16)))
        assertEquals(listOf(0, 1), LauncherOverloads.rank(listOf(android16, decoy)))
    }

    @Test
    fun fallsBackToTheDecoyWhenTheExactSignatureIsAbsent() {
        assertEquals(listOf(0), LauncherOverloads.rank(listOf(decoy)))
    }

    @Test
    fun returnsNothingWhenNoOverloadPlausiblyMatches() {
        assertEquals(emptyList<Int>(), LauncherOverloads.rank(listOf(listOf("int", "int"))))
        assertEquals(emptyList<Int>(), LauncherOverloads.rank(emptyList()))
    }
}
