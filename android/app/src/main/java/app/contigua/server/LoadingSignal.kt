package app.contigua.server

/**
 * A loading signal (docs/PROTOCOL.md "UI tree" item 9, docs/specs/mcp.md
 * MCP-103): a node visible to the user that is an indeterminate progress bar, or
 * a `WebView` with no content yet. Pure: it sees a node's class name, whether it
 * is visible to the user, whether it reports a range, and its child count, and
 * answers "loading or not".
 *
 * A `ProgressBar` (or any class whose name ends in `ProgressBar`) with no
 * `RangeInfo` is indeterminate; a determinate one reports a range. A visible
 * `android.webkit.WebView` with no child node is a skeleton page still filling
 * in. This is round 1's "skeleton tree" read right after navigating — a bare
 * WebView, a sheet with none of its chips — with nothing saying it was still
 * loading.
 */
object LoadingSignal {

    /**
     * @param className the node's full class name (`android.widget.ProgressBar`).
     * @param visibleToUser `AccessibilityNodeInfo.isVisibleToUser`.
     * @param hasRange whether the node reports a range (`getRangeInfo()` non-null).
     * @param childCount the node's child count.
     */
    fun loading(className: String, visibleToUser: Boolean, hasRange: Boolean, childCount: Int): Boolean {
        if (!visibleToUser) return false
        return indeterminateProgressBar(className, hasRange) || emptyWebView(className, childCount)
    }

    private fun indeterminateProgressBar(className: String, hasRange: Boolean): Boolean =
        !hasRange && className.endsWith("ProgressBar")

    private fun emptyWebView(className: String, childCount: Int): Boolean =
        className == "android.webkit.WebView" && childCount == 0
}
