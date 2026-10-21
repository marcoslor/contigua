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
//   wake-phone       the phone window's Wake Screen button (phone mode)
//   menudump PATH    the main menu tree as JSON (MenuDump.swift), for a dump at
//                    a moment no debug-input script is running (the e2e menus
//                    check reads the bar after the last window closed)
//   panel-menu       Navigate ▸ Turn Off Phone Screen: the same call the menu
//                    item's binding makes (the phone window's own action)
//   nav-click back|home|recents  a click on that bar button: synthetic NSEvents
//                    at the button's window location, to the control the
//                    content's hit test finds (never the action itself)
//   nav back|home|recents  the Navigate menu's action on the first stream
//                    window (what its bar button and shortcut run): for a check
//                    that must act after a wait the app cannot run inline
//   occlude on|off   the first stream window's occlusion state: the WindowServer
//                    would say a covered window is not visible, and a quiet
//                    check may not put a window over it
//   secondary-click longPress|back|nothing
//                    Settings ▸ Input "Secondary click (two-finger click)", the
//                    same store the Settings picker writes
//   resize-step W H  one step of a scripted drag on the first window: the same
//                    windowWillResize call AppKit makes for a mouse move, then
//                    the frame it returns (the chrome state's `frame=` records it)
//   settings-dump PATH [LAST ROW]  the Settings window's real geometry: its
//                    frame against the screen, the tab's scroll view, and
//                    whether the last row shows once scrolled to the end
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
