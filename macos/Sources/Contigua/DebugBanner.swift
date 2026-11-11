// Test hook (`--debug-banner FILE`, e2e): writes the banner text the deck
// window currently shows, one line per change. The gate checks read the exact
// sentence the person sees without looking at pixels.

import Foundation

@MainActor
final class DebugBanner {
    private let file: URL
    private let read: () -> String?
    private var timer: Timer?
    private var last: String?

    init(path: String, read: @escaping () -> String?) {
        file = URL(fileURLWithPath: path)
        self.read = read
    }

    func start() {
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        poll()
    }

    private func poll() {
        let text = read()
        guard text != last else { return }
        last = text
        try? Data((text ?? "").utf8).write(to: file, options: .atomic)
    }
}
