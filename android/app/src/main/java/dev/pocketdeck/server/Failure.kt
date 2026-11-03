package dev.pocketdeck.server

import android.system.ErrnoException
import android.system.OsConstants
import java.lang.reflect.InvocationTargetException

/**
 * A failure's classes only, for logcat: never a message, path, URI or name
 * (R-PRIV-1). Reflective clipboard calls hide the real cause in
 * [InvocationTargetException.targetException], and storage failures hide the
 * reason in [ErrnoException.errno]; both are followed here so the log names
 * `SecurityException` or `EACCES` instead of a message that may carry a path.
 */
internal fun failureClasses(error: Throwable): String {
    val parts = mutableListOf<String>()
    var current: Throwable? = error
    var depth = 0
    while (current != null && depth < 4) {
        val e = current
        parts += when (e) {
            is ErrnoException -> "ErrnoException(${errnoName(e.errno)})"
            else -> e.javaClass.simpleName
        }
        current = when (e) {
            is InvocationTargetException -> e.targetException ?: e.cause
            else -> e.cause
        }
        depth += 1
    }
    return parts.joinToString("<-")
}

private fun errnoName(errno: Int): String = when (errno) {
    OsConstants.EACCES -> "EACCES"
    OsConstants.EPERM -> "EPERM"
    OsConstants.ENOENT -> "ENOENT"
    OsConstants.EIO -> "EIO"
    OsConstants.EPIPE -> "EPIPE"
    OsConstants.ENOSPC -> "ENOSPC"
    else -> errno.toString()
}
