// `--debug-frame-log FILE` (e2e): one line per video frame a window handed to
// its decoder, `<epoch seconds>\t<stream>\t<path id>`. The direct-link
// confirmation boot buckets these per 250 ms to see the picture keep moving
// across a black-holed path, and attributes each frame to the path it arrived
// on. Debug-only: a release build ignores the flag (LaunchOptions.testHooks).

import Foundation

final class DebugFrameLog {
    private let handle: FileHandle?
    private let lock = NSLock()

    init(path: String) {
        FileManager.default.createFile(atPath: path, contents: nil)
        handle = FileHandle(forWritingAtPath: path)
    }

    /// Called on the session's video queue; the lock keeps a second session
    /// (a retry during the same launch) from interleaving a half line.
    func note(stream: UInt32, path: String) {
        guard let handle else { return }
        let line = String(format: "%.6f\t%u\t", Date().timeIntervalSince1970, stream) + path + "\n"
        lock.lock()
        defer { lock.unlock() }
        try? handle.write(contentsOf: Data(line.utf8))
    }
}
