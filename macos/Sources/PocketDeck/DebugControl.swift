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
//   activate         bring the app front for a real-key check (setup, no action)
//   menudump PATH    the main menu tree as JSON (MenuDump.swift), for a dump at
//                    a moment no debug-input script is running (the e2e menus
//                    check reads the bar after the last window closed)
//   iconmenu PATH    the status item's own menu as JSON, without popping it (the
//                    e2e menus check reads Settings…/About/Quit from it)
//   menubaricon      the status item as AppKit has it: "length=… image=…
//                    subviews=… state=… dot=…" (the e2e menubar-shots check)
//   panel-menu       Phone ▸ Turn Off Phone Screen: the same call the menu
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
//   resize-drag EDGE AMOUNT STEPS STEP_MS
//                    a whole drag on the first window's own live-resize path,
//                    one step a display refresh (a quiet run cannot move the
//                    person's pointer); EDGE is right, bottom or top
//   settings-dump PATH [LAST ROW]  the Settings window's real geometry: its
//                    frame against the screen, the tab's scroll view, and
//                    whether the last row shows once scrolled to the end
//   visibleframe PATH the visible frame of the key window's screen, "W H":
//                    the e2e chrome check's limit for an AX resize
//   deck-frame PATH  the Deck window's frame, "x y w h" in screen points (the
//                    frame a relaunch has to restore, DECK-19)
//   deckclick LABEL  a click on that app's cell in the Deck grid: the cell's
//                    own place from the accessibility tree, through the
//                    Deck window's event handling
//   deckrailclick LETTER [HOLD_MS] / deckraildrag FROM TO
//                    pointer events at the rail's drawn letters, through the
//                    window's event handling (the rail's own gesture)
//   deckrailclickat X Y [HOLD_MS] / deckrailhoverat X Y
//                    a pointer event at a point in the rail's own coordinates
//                    (0,0 = its top-left), for the hit column's bounds
//   deckcellpoint LABEL PATH  that cell's centre in Quartz coordinates, for a
//                    check that posts a real right click (the cell's menu)
//   deckmenu LABEL   the cell's own context menu, through a secondary click at
//                    the cell's drawn place (for the quiet screenshots)
//   shortcut add|remove PKG
//                    the Deck tile's Add to/Remove from Applications action
//                    (docs/specs/dock.md DOCK-4); a context menu cannot be
//                    clicked in a quiet run
//   dock add|remove PKG  the tile's Add to Dock/Remove from Dock App action
//   shortcutsall on|off  the phone page's Save all switch, through its own
//                    write-then-apply path
//   keywindow PATH   the key window's identifier and title, one per line
//                    (which window a raise actually put in front)
//   coverclick TITLE a click on the opening cover's Cancel or Close, at the
//                    button's place in the window
//   quit             a real quit through NSApp.terminate (⌘Q's path), for a
//                    check that relaunches the app
//   livedump PATH    the menu bar's LIVE section as JSON, at a moment no
//                    debug-input script is running (the e2e's notify/path
//                    checks read the rows before and after an outage)
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
