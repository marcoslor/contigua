// The three pairing sheets over the Deck: the 6-digit code, the QR, and the
// manual address (docs/design/mac-redesign.md §3.4–3.5).

import AppKit
import SwiftUI

/// The text of the code field, reduced to what the boxes show.
struct CodeEntry: Equatable {
    static let length = 6
    private(set) var digits = ""

    /// Keeps digits only (a paste of "482 913" works), at most six. Returns the
    /// code exactly once, when the sixth digit arrives.
    mutating func update(_ text: String) -> String? {
        let filtered = String(text.filter(\.isASCII).filter(\.isNumber).prefix(Self.length))
        let completed = filtered.count == Self.length && digits.count != Self.length
        digits = filtered
        return completed ? filtered : nil
    }

    mutating func clear() { digits = "" }

    func digit(at index: Int) -> Character? {
        index < digits.count ? digits[digits.index(digits.startIndex, offsetBy: index)] : nil
    }
}

struct CodeSheet: View {
    @Environment(ConnectionController.self) private var controller
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var entry = CodeEntry()
    @State private var text = ""
    @State private var shake = 0
    @FocusState private var focused: Bool

    private var phone: PhoneRef? { controller.link.phone }
    private var state: Pairing? {
        if case .pairing(_, let state) = controller.link { return state }
        return nil
    }

