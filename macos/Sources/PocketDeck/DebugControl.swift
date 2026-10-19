// Test hook (`--debug-control DIR`, e2e): the end-to-end checks that do not test
// launch, pairing or first run share one running app instead of relaunching it
// for each check, and hand it commands as files. A check writes `NAME.cmd`
// (atomically, one command line); the app runs it on the main thread, deletes
// the file and writes `NAME.done`: "ok", or why the command did not run.
//
//   reset            every stream window closes as the person closes one, the
//                    stream state is forgotten (ids from 1) and the per-check
//                    options are off: what a relaunch leaves
//   reset prefs      the same, and the remembered frames, styles and touch
//                    display are forgotten too: what a fresh profile leaves
//   open ARGS...     a launch's per-window options for the running session:
//                    --open, --open-phone, --continue-on-mac, --float-windows,
//                    --debug-chrome-state, --debug-input-script, --audio-stats,
//                    --resize-stream, --minimize-stream, --deminimize-stream,
//                    --close-stream (timers count from the command)
//
// Arguments are separated by spaces; paths with spaces are not supported.

import Foundation

final class DebugControl {
    private let directory: URL
    private let perform: (String, [String]) -> String?
    private var timer: Timer?

    /// `perform(command, arguments)` returns nil when the command ran.
    init(directory: String, perform: @escaping (String, [String]) -> String?) {
        self.directory = URL(fileURLWithPath: directory, isDirectory: true)
        self.perform = perform
    }

    func start() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // A directory listing every 0.2 s: next to nothing, and a check's reset
        // is answered well within a poll of the check's own waits.
        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in self?.poll() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func poll() {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in names.filter({ $0.hasSuffix(".cmd") }).sorted() {
            let file = directory.appendingPathComponent(name)
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            try? FileManager.default.removeItem(at: file)
            let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
            let reply = words.first.map { perform($0, Array(words.dropFirst())) ?? "ok" } ?? "empty command"
            let done = directory.appendingPathComponent(String(name.dropLast(".cmd".count)) + ".done")
            try? Data((reply + "\n").utf8).write(to: done, options: .atomic)
        }
    }
}
