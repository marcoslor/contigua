package app.contigua.server

/**
 * Picks the order in which hidden `IActivityManager.startActivity` overloads are
 * tried. The parameter types are compared by name because the hidden types
 * (`IApplicationThread`, `ProfilerInfo`, …) are not on the compile classpath.
 * Pure so it is JVM-tested.
 */
internal object LauncherOverloads {

    /** The Android 16 `IActivityManager.startActivity` overload we prefer. */
    val PREFERRED: List<String> = listOf(
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

    private fun plausible(types: List<String>): Boolean =
        types.contains("android.content.Intent") &&
            types.lastOrNull() == "android.os.Bundle" &&
            types.size >= 6

    /**
     * Candidate indices, best first: the exact Android 16 signature, then any
     * other plausible `startActivity(… Intent … Bundle)`. Empty when no
     * overload looks like a usable start (the caller then falls back to `am`).
     */
    fun rank(candidates: List<List<String>>): List<Int> {
        val indices = candidates.indices
        val exact = indices.filter { candidates[it] == PREFERRED }
        val likely = indices.filter { it !in exact && plausible(candidates[it]) }
        return exact + likely
    }
}