    var body: some View {
        VStack(spacing: 24) {
            Text("Enter the code shown on \(displayName)")
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
            if controller.pairingSucceeded {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(.green)
                    .symbolEffect(.bounce, value: controller.pairingSucceeded)
                    .frame(height: 60)
            } else if showsBoxes {
                digitRow
            }
            line
            actions
        }
        .padding(32)
        .frame(width: 400)
        .onChange(of: state) { old, new in
            if new == .stillWaiting {
                entry.clear()
                text = ""
                if !reduceMotion { shake += 1 }
                NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .default)
                focused = true
            }
            if new == .waitingForCode, old != .waitingForCode { entry.clear(); text = "" }
        }
        .onChange(of: controller.codeShown) { _, shown in if shown { focused = true } }
        .onAppear { focused = true }
    }

    private var displayName: String {
        // A manual connection only knows an address, which is no name to show.
        guard let phone, !phone.id.isEmpty, !phone.name.isEmpty else { return "your phone" }
        return phone.name
    }

    private var showsBoxes: Bool {
        switch state {
        case .denied, .timedOut, .unreachable: return false
        default: return true
        }
    }

    private var digitRow: some View {
        ZStack {
            TextField("", text: $text)
                .focused($focused)
                .textFieldStyle(.plain)
                .opacity(0.01)
                .frame(width: 1, height: 1)
                .disabled(!controller.codeShown || state == .verifying)
                .onChange(of: text) { _, new in
                    if let code = entry.update(new) { controller.submitCode(code) }
                    if text != entry.digits { text = entry.digits }
                }
            HStack(spacing: 8) {
                ForEach(0..<CodeEntry.length, id: \.self) { index in
                    box(index)
                    if index == 2 { Spacer().frame(width: 8) }
                }
            }
            .opacity(controller.codeShown ? 1 : 0.5)
            .keyframeAnimator(initialValue: 0.0, trigger: shake) { view, offset in
                view.offset(x: offset)
            } keyframes: { _ in
                KeyframeTrack {
                    for step in [-10.0, 10, -8, 8, -4, 4, 0] { LinearKeyframe(step, duration: 0.057) }
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { focused = true }
    }

    private func box(_ index: Int) -> some View {
        let isCurrent = focused && index == min(entry.digits.count, CodeEntry.length - 1)
        return ZStack {
            if let digit = entry.digit(at: index) {
                Text(String(digit))
                    .font(.system(size: 30, weight: .semibold, design: .rounded).monospacedDigit())
            }
        }
        .frame(width: 48, height: 60)
        .glassEffect(.regular, in: .rect(cornerRadius: 12))
        .overlay {
            if isCurrent {
                RoundedRectangle(cornerRadius: 12).strokeBorder(Color.accentColor, lineWidth: 2)
            }
        }
    }

    @ViewBuilder
    private var line: some View {
        switch state {
        case .waitingForCode:
            if controller.codeShown {
                Text("Allow on your phone, then type the code.").font(.callout).foregroundStyle(.secondary)
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Contacting \(displayName)…").font(.callout).foregroundStyle(.secondary)
                }
            }
        case .verifying:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Checking…").font(.callout).foregroundStyle(.secondary)
            }
        case .stillWaiting:
            Text("Still waiting. Check the code, and tap Allow on your phone.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
        case .denied:
            Text("Pairing was denied.").font(.callout).foregroundStyle(.red)
        case .timedOut:
            Text("The phone stopped waiting. Try again.").font(.callout).foregroundStyle(.secondary)
        case .unreachable:
            Text("Couldn't reach \(displayName). Try again.").font(.callout).foregroundStyle(.secondary)
        case nil:
            if controller.pairingSucceeded { Text("Paired.").font(.callout).foregroundStyle(.secondary) }
        }
    }

    @ViewBuilder
    private var actions: some View {
        switch state {
        case .denied, .timedOut, .unreachable:
            HStack(spacing: 8) {
                Button("Cancel") { controller.sheet = nil }.buttonStyle(.glass)
                Button("Try again") { controller.retryPairing() }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
            }
        case .verifying:
            EmptyView()
        default:
            if !controller.pairingSucceeded {
                Button("Cancel") { controller.sheet = nil }
                    .buttonStyle(.glass)
                    .keyboardShortcut(.cancelAction)
            }
        }
    }
}

struct QRSheet: View {
    @Environment(ConnectionController.self) private var controller

    var body: some View {
        VStack(spacing: 16) {
            Text("Scan with PocketDeck on your phone")
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
            if let qr = controller.qr {
                ZStack {
                    if qr.succeeded {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 64))
                            .foregroundStyle(.green)
                            .symbolEffect(.bounce, value: qr.succeeded)
                            .transition(.opacity)
                    } else {
                        tile(for: qr)
                    }
                }
                .frame(width: 252, height: 252)
                .animation(.smooth(duration: 0.3), value: qr.succeeded)
                status(for: qr)
            }
            Button(controller.qr?.succeeded == true ? "Done" : "Cancel") { controller.sheet = nil }
                .buttonStyle(.glass)
                .keyboardShortcut(.cancelAction)
        }
        .padding(32)
        .frame(width: 360)
    }

    private func tile(for qr: QRPairingState) -> some View {
        ZStack {
            // White in both appearances: scanners need the contrast.
            RoundedRectangle(cornerRadius: 16).fill(.white)
            if let image = QRCode.image(from: qr.payload.uri) {
                Image(nsImage: image).interpolation(.none).resizable().padding(16)
            }
        }
        .frame(width: 252, height: 252)
        .blur(radius: qr.expired ? 8 : 0)
        .overlay {
            if qr.expired {
                Button("Show new code") { controller.startQRPairing() }
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
            }
        }
    }

    @ViewBuilder
    private func status(for qr: QRPairingState) -> some View {
        if qr.succeeded {
            Text("Paired.").font(.callout).foregroundStyle(.secondary)
        } else if qr.expired {
            Text("This code expired.").font(.caption).foregroundStyle(.secondary)
        } else {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let remaining = Int(qr.payload.remaining(now: context.date).rounded(.up))
                Text("Expires in \(remaining / 60):\(String(format: "%02d", remaining % 60))")
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
            Text("Waiting for your phone…").font(.callout).foregroundStyle(.secondary)
        }
    }
}

struct ManualSheet: View {
    @Environment(ConnectionController.self) private var controller
    @State private var host = ""
    @State private var port = ""

    private var parsedPort: UInt16? { UInt16(port.trimmingCharacters(in: .whitespaces)).flatMap { $0 > 0 ? $0 : nil } }
    private var trimmedHost: String { host.trimmingCharacters(in: .whitespaces) }
    private var valid: Bool { !trimmedHost.isEmpty && parsedPort != nil }

    var body: some View {
        VStack(spacing: 24) {
            Text("Connect manually").font(.title3.weight(.semibold))
            Form {
                TextField("Address", text: $host, prompt: Text("192.168.1.20"))
                TextField("Port", text: $port, prompt: Text("47000")).monospacedDigit()
            }
            .formStyle(.columns)
            HStack(spacing: 8) {
                Button("Cancel") { controller.sheet = nil }
                    .buttonStyle(.glass)
                    .keyboardShortcut(.cancelAction)
                Button("Connect") {
                    if let parsedPort { controller.connectManually(host: trimmedHost, port: parsedPort) }
                }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!valid)
            }
        }
        .padding(32)
        .frame(width: 400)
    }
}
