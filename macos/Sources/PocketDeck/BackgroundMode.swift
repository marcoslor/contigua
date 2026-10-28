// Background mode (`--background`, e2e only): the checks run while the person
// keeps typing in another app. The app never becomes the frontmost app, has no
// Dock icon or ⌘-Tab entry, and puts its windows on a display of its own
// (VirtualDisplay.swift) instead of the person's screens. Launch refuses it
// with the default profile, so the installed app never runs this way.

import AppKit

enum BackgroundMode {
    /// Set once at launch, before any window exists.
    static var isOn = false

    @MainActor
    static func start() {
        NSApp.setActivationPolicy(.accessory)
        VirtualDisplay.create()
        NSWindow.keepWindowsOnVirtualDisplay()
        BackgroundKeyWindow.install()
    }

    /// Brings the app forward, except in background mode: there the person's
    /// frontmost app keeps the focus and windows are ordered without it.
    static func activateApp() {
        guard !isOn else { return }
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// An app that is not active has no key window, yet the app behaves by its key
/// window: menu commands and ⌥⌘F act on it, Escape reaches only it, it never
/// pauses. In background mode the window last made key (as the app's own code
/// does when it opens a window, and the scripted input when it focuses one) is
/// reported as the key window, with the usual become/resign notifications,
/// while the app itself stays inactive.
enum BackgroundKeyWindow {
    private static weak var window: NSWindow?

    /// The emulated key window while it is on screen.
    static var current: NSWindow? {
        guard let window, window.isVisible, !window.isMiniaturized else { return nil }
        return window
    }

    @MainActor
    static func install() {
        swap(NSWindow.self, #selector(NSWindow.makeKey), #selector(NSWindow.pd_makeKey))
        swap(NSWindow.self, #selector(NSWindow.makeKeyAndOrderFront(_:)), #selector(NSWindow.pd_makeKeyAndOrderFront(_:)))
        swap(NSWindow.self, #selector(getter: NSWindow.isKeyWindow), #selector(getter: NSWindow.pd_isKeyWindow))
        swap(NSApplication.self, #selector(getter: NSApplication.keyWindow), #selector(getter: NSApplication.pd_keyWindow))
        // A real AppKit app hands the keyboard to another window when the key
        // one closes; the emulation must too, or the app behaves as if nothing
        // were key after ⌘W.
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: nil, queue: .main
        ) { note in
            MainActor.assumeIsolated {
                guard let closing = note.object as? NSWindow, closing === window else { return }
                window = nil
                let next = NSApp.windows.first {
                    $0 !== closing && $0.isVisible && !$0.isMiniaturized && $0.canBecomeKey
                }
                if let next { becomeKey(next) }
            }
        }
    }

    private static func swap(_ cls: AnyClass, _ original: Selector, _ replacement: Selector) {
        guard let a = class_getInstanceMethod(cls, original), let b = class_getInstanceMethod(cls, replacement) else { return }
        method_exchangeImplementations(a, b)
    }

    fileprivate static func becomeKey(_ next: NSWindow) {
        guard next.canBecomeKey, next !== window else { return }
        let previous = current
        window = next
        if let previous { NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: previous) }
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: next)
    }
}

extension NSWindow {
    @objc fileprivate func pd_makeKey() {
        pd_makeKey()
        BackgroundKeyWindow.becomeKey(self)
    }

    @objc fileprivate func pd_makeKeyAndOrderFront(_ sender: Any?) {
        pd_makeKeyAndOrderFront(sender)
        BackgroundKeyWindow.becomeKey(self)
    }

    @objc fileprivate var pd_isKeyWindow: Bool { pd_isKeyWindow || BackgroundKeyWindow.current === self }
}

extension NSApplication {
    @objc fileprivate var pd_keyWindow: NSWindow? { pd_keyWindow ?? BackgroundKeyWindow.current }
}

/// Background mode's stand-in for LaunchServices handing the app a file: a quiet
/// run cannot use `open -a`, which brings the running app to the front even
/// with `-g`. A `*.path` file in the folder holds one absolute path per line;
/// it is read, removed, and its paths go to the app's own open handler.
/// nil (inert) unless the app runs with `--background`.
final class OpenRequestInbox {
    let folder: URL
    private var timer: Timer?

    init?(options: LaunchOptions) {
        guard options.background, let path = options.openRequests, path.hasPrefix("/") else { return nil }
        folder = URL(fileURLWithPath: path, isDirectory: true)
    }

    /// The paths of the requests waiting in the folder, oldest name first; the
    /// request files are removed.
    func take() -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.filter { $0.hasSuffix(".path") }.sorted().flatMap { name -> [URL] in
            let file = folder.appendingPathComponent(name)
            defer { try? FileManager.default.removeItem(at: file) }
            let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
            return text.split(separator: "\n").map(String.init).filter { $0.hasPrefix("/") }
                .map { URL(fileURLWithPath: $0) }
        }
    }

    func start(_ open: @escaping ([URL]) -> Void) {
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let urls = self?.take(), !urls.isEmpty else { return }
            open(urls)
        }
    }
}
