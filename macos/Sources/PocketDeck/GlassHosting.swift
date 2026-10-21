// Small glass pieces that live inside the AppKit stream windows: the link pill
// (the hover header is in WindowChrome.swift). Each is an `NSGlassEffectView` whose
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
    /// The words the pill shows. The e2e reads them to tell one pill from
    /// another ("Not responding" from "Reconnecting…") in the same view tree.
    private(set) var text: String
    /// Where `fade(to:)` is taking the alpha; nil until the first fade, so the
    /// state never counts a pill whose fade-in was never started as shown.
    private(set) var fadeTarget: CGFloat?

    init(text: String, showsProgress: Bool) {
        self.text = text
        super.init(frame: .zero)
        cornerRadius = 18
        host.rootView = PillContent(text: text, showsProgress: showsProgress)
        contentView = host
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func setText(_ text: String, showsProgress: Bool) {
        self.text = text
        host.rootView = PillContent(text: text, showsProgress: showsProgress)
    }

    override var fittingSize: NSSize { host.fittingSize }

    func fade(to alpha: CGFloat) {
        fadeTarget = alpha
        NSAnimationContext.runAnimationGroup { context in
            context.duration = alpha > 0 ? 0.2 : 0.3
            animator().alphaValue = alpha
        }
    }
}
