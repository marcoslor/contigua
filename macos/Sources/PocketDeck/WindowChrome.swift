// The plain icon controls the stream windows' chrome hosts (StreamChrome.swift):
// one row of buttons whose taps are the window kinds' own actions — the phone
// window's Back / Home / Recents — at the framed bar's right end or inside the
// immersive dwell pill.

import AppKit
import SwiftUI

/// The buttons that live next to the traffic lights in the window kinds that
/// have them: plain icons in one row.
struct HeaderControls: View {
    static let buttonWidth: CGFloat = 32
    static let buttonHeight: CGFloat = 28
    let actions: [HeaderAction]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(actions) { action in
                Button(action: action.perform) {
                    Image(systemName: action.symbol)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)
                        .frame(width: Self.buttonWidth, height: Self.buttonHeight)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusable(false)
                .help(action.help)
                .accessibilityLabel(action.help)
            }
        }
    }
}

/// A button at the bar's right end (the phone window's Back/Home/Recents).
struct HeaderAction: Identifiable {
    let symbol: String
    let help: String
    let perform: () -> Void

    var id: String { symbol }
}
