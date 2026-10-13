// Small glass pieces that live inside the AppKit stream windows: the link pill
// and the phone-mode navigation bar. Each is an `NSGlassEffectView` whose
// content is SwiftUI (docs/DESIGN.md "AppKit-hosted bits").

import AppKit
import SwiftUI

private struct PillContent: View {
    let text: String
    let showsProgress: Bool

    var body: some View {
        HStack(spacing: 8) {
            if showsProgress { ProgressView().controlSize(.small) }
            Text(text).font(.caption)
        }
        .padding(.horizontal, 14)
        .frame(height: 36)
    }
}

final class GlassPillView: NSGlassEffectView {
    private let host = NSHostingView(rootView: PillContent(text: "", showsProgress: false))

    init(text: String, showsProgress: Bool) {
        super.init(frame: .zero)
        cornerRadius = 18
        host.rootView = PillContent(text: text, showsProgress: showsProgress)
        contentView = host
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func setText(_ text: String, showsProgress: Bool) {
        host.rootView = PillContent(text: text, showsProgress: showsProgress)
    }

    override var fittingSize: NSSize { host.fittingSize }

    func fade(to alpha: CGFloat) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = alpha > 0 ? 0.2 : 0.3
            animator().alphaValue = alpha
        }
    }
}

private struct PhoneBarContent: View {
    let back: () -> Void
    let home: () -> Void
    let recents: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            barButton("chevron.backward", help: "Back", action: back)
            barButton("circle", help: "Home", action: home)
            barButton("square.on.square", help: "Recents", action: recents)
        }
        .padding(.horizontal, 6)
    }

    private func barButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 44, height: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// Back / Home / Recents for the phone window; 144×36, shown on hover.
final class PhoneBarView: NSGlassEffectView {
    static let size = NSSize(width: 144, height: 36)

    init(back: @escaping () -> Void, home: @escaping () -> Void, recents: @escaping () -> Void) {
        super.init(frame: NSRect(origin: .zero, size: Self.size))
        cornerRadius = 18
        contentView = NSHostingView(rootView: PhoneBarContent(back: back, home: home, recents: recents))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
}
